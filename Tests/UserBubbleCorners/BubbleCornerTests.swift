import SwiftUI
import XCTest
@testable import BubbleTestHost

@MainActor final class BubbleCornerTests: XCTestCase {
    func testShortBubbleHasMatchingCorners() throws {
        try assertSymmetricBubble(width: 140, height: 20)
    }

    func testMultilineBubbleHasMatchingCorners() throws {
        try assertSymmetricBubble(width: 230, height: 120)
    }

    func testSmallBubbleClampsCornersSymmetrically() throws {
        try assertSymmetricBubble(width: 4, height: 4)
    }

    func testDarkBubbleHasMatchingCorners() throws {
        try assertSymmetricBubble(width: 230, height: 120, scheme: .dark)
    }

    func testRightToLeftBubbleHasMatchingCorners() throws {
        try assertSymmetricBubble(width: 230, height: 60, direction: .rightToLeft)
    }

    /// Render the real component without text so only the clipping outline is measured.
    private func assertSymmetricBubble(width: CGFloat, height: CGFloat,
                                       scheme: ColorScheme = .light,
                                       direction: LayoutDirection = .leftToRight) throws {
        let renderer = ImageRenderer(content:
            ChatMessageBubble(role: .user) {
                Color.clear.frame(width: width, height: height)
            }
            .frame(width: 390)
            .environment(\.theme, AppTheme(colorScheme: scheme))
            .environment(\.layoutDirection, direction))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * image.width + x) * 4 + 3]) }
        var left = image.width, right = 0, top = image.height, bottom = 0
        for y in 0..<image.height {
            for x in 0..<image.width where alpha(x, y) > 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        XCTAssertLessThan(left, right, "A visible bubble must be rendered")
        XCTAssertLessThan(top, bottom)
        guard left < right, top < bottom else { return }
        var horizontalDifference = 0, verticalDifference = 0
        for y in top...bottom {
            for x in left...right {
                horizontalDifference += abs(alpha(x, y) - alpha(left + right - x, y))
                verticalDifference += abs(alpha(x, y) - alpha(x, top + bottom - y))
            }
        }
        // Ignore tiny antialiasing differences, but reject unequal corner radii.
        let area = Double((right - left + 1) * (bottom - top + 1))
        XCTAssertLessThan(Double(horizontalDifference) / area, 0.5, "Left and right corners must match")
        XCTAssertLessThan(Double(verticalDifference) / area, 0.5, "Top and bottom corners must match")
    }

    func testLightExamples() throws { try captureExamples(scheme: .light) }
    func testDarkExamples() throws { try captureExamples(scheme: .dark) }

    private func captureExamples(scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: BubbleExamples()
            .frame(width: 375, height: 650)
            .environment(\.theme, AppTheme(colorScheme: scheme))
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = scheme == .dark ? "dark-bubbles" : "light-bubbles"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
