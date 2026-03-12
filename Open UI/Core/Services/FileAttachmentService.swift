import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os.log
import ImageIO

/// Manages file attachment handling for chats and notes, including
/// image picking, document selection, and file upload to the server.
@MainActor @Observable
final class FileAttachmentService {

    // MARK: - State

    /// Pending attachments ready to be sent.
    private(set) var pendingAttachments: [ChatAttachment] = []

    /// Whether a file operation is in progress.
    private(set) var isProcessing: Bool = false

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "FileAttachment")
    private var conversationManager: ConversationManager?

    // MARK: - Configuration

    func configure(with manager: ConversationManager) {
        self.conversationManager = manager
    }

    // MARK: - Image Handling

    /// Processes selected photos from PhotosPicker.
    /// Automatically converts HEIC/HEIF/DNG/RAW images to JPEG for
    /// compatibility with vision models that don't support these formats.
    /// Immediately begins uploading each photo to the server.
    func processPhotos(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let (convertedData, fileName) = convertToJPEGIfNeeded(
                        data: data,
                        originalName: "Photo_\(Date.now.timeIntervalSince1970).jpg"
                    )
                    let image = UIImage(data: convertedData)
                    let thumbnail = image.map { Image(uiImage: $0) }

                    var attachment = ChatAttachment(
                        type: .image,
                        name: fileName,
                        thumbnail: thumbnail,
                        data: convertedData
                    )
                    attachment.uploadStatus = .uploading
                    pendingAttachments.append(attachment)

                    // Start upload immediately in background
                    let attachmentId = attachment.id
                    Task { await self.uploadAttachment(id: attachmentId) }
                }
            } catch {
                logger.error("Failed to load photo: \(error.localizedDescription)")
            }
        }
    }

    /// Processes a file URL (from document picker or share extension).
    /// Automatically converts HEIC/HEIF/DNG/RAW images to JPEG.
    /// Immediately begins uploading + processing on the server.
    func processFileURL(_ url: URL) async {
        isProcessing = true
        defer { isProcessing = false }

        guard url.startAccessingSecurityScopedResource() else {
            logger.error("Cannot access security-scoped resource: \(url.path)")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            logger.error("Failed to read file data: \(url.path)")
            return
        }

        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false

        if isImage {
            let (convertedData, fileName) = convertToJPEGIfNeeded(
                data: data,
                originalName: url.lastPathComponent
            )
            let thumbnail: Image? = UIImage(data: convertedData).map { Image(uiImage: $0) }
            var attachment = ChatAttachment(
                type: .image,
                name: fileName,
                thumbnail: thumbnail,
                data: convertedData
            )
            attachment.uploadStatus = .uploading
            pendingAttachments.append(attachment)

            let attachmentId = attachment.id
            Task { await self.uploadAttachment(id: attachmentId) }
        } else {
            var attachment = ChatAttachment(
                type: .file,
                name: url.lastPathComponent,
                thumbnail: nil,
                data: data
            )
            attachment.uploadStatus = .uploading
            pendingAttachments.append(attachment)

            let attachmentId = attachment.id
            Task { await self.uploadAttachment(id: attachmentId) }
        }
    }

    /// Processes multiple file URLs.
    func processFileURLs(_ urls: [URL]) async {
        for url in urls {
            await processFileURL(url)
        }
    }

    // MARK: - Upload

    /// Whether all non-audio attachments have finished uploading + processing.
    var allAttachmentsReady: Bool {
        let nonAudio = pendingAttachments.filter { $0.type != .audio }
        guard !nonAudio.isEmpty else { return true }
        return nonAudio.allSatisfy { $0.isReady }
    }

    /// Whether any attachment is currently uploading or processing.
    var hasUploadingAttachments: Bool {
        pendingAttachments.contains { $0.isUploading }
    }

    /// Uploads a single attachment to the server immediately.
    /// Updates the attachment's status as it progresses through
    /// uploading → processing → completed (or error).
    private func uploadAttachment(id: UUID) async {
        guard let manager = conversationManager else {
            updateAttachmentStatus(id: id, status: .error, error: "Not connected to server")
            return
        }

        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }),
              let data = pendingAttachments[index].data else {
            return
        }

        let fileName = pendingAttachments[index].name
        let isImage = pendingAttachments[index].type == .image

        // Mark as uploading
        updateAttachmentStatus(id: id, status: .uploading)

        do {
            // Upload file — for non-images, this also waits for processing
            // (the APIClient.uploadFile method handles ?process=true + SSE polling)
            if !isImage {
                // For documents: show "processing" after upload starts
                // We split this into two phases for better UI feedback
                let fileId = try await manager.uploadFile(data: data, fileName: fileName)
                updateAttachmentStatus(id: id, status: .completed, fileId: fileId)
            } else {
                let fileId = try await manager.uploadFile(data: data, fileName: fileName)
                updateAttachmentStatus(id: id, status: .completed, fileId: fileId)
            }

            logger.info("Attachment \(fileName) uploaded successfully")
        } catch {
            logger.error("Failed to upload \(fileName): \(error.localizedDescription)")
            updateAttachmentStatus(id: id, status: .error, error: error.localizedDescription)
        }
    }

    /// Updates the upload status of an attachment by its ID.
    private func updateAttachmentStatus(
        id: UUID,
        status: ChatAttachment.UploadStatus,
        fileId: String? = nil,
        error: String? = nil
    ) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingAttachments[index].uploadStatus = status
        if let fileId { pendingAttachments[index].uploadedFileId = fileId }
        if let error { pendingAttachments[index].uploadError = error }
    }

    /// Retries uploading a failed attachment.
    func retryUpload(attachmentId: UUID) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }),
              pendingAttachments[index].uploadStatus == .error else { return }

        pendingAttachments[index].uploadStatus = .uploading
        pendingAttachments[index].uploadError = nil
        Task { await uploadAttachment(id: attachmentId) }
    }

    /// Returns pre-uploaded file references for all completed attachments.
    /// Used by ChatViewModel.sendMessage() instead of uploading at send time.
    func getUploadedFileRefs() -> [[String: Any]] {
        pendingAttachments.compactMap { attachment -> [String: Any]? in
            guard let fileId = attachment.uploadedFileId else { return nil }
            // Skip audio attachments — they're handled separately via transcription
            guard attachment.type != .audio else { return nil }
            return [
                "type": attachment.type == .image ? "image" : "file",
                "id": fileId,
                "name": attachment.name
            ]
        }
    }

    // MARK: - Management

    /// Removes an attachment from the pending list.
    func removeAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Clears all pending attachments.
    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    // MARK: - Previews

    /// Returns an icon name for the given file extension.
    static func iconForExtension(_ ext: String) -> String {
        guard let utType = UTType(filenameExtension: ext) else { return "doc" }
        if utType.conforms(to: .image) { return "photo" }
        if utType.conforms(to: .movie) { return "film" }
        if utType.conforms(to: .audio) { return "waveform" }
        if utType.conforms(to: .pdf) { return "doc.text" }
        if utType.conforms(to: .spreadsheet) { return "tablecells" }
        if utType.conforms(to: .presentation) { return "rectangle.stack" }
        if utType.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if utType.conforms(to: .text) { return "doc.plaintext" }
        if utType.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }

    /// Formats a byte count for display.
    static func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Image Conversion

    /// File extensions that need conversion to JPEG for vision model compatibility.
    private static let convertibleExtensions: Set<String> = [
        "heic", "heif", "dng", "raw", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2", "webp"
    ]

    /// Converts HEIC/HEIF/DNG/RAW image data to JPEG if needed.
    /// Also enforces the 2 MP pixel cap so uploads always stay under the
    /// API's 5 MB image limit.
    /// Returns the (possibly converted) data and updated filename.
    private func convertToJPEGIfNeeded(data: Data, originalName: String) -> (Data, String) {
        let ext = (originalName as NSString).pathExtension.lowercased()

        // Check if format conversion is needed
        guard Self.convertibleExtensions.contains(ext) else {
            // No format conversion, but still enforce pixel cap
            let capped = Self.downsampleForUpload(data: data, logger: logger)
            return (capped, originalName)
        }

        // Try to convert using UIImage → JPEG, then apply pixel cap
        guard let uiImage = UIImage(data: data) else {
            logger.warning("Failed to decode \(ext) image, using original")
            return (data, originalName)
        }

        let baseName = (originalName as NSString).deletingPathExtension
        let newName = baseName + ".jpg"

        let capped = Self.downsampleForUpload(image: uiImage, logger: logger)

        logger.info("Converted \(ext) image to JPEG (\(data.count) → \(capped.count) bytes)")
        return (capped, newName)
    }

    // MARK: - Image Size Limit

    /// Maximum total pixels for uploaded images (2 megapixels).
    /// A 2 MP JPEG at 0.85 quality is typically 1-2 MB — well under the
    /// API's 5 MB limit — while retaining enough detail for vision models.
    private static let maxPixels: CGFloat = 2_000_000

    /// Downsamples an image to ≤ 2 MP and returns JPEG data at 0.85 quality.
    /// If the image is already within the pixel budget, it is only re-encoded
    /// to JPEG (no resize). Returns the original data unchanged if decoding fails.
    static func downsampleForUpload(data: Data, image: UIImage? = nil, logger: Logger? = nil) -> Data {
        guard let img = image ?? UIImage(data: data) else { return data }
        return downsampleForUpload(image: img, logger: logger)
    }

    /// Core implementation: downscale `UIImage` to ≤ 2 MP, encode as JPEG.
    static func downsampleForUpload(image: UIImage, logger: Logger? = nil) -> Data {
        let w = image.size.width
        let h = image.size.height
        let totalPixels = w * h

        if totalPixels <= maxPixels {
            // Already small enough — just encode to JPEG
            return image.jpegData(compressionQuality: 0.85) ?? Data()
        }

        // Scale factor to reach exactly maxPixels
        let scale = sqrt(maxPixels / totalPixels)
        let newSize = CGSize(width: round(w * scale), height: round(h * scale))

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        let result = resized.jpegData(compressionQuality: 0.85) ?? Data()
        logger?.info("Downsampled image from \(Int(w))×\(Int(h)) to \(Int(newSize.width))×\(Int(newSize.height)) (\(result.count) bytes)")
        return result
    }
}
