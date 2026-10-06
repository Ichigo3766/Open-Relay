import SwiftUI
import PhotosUI
import UIKit
import ImageIO

// MARK: - Model Background Image
//
// Mirrors the web ModelEditor "Background Image" control. The image is uploaded to
// `/api/v1/files/?process=false` and referenced as `meta.background_image_url =
// /api/v1/files/{id}/content`. The server only accepts that exact URL shape and
// validates the bytes: PNG / JPEG / WebP / GIF, ≤ 5 MiB, ≤ 25 megapixels.

enum ModelBackgroundImage {
    static let maxBytes = 5 * 1024 * 1024
    static let maxPixels = 25_000_000

    struct Validated {
        let data: Data
        let fileName: String
        let preview: UIImage
    }

    enum ValidationError: LocalizedError {
        case tooLarge, badFormat, tooManyPixels, invalid
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Background image must be at most 5 MiB."
            case .badFormat: return "Background image must be PNG, JPEG, WebP, or GIF."
            case .tooManyPixels: return "Background image must be at most 25 megapixels."
            case .invalid: return "Invalid background image."
            }
        }
    }

    /// Client-side mirror of the server's `validate_background_image`.
    /// Picked photos are re-encoded as JPEG when they'd exceed the size limit
    /// (e.g. large HEIC/PNG camera images), so users don't hit a dead end.
    static func prepare(_ raw: Data) throws -> Validated {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw ValidationError.invalid }
        let uti = CGImageSourceGetType(source) as String?
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { throw ValidationError.invalid }

        let accepted: [String: String] = [
            "public.png": "png", "public.jpeg": "jpg", "org.webmproject.webp": "webp", "com.compuserve.gif": "gif"
        ]
        var data = raw
        var ext = uti.flatMap { accepted[$0] }

        // HEIC and other formats (common from the photo library): convert to JPEG.
        if ext == nil {
            guard let img = UIImage(data: raw), let jpeg = img.jpegData(compressionQuality: 0.9) else {
                throw ValidationError.badFormat
            }
            data = jpeg; ext = "jpg"
        }
        // Over the pixel cap → downscale (JPEG), rather than failing.
        if w * h > maxPixels, let img = UIImage(data: data) {
            let scale = (Double(maxPixels) / Double(w * h)).squareRoot() * 0.98
            let size = CGSize(width: Double(w) * scale, height: Double(h) * scale)
            let r = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            let resized = r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { throw ValidationError.tooManyPixels }
            data = jpeg; ext = "jpg"
        }
        // Over the byte cap → recompress stepwise.
        if data.count > maxBytes, let img = UIImage(data: data) {
            var q: CGFloat = 0.8
            var out = data
            while out.count > maxBytes, q > 0.2 {
                guard let d = img.jpegData(compressionQuality: q) else { break }
                out = d; q -= 0.15
            }
            guard out.count <= maxBytes else { throw ValidationError.tooLarge }
            data = out; ext = "jpg"
        }
        guard let preview = UIImage(data: data) else { throw ValidationError.invalid }
        return Validated(data: data, fileName: "background.\(ext ?? "jpg")", preview: preview)
    }

    /// Canonical URL the server accepts for `meta.background_image_url`.
    static func contentPath(forFileId id: String) -> String { "/api/v1/files/\(id)/content" }
}
