import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct NoteFilesSection: View {
    @Bindable var model: NoteFilesModel
    @State private var previewURL: URL?
    @State private var download: Task<Void, Never>?
    @State private var opening = false
    @State private var openError: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !model.files.isEmpty || model.isBusy || model.error != nil {
                Text("Attachments").font(.subheadline.weight(.medium))
            }
            ForEach(Array(model.files.enumerated()), id: \.offset) { _, file in
                HStack {
                    Button { open(file) } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(file.name).lineLimit(2)
                                if let size = file.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } icon: { Image(systemName: file.icon) }
                    }
                    .accessibilityLabel("Open \(file.name)")
                    .disabled(opening || !model.sessionIsCurrent)
                    if model.canEdit {
                        Menu {
                            Button("Remove from note", systemImage: "minus.circle", role: .destructive) {
                                Task { await model.remove(file) }
                            }
                        } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Actions for \(file.name)")
                        .disabled(model.isBusy)
                    }
                }
                .padding(Spacing.sm)
                .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: CornerRadius.sm))
            }
            if model.isBusy { ProgressView("Updating attachments…") }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                if model.pending != nil {
                    Text("Uploaded, but not attached to this note yet.").font(.footnote)
                    Button("Retry attaching") { Task { await model.retryAttachment() } }
                        .disabled(model.isBusy)
                } else if !model.loaded {
                    Button("Retry loading attachments") { Task { await model.load() } }
                }
            }
            if opening {
                HStack {
                    ProgressView("Opening attachment…")
                    Spacer()
                    Button("Cancel", systemImage: "xmark") { download?.cancel() }
                        .labelStyle(.iconOnly)
                }
            }
            if let openError { Text(openError).font(.footnote).foregroundStyle(.secondary) }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { previous, current in
            if current == nil, let previous { try? FileManager.default.removeItem(at: previous.deletingLastPathComponent()) }
        }
        .onDisappear { download?.cancel() }
    }

    private func open(_ file: NoteFileReference) {
        guard !opening, model.sessionIsCurrent else { return }
        opening = true
        openError = nil
        download = Task {
            defer { opening = false }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url: URL
                if file.isImage {
                    // Native inline images are data URLs. Never send credentials to an arbitrary image URL.
                    guard let value = file.raw["url"] as? String,
                          value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
                          value[..<comma].hasSuffix(";base64"),
                          let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    let mime = String(value.dropFirst(5).prefix { $0 != ";" })
                    url = directory.appendingPathComponent("image." + (UTType(mimeType: mime)?.preferredFilenameExtension ?? "img"))
                    try data.write(to: url)
                } else {
                    guard file.raw["type"] as? String == "file", let id = file.fileId, !id.isEmpty,
                          let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    let temporary = try await model.api.network.downloadFile(path: "/api/v1/files/\(encoded)/content")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let name = (file.name as NSString).lastPathComponent
                    url = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "attachment" : name)
                    try FileManager.default.moveItem(at: temporary, to: url)
                }
                try Task.checkCancellation()
                guard model.sessionIsCurrent else { throw CancellationError() }
                previewURL = url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if !Task.isCancelled, !(error is CancellationError), model.sessionIsCurrent {
                    openError = "Couldn’t open attachment. Tap it to retry. \(error.localizedDescription)"
                }
            }
        }
    }
}
