import Litext
@testable import ReasoningHost
import SwiftUI
import XCTest

@MainActor
final class RenderingTests: XCTestCase {
    private let paragraph = "A copper telescope stands beside a blue notebook. Seven paper stars mark the imaginary map. A quiet observatory records the changing colors of the sky, then stores the numbered sketch for another evening."

    func testBaselineLongTextExpansion() throws {
        try measureExpansion(native: false)
    }

    func testNativeLongTextExpansion() throws {
        try measureExpansion(native: true)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settle(_ window: UIWindow) {
        window.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    func testLiteralTextStreamingStyleAndWidthChanges() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let controller = UIHostingController(rootView: ScrollView { ReasoningText(text: "").frame(width: 320) })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        for text in ["", "Short plain text.", "**Literal asterisks**\n\n    Indented text\n\n星と月 👨‍👩‍👧‍👦 café", String(repeating: paragraph + "\n\n", count: 512), String(repeating: "星👨‍👩‍👧‍👦e\u{301}", count: 1000), "\n\r\n   \t", String(repeating: "LongUnbrokenText", count: 1000)] {
            controller.rootView = ScrollView { ReasoningText(text: text, fontSize: 18, color: .systemPurple).frame(width: 320) }
            settle(window)
            let label = try XCTUnwrap(descendants(window).compactMap { $0 as? LTXLabel }.first)
            XCTAssertEqual(label.attributedText.string, text)
            XCTAssertTrue(label.isSelectable)
            if !text.isEmpty {
                XCTAssertEqual((label.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 18)
                XCTAssertEqual(label.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .systemPurple)
            }
        }
        let text = String(repeating: paragraph, count: 20)
        controller.rootView = ScrollView { ReasoningText(text: text).frame(width: 320) }
        settle(window)
        let label = try XCTUnwrap(descendants(window).compactMap { $0 as? LTXLabel }.first)
        let wideHeight = label.bounds.height
        controller.rootView = ScrollView { ReasoningText(text: text).frame(width: 160) }
        settle(window)
        XCTAssertEqual(label.bounds.width, 160, accuracy: 1)
        XCTAssertGreaterThan(label.bounds.height, wideHeight * 1.5)
    }

    func testNativeLabelLaysOutAndSelectsEntireText() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let text = String(repeating: paragraph + "\n\n", count: 512)
        let controller = UIHostingController(rootView: ScrollView {
            ReasoningText(text: text).padding(24)
        })
        controller.view.backgroundColor = .white
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle(window)
        let views = descendants(window)
        let label = try XCTUnwrap(views.compactMap { $0 as? LTXLabel }.first)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(label.attributedText.string, text)
        XCTAssertEqual(label.preferredMaxLayoutWidth, label.bounds.width, accuracy: 0.5,
                       "Resolve the proposed width before placement instead of correcting the height afterward.")
        XCTAssertGreaterThan(label.bounds.height, 30000)
        XCTAssertLessThanOrEqual(label.bounds.width, window.bounds.width - 48)
        XCTAssertGreaterThan(scroll.contentSize.height, 30000)
        label.selectionRange = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertEqual(label.selectedPlainText(), text)
        label.clearSelection()
        for offset in [CGFloat.zero, scroll.contentSize.height / 2, scroll.contentSize.height - scroll.bounds.height] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            settle(window)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 255, count: cgImage.width * cgImage.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            var ink = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[index] < 150, pixels[index + 1] < 150, pixels[index + 2] < 150, pixels[index + 3] > 200 {
                    ink += 1
                }
            }
            XCTAssertGreaterThan(ink, 1000, "The whole viewport must contain rendered text, not just accessible text.")
            XCTAssertLessThan(ink, cgImage.width * cgImage.height / 3, "A dark background is not evidence of rendered text.")
            let drawing = try XCTUnwrap(descendants(label).first { String(describing: type(of: $0)).contains("DrawingView") })
            XCTAssertLessThan(drawing.bounds.height, window.bounds.height * 2)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Synthetic native reasoning at offset \(Int(offset))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func measureExpansion(native: Bool) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let text = (1 ... 512).map { "Observation \($0)\n" + paragraph }.joined(separator: "\n\n")
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let controller = UIHostingController(rootView:
                ScrollView {
                    Group {
                        if native {
                            ReasoningText(text: text)
                        } else {
                            Text(text)
                        }
                    }
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(24)
                })
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.rootViewController = nil
        }
    }
}
