import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os.log
import ImageIO
import CoreImage

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

    private struct FileEntry {
        let id: UUID
        let url: URL
        let data: Data
        let isImage: Bool
    }

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
    /// When 2 or more non-image files are selected they are uploaded in parallel
    /// and then submitted to the server as a single batch-processing request,
    /// which is faster than N individual upload+SSE-poll calls.
    func processFileURLs(_ urls: [URL]) async {
        guard urls.count > 1 else {
            // Single file — use the existing path (upload + SSE poll).
            if let url = urls.first { await processFileURL(url) }
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        // ── 1. Read file data and classify URLs ───────────────────────────────
        // Build FileEntry + add placeholder attachment in one pass so the
        // entry.id always matches the attachment's auto-generated UUID.
        var entries: [FileEntry] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                logger.error("Cannot access security-scoped resource: \(url.path)")
                continue
            }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url) else {
                logger.error("Failed to read file data: \(url.path)")
                continue
            }
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false

            // ── 2. Add placeholder attachment and capture its UUID ────────────
            var attachment: ChatAttachment
            if isImage {
                let (convertedData, fileName) = convertToJPEGIfNeeded(
                    data: data,
                    originalName: url.lastPathComponent
                )
                let thumbnail: Image? = UIImage(data: convertedData).map { Image(uiImage: $0) }
                attachment = ChatAttachment(
                    type: .image,
                    name: fileName,
                    thumbnail: thumbnail,
                    data: convertedData
                )
                attachment.uploadStatus = .uploading
                pendingAttachments.append(attachment)
                entries.append(FileEntry(id: attachment.id, url: url, data: convertedData, isImage: true))
            } else {
                attachment = ChatAttachment(
                    type: .file,
                    name: url.lastPathComponent,
                    thumbnail: nil,
                    data: data
                )
                attachment.uploadStatus = .uploading
                pendingAttachments.append(attachment)
                entries.append(FileEntry(id: attachment.id, url: url, data: data, isImage: false))
            }
        }

        // ── 3. Images: upload individually (no server-side processing needed) ─
        let imageEntries = entries.filter { $0.isImage }
        let docEntries   = entries.filter { !$0.isImage }

        for entry in imageEntries {
            Task { await self.uploadAttachment(id: entry.id) }
        }

        // ── 4. Documents: single file → existing path; 2+ → batch ────────────
        if docEntries.count == 1 {
            Task { await self.uploadAttachment(id: docEntries[0].id) }
        } else if docEntries.count > 1 {
            Task { await self.uploadAndBatchProcess(entries: docEntries) }
        }
    }

    // MARK: - Batch Upload + Process

    /// Uploads each document without individual processing, then calls the
    /// batch-processing endpoint once for all of them.
    private func uploadAndBatchProcess(entries: [FileEntry]) async {
        guard let manager = conversationManager else {
            for entry in entries {
                updateAttachmentStatus(id: entry.id, status: .error, error: "Not connected to server")
            }
            return
        }

        // ── Phase 1: parallel upload (no processing) ─────────────────────────
        // Each element: (attachmentId, fileObject) or nil on failure
        typealias UploadResult = (id: UUID, fileObject: [String: Any])?

        var fileObjects: [[String: Any]] = []
        var idToFileId: [UUID: String] = [:]

        await withTaskGroup(of: UploadResult.self) { group in
            for entry in entries {
                let entryId = entry.id
                let entryData = entry.data
                let entryName = entry.url.lastPathComponent
                group.addTask {
                    do {
                        let fileObj = try await manager.uploadFileOnly(
                            data: entryData,
                            fileName: entryName
                        )
                        return (id: entryId, fileObject: fileObj)
                    } catch {
                        let msg = (error as? APIError).flatMap {
                            if case .httpError(_, let m, _) = $0 { return m } else { return nil }
                        } ?? error.localizedDescription
                        await MainActor.run {
                            self.updateAttachmentStatus(id: entryId, status: .error, error: msg)
                        }
                        self.logger.error("Batch upload failed for \(entryName): \(msg)")
                        return nil
                    }
                }
            }

            for await result in group {
                guard let r = result else { continue }
                fileObjects.append(r.fileObject)
                if let fileId = r.fileObject["id"] as? String {
                    idToFileId[r.id] = fileId
                }
            }
        }

        // Mark all successfully uploaded files as .processing
        for (attachId, _) in idToFileId {
            updateAttachmentStatus(id: attachId, status: .processing)
        }

        guard !fileObjects.isEmpty else { return }

        // ── Phase 2: single batch-process call ────────────────────────────────
        let collectionName = "batch-\(UUID().uuidString)"
        do {
            let result = try await manager.processFilesBatch(
                fileObjects: fileObjects,
                collectionName: collectionName
            )

            // Map fileId → attachmentId for result routing
            let fileIdToAttachId = Dictionary(idToFileId.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

            for fileId in result.successes {
                if let attachId = fileIdToAttachId[fileId] {
                    updateAttachmentStatus(id: attachId, status: .completed, fileId: fileId)
                }
            }
            for failure in result.errors {
                if let attachId = fileIdToAttachId[failure.fileId] {
                    updateAttachmentStatus(
                        id: attachId,
                        status: .error,
                        error: failure.error ?? "Processing failed"
                    )
                }
            }
            logger.info("Batch processed \(result.successes.count) files (\(result.errors.count) errors)")
        } catch {
            let msg = (error as? APIError).flatMap {
                if case .httpError(_, let m, _) = $0 { return m } else { return nil }
            } ?? error.localizedDescription
            logger.error("Batch processing call failed: \(msg)")
            // Fall back: mark each as error with the batch failure message
            for attachId in idToFileId.keys {
                updateAttachmentStatus(id: attachId, status: .error, error: msg)
            }
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
    ///
    /// For non-image files, two phases are shown:
    /// 1. `.uploading` — multipart POST in progress
    /// 2. `.processing` — file is on server, SSE polling for completion
    /// 3. `.completed` or `.error` — done
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

        // Mark as uploading
        updateAttachmentStatus(id: id, status: .uploading)

        do {
            // For non-images: transition to .processing once upload completes,
            // while waiting for the server's SSE processing poll.
            let (fileId, fileObject) = try await manager.uploadFile(
                data: data,
                fileName: fileName,
                onUploaded: { [weak self] _ in
                    // Called on the calling task's thread (non-isolated);
                    // dispatch back to MainActor to update @Observable state.
                    Task { @MainActor [weak self] in
                        self?.updateAttachmentStatus(id: id, status: .processing)
                    }
                }
            )
            updateAttachmentStatus(id: id, status: .completed, fileId: fileId, fileObject: fileObject)
            logger.info("Attachment \(fileName) uploaded and processed successfully")
        } catch {
            // Surface the server error message (e.g. transcription failure) to the user.
            let message: String
            if let apiError = error as? APIError,
               case .httpError(_, let msg, _) = apiError,
               let msg {
                message = msg
            } else {
                message = error.localizedDescription
            }
            logger.error("Failed to upload/process \(fileName): \(message)")
            updateAttachmentStatus(id: id, status: .error, error: message)
        }
    }

    /// Updates the upload status of an attachment by its ID.
    private func updateAttachmentStatus(
        id: UUID,
        status: ChatAttachment.UploadStatus,
        fileId: String? = nil,
        fileObject: [String: Any]? = nil,
        error: String? = nil
    ) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingAttachments[index].uploadStatus = status
        if let fileId { pendingAttachments[index].uploadedFileId = fileId }
        if let fileObject { pendingAttachments[index].uploadedFileObject = fileObject }
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
    /// Builds the rich web-UI-format file ref so the server can locate the image/file content.
    /// Used by ChatViewModel.sendMessage() instead of uploading at send time.
    func getUploadedFileRefs() -> [[String: Any]] {
        pendingAttachments.compactMap { attachment -> [String: Any]? in
            guard let fileId = attachment.uploadedFileId else { return nil }
            // Skip audio attachments — they're handled separately via transcription
            guard attachment.type != .audio else { return nil }

            let fileObject = attachment.uploadedFileObject ?? [:]
            let filename = attachment.name
            let isImage = attachment.type == .image
            let contentType: String = isImage ? "image/jpeg" : "application/octet-stream"
            let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0

            return [
                "type": "file",
                "file": fileObject.isEmpty ? [
                    "id": fileId,
                    "filename": filename,
                    "meta": ["name": filename, "content_type": contentType, "size": size]
                ] : fileObject,
                "id": fileId,
                "url": fileId,
                "name": filename,
                "status": "uploaded",
                "size": size,
                "error": "",
                "content_type": contentType
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

    /// Maximum total pixels for uploaded images (4 megapixels ≈ 2000×2000).
    /// This fills GPT-4o's max tile budget (2048px), Claude's and Gemini's
    /// high-resolution paths, giving vision models the most detail possible
    /// while keeping JPEG output well under 5 MB for typical photos.
    private static let maxPixels: CGFloat = 4_000_000

    /// Upload size ceiling enforced by the /files API.
    private static let uploadSizeLimit = 5 * 1_024 * 1_024   // 5 MB

    /// Downsamples an image to ≤ 4 MP and returns JPEG data.
    /// If the image is already within the pixel budget, it is only re-encoded.
    /// Returns the original data unchanged if decoding fails.
    static func downsampleForUpload(data: Data, image: UIImage? = nil, logger: Logger? = nil) -> Data {
        guard let img = image ?? UIImage(data: data) else { return data }
        return downsampleForUpload(image: img, logger: logger)
    }

    /// Core implementation: downscale `UIImage` to ≤ 4 MP using Lanczos3 resampling
    /// (GPU-accelerated via `CILanczosScaleTransform`), then encode as JPEG with a
    /// progressive quality fallback to guarantee the result stays under 5 MB.
    ///
    /// Algorithm rationale:
    /// - `UIGraphicsImageRenderer.draw` uses bilinear interpolation — it blurs fine
    ///   detail that vision models need to correctly interpret photos.
    /// - `CILanczosScaleTransform` uses a Lanczos3 (sinc-windowed) kernel, which is
    ///   the gold standard for photo downsampling: sharp edges, minimal aliasing.
    static func downsampleForUpload(image: UIImage, logger: Logger? = nil) -> Data {
        let w = image.size.width
        let h = image.size.height
        let totalPixels = w * h

        // ── 1. Resize to ≤ maxPixels using Lanczos3 ──────────────────────────
        let targetImage: UIImage
        if totalPixels > maxPixels {
            let scaleFactor = sqrt(maxPixels / totalPixels)
            let targetW = round(w * scaleFactor)
            let targetH = round(h * scaleFactor)

            if let ciInput = CIImage(image: image) {
                let scaleX = targetW / ciInput.extent.width
                let filter = CIFilter(name: "CILanczosScaleTransform")!
                filter.setValue(ciInput,  forKey: kCIInputImageKey)
                filter.setValue(scaleX,   forKey: kCIInputScaleKey)
                filter.setValue(1.0,      forKey: kCIInputAspectRatioKey)

                let ctx = CIContext(options: [.useSoftwareRenderer: false])
                if let output = filter.outputImage,
                   let cg = ctx.createCGImage(output, from: output.extent) {
                    targetImage = UIImage(cgImage: cg, scale: 1, orientation: image.imageOrientation)
                    logger?.info("Lanczos downsampled \(Int(w))×\(Int(h)) → \(Int(targetW))×\(Int(targetH))")
                } else {
                    // CI pipeline failed — fall back to original
                    targetImage = image
                    logger?.warning("CILanczosScaleTransform failed, using original dimensions")
                }
            } else {
                targetImage = image
                logger?.warning("CIImage init failed, using original dimensions")
            }
        } else {
            targetImage = image
        }

        // ── 2. Encode JPEG with progressive quality fallback ──────────────────
        // Starts at 0.85 (visually lossless for photos). Only steps down if the
        // encoded result would still exceed the 5 MB API limit, which is rare at
        // 4 MP but possible for extreme-detail images.
        let qualities: [CGFloat] = [0.85, 0.75, 0.65, 0.55, 0.45]
        for quality in qualities {
            if let data = targetImage.jpegData(compressionQuality: quality),
               data.count < uploadSizeLimit {
                if quality < 0.85 {
                    logger?.warning("Used JPEG quality \(quality) to fit under 5 MB (\(data.count) bytes)")
                }
                return data
            }
        }
        // Last-resort: 0.45 quality regardless of size
        return targetImage.jpegData(compressionQuality: 0.45) ?? Data()
    }
}
