import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Unified Image Pipeline
//
// Every image that enters the composer (camera, scanner, Photos picker, Files,
// paste, Share Extension, "Open In") goes through here, so they are all decoded
// the same way (HEIC/RAW/WebP/…), orientation-corrected, capped at 4 MP, encoded
// as JPEG under 5 MB, renamed .jpg, and given a cheap thumbnail.

extension FileAttachmentService {
    /// Image file extensions the pipeline treats as images.
    nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
        "dng", "raw", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2"
    ]

    /// Whether a file name / MIME type describes an image.
    nonisolated static func isImageFile(name: String, mimeType: String? = nil) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        if let mimeType, mimeType.hasPrefix("image/") { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return true }
        return false
    }

    /// Builds an upload-ready image attachment from raw image bytes in any format.
    /// Returns nil when the data can't be decoded as an image.
    static func makeImageAttachment(data: Data, name: String? = nil) -> ChatAttachment? {
        guard let image = decodeImage(data) else { return nil }
        return makeImageAttachment(image: image, name: name)
    }

    /// Builds an upload-ready image attachment from a decoded image.
    static func makeImageAttachment(image: UIImage, name: String? = nil) -> ChatAttachment? {
        let jpeg = downsampleForUpload(image: image)
        guard !jpeg.isEmpty else { return nil }
        let baseName = name.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Photo_\(Int(Date.now.timeIntervalSince1970))"
        let thumbnail = makeThumbnail(from: jpeg).map { Image(uiImage: $0) }
        return ChatAttachment(type: .image, name: baseName + ".jpg", thumbnail: thumbnail, data: jpeg)
    }

    /// Decodes image data in any ImageIO-supported format (HEIC, RAW, WebP…) with
    /// EXIF orientation applied. Large images are decoded straight at ≤ 4096 px on
    /// the long side, so a 48 MP photo never needs to be fully decoded in memory.
    static func decodeImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }

    /// Small thumbnail for the composer tile (avoids decoding the full image for display).
    static func makeThumbnail(from data: Data, maxPixel: CGFloat = 320) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    // MARK: Scans

    /// One scanned page → an image attachment; several → a single multi-page PDF.
    static func makeScanAttachment(pages: [UIImage]) -> ChatAttachment? {
        guard !pages.isEmpty else { return nil }
        let stamp = Int(Date.now.timeIntervalSince1970)
        if pages.count == 1 {
            return makeImageAttachment(image: pages[0], name: "Scan_\(stamp)")
        }
        guard let pdf = makePDF(pages: pages) else { return nil }
        let thumbnail = pages.first.flatMap { page -> UIImage? in
            makeThumbnail(from: page.jpegData(compressionQuality: 0.7) ?? Data())
        }.map { Image(uiImage: $0) }
        return ChatAttachment(type: .file, name: "Scan_\(stamp) (\(pages.count) pages).pdf",
                              thumbnail: thumbnail, data: pdf)
    }

    /// Renders pages into a PDF (US Letter width, each page keeps its aspect ratio).
    /// Pages are re-encoded as JPEG through the same 4 MP cap, keeping the PDF small.
    static func makePDF(pages: [UIImage]) -> Data? {
        let pageWidth: CGFloat = 612
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: 792))
        let data = renderer.pdfData { context in
            for page in pages {
                let jpeg = downsampleForUpload(image: page)
                guard let compressed = UIImage(data: jpeg), compressed.size.width > 0 else { continue }
                let height = pageWidth * compressed.size.height / compressed.size.width
                let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: height)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                compressed.draw(in: bounds)
            }
        }
        return data.isEmpty ? nil : data
    }
}
