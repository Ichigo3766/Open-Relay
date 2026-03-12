import Foundation

/// Represents a single file attachment shared from another app via the Share Extension.
///
/// Stores the raw bytes alongside the original filename and MIME type so the
/// main app can reconstruct a ``ChatAttachment`` with the correct metadata.
struct SharedFileAttachment: Codable, Sendable {
    /// Original filename (e.g. "report.pdf", "IMG_1234.jpg").
    let name: String
    /// Raw file data.
    let data: Data
    /// MIME type (e.g. "image/jpeg", "application/pdf"). May be nil if unknown.
    let mimeType: String?
    /// Whether this attachment is an image.
    var isImage: Bool {
        mimeType?.hasPrefix("image/") ?? false
    }
}

/// Represents content shared from another app via the Share Extension.
///
/// Stored in the App Group shared UserDefaults by the Share Extension,
/// then read and processed by the main app on launch.
struct SharedContent: Codable, Sendable {
    var text: String?
    var urls: [String] = []
    /// File attachments (images, PDFs, documents, etc.) with name and MIME type.
    var fileAttachments: [SharedFileAttachment] = []
    var timestamp: Date = .now

    // MARK: - Migration support

    /// Legacy image-only data (kept for backward compatibility with older extension builds).
    var imageData: [Data] = []
}
