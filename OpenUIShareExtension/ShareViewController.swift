import UIKit
import UniformTypeIdentifiers
import MobileCoreServices

/// Share Extension view controller.
///
/// Uses the standard UIViewController + NSExtensionContext approach, which is the
/// only fully reliable way to receive arbitrary file attachments from any app on iOS.
///
/// Flow:
/// 1. iOS instantiates this as the NSExtensionPrincipalClass.
/// 2. viewDidLoad() immediately processes all NSItemProviders from the share sheet.
/// 3. All items are serialised into a SharedContent struct and saved to the shared
///    App Group UserDefaults under the key "pending_shared_content".
/// 4. We open the main app via the "openui://shared-content" URL scheme.
/// 5. extensionContext.completeRequest() dismisses the share sheet.
/// 6. The main app foregrounds and reads the pending content on scenePhase == .active.
final class ShareViewController: UIViewController {

    // MARK: - Entry Point

    override func viewDidLoad() {
        super.viewDidLoad()
        // Transparent background — this VC is never actually shown.
        view.backgroundColor = .clear

        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }

        // Collect all NSItemProviders from every input item.
        let providers: [NSItemProvider] = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finish()
            return
        }

        Task {
            var content = await Self.process(providers: providers)
            // Large payloads (photos, videos, PDFs) don't belong in UserDefaults:
            // write them to the shared App Group container and pass file paths.
            content = Self.offloadFilesToContainer(content)

            // Persist to the shared App Group so the main app can read it.
            if let defaults = UserDefaults(suiteName: "group.com.openui.openui"),
               let encoded = try? JSONEncoder().encode(content) {
                defaults.set(encoded, forKey: "pending_shared_content")
                defaults.synchronize()
            }

            // Open the main app. openui://shared-content is handled in Open_UIApp.swift.
            await openMainApp()
            finish()
        }
    }

    /// Moves attachment bytes into `<AppGroup>/SharedInbox/` and replaces them with
    /// the relative file name. Falls back to inline data if the container is unavailable.
    private static func offloadFilesToContainer(_ content: SharedContent) -> SharedContent {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.openui.openui") else { return content }
        let inbox = container.appendingPathComponent("SharedInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var result = content
        result.fileAttachments = content.fileAttachments.map { file in
            let stored = UUID().uuidString + "-" + file.name
            let url = inbox.appendingPathComponent(stored)
            guard (try? file.data.write(to: url, options: .atomic)) != nil else { return file }
            return SharedFileAttachment(name: file.name, data: Data(), mimeType: file.mimeType, storedFileName: stored)
        }
        return result
    }

    // MARK: - Item Processing

    /// Converts an array of NSItemProviders into a ``SharedContent`` value.
    private static func process(providers: [NSItemProvider]) async -> SharedContent {
        var content = SharedContent()

        for provider in providers {
            // ── Web URL (Safari, Chrome, any browser) ──────────────────────────
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let urlStr = await loadURL(from: provider) {
                    let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Only store non-file URLs as web URLs
                    if let url = URL(string: trimmed), !url.isFileURL {
                        content.urls.append(trimmed)
                        continue
                    }
                }
            }

            // ── File URL (Files app, Finder, any file-based app) ───────────────
            // Must be checked before plain-data so we get the actual file bytes.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let attachment = await loadFileURL(from: provider) {
                    content.fileAttachments.append(attachment)
                    continue
                }
            }

            // ── Image (Photos, screenshots, etc.) ─────────────────────────────
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let attachment = await loadData(from: provider,
                                                   typeIdentifier: UTType.image.identifier,
                                                   fallbackMIME: "image/jpeg") {
                    content.fileAttachments.append(attachment)
                    continue
                }
            }

            // ── PDF ────────────────────────────────────────────────────────────
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                if let attachment = await loadData(from: provider,
                                                   typeIdentifier: UTType.pdf.identifier,
                                                   fallbackMIME: "application/pdf") {
                    content.fileAttachments.append(attachment)
                    continue
                }
            }

            // ── Plain text (may contain a URL) ─────────────────────────────────
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadText(from: provider) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // If the text IS a URL treat it as one.
                    if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")),
                       URL(string: trimmed) != nil {
                        content.urls.append(trimmed)
                    } else if !trimmed.isEmpty {
                        if content.text == nil {
                            content.text = trimmed
                        } else {
                            content.text?.append("\n" + trimmed)
                        }
                    }
                    continue
                }
            }

            // ── Generic data (any other file type) ────────────────────────────
            if let firstType = provider.registeredTypeIdentifiers.first {
                if let attachment = await loadData(from: provider,
                                                   typeIdentifier: firstType,
                                                   fallbackMIME: nil) {
                    content.fileAttachments.append(attachment)
                }
            }
        }

        return content
    }

    // MARK: - NSItemProvider Loaders

    /// Loads a web URL string from an item provider.
    private static func loadURL(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url.absoluteString)
                } else if let data = item as? Data,
                          let str = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: str)
                } else if let str = item as? String {
                    continuation.resume(returning: str)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Loads a file from a file:// URL item provider, copying the raw bytes.
    private static func loadFileURL(from provider: NSItemProvider) async -> SharedFileAttachment? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let fileURL = item as? URL else {
                    continuation.resume(returning: nil)
                    return
                }
                // Access the security-scoped resource if needed.
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

                guard let data = try? Data(contentsOf: fileURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                let filename = fileURL.lastPathComponent.isEmpty ? "file" : fileURL.lastPathComponent
                let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                continuation.resume(returning: SharedFileAttachment(name: filename,
                                                                     data: data,
                                                                     mimeType: mime))
            }
        }
    }

    /// Loads raw bytes for a given UTI, deriving a sensible filename and MIME type.
    private static func loadData(from provider: NSItemProvider,
                                 typeIdentifier: String,
                                 fallbackMIME: String?) async -> SharedFileAttachment? {
        // Capture suggestedName before entering the @Sendable closure to avoid
        // capturing the non-Sendable NSItemProvider across a concurrency boundary.
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let utType = UTType(typeIdentifier)
                let mime = utType?.preferredMIMEType ?? fallbackMIME
                let ext = utType?.preferredFilenameExtension ?? "bin"
                let name = suggestedName ?? "attachment.\(ext)"
                continuation.resume(returning: SharedFileAttachment(name: name,
                                                                     data: data,
                                                                     mimeType: mime))
            }
        }
    }

    /// Loads a plain-text string from an item provider.
    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    // MARK: - App Launch

    /// Opens the main app via the openui:// URL scheme.
    ///
    /// Extensions cannot call UIApplication.shared directly, so we walk the
    /// responder chain to find the UIApplication instance and open the URL on it.
    @MainActor
    private func openMainApp() async {
        guard let url = URL(string: "openui://shared-content") else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    // MARK: - Completion

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

// MARK: - Inline model types
// Duplicated here because share extensions cannot import the main app target.
// Keep in sync with Open UI/Core/Models/SharedContent.swift.

private struct SharedFileAttachment: Codable {
    let name: String
    let data: Data
    let mimeType: String?
    /// File name inside `<AppGroup>/SharedInbox/` when the bytes were written to disk.
    var storedFileName: String? = nil
}

private struct SharedContent: Codable {
    var text: String?
    var urls: [String] = []
    var fileAttachments: [SharedFileAttachment] = []
    var timestamp: Date = .now
    var imageData: [Data] = []   // kept for backward-compat decoding
}
