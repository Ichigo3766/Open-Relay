import XCTest
import SwiftUI
import Vision
import Litext

@MainActor final class RegressionChecks: XCTestCase {
    func text(_ rows: Int) -> String {
        let objects = (0..<rows).map { ["row": "\($0)", "moon": "invented-violet", "note": "An imaginary observatory sample."] }
        return String(data: try! JSONSerialization.data(withJSONObject: objects), encoding: .utf8)!
    }
    func labels(_ root: UIView) -> [LTXLabel] {
        (root as? LTXLabel).map { [$0] } ?? root.subviews.flatMap(labels)
    }
    func testSmallAndLargeOutputVisibleAndSelectable() async throws {
        for count in [8, 2000] {
            let content = text(count)
            let controller = UIHostingController(rootView: ToolCallResultBlockView(content: content).padding(16))
            let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image:image); attachment.name = "synthetic-\(count)-rows"; attachment.lifetime = .keepAlways; add(attachment)
            try await Task.sleep(for:.seconds(2))
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
            let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            XCTAssertTrue(visible.contains("imaginary") || visible.contains("invented"), "Visible output must contain actual text: " + visible)
            let label = try XCTUnwrap(labels(controller.view).first)
            XCTAssertTrue(label.isSelectable)
            let full = try XCTUnwrap(label.attributedText.string)
            let parsed = try JSONSerialization.jsonObject(with: Data(full.utf8)) as! [[String: String]]
            XCTAssertEqual(parsed.count, count)
            XCTAssertEqual(parsed.last?["row"], "\(count - 1)")
            let font = try XCTUnwrap(label.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        }
    }
    func testLongLineKeepsHorizontalScrolling() async throws {
        let content = "Invented moon " + String(repeating: "0123456789", count: 100)
        let controller = UIHostingController(rootView: ToolCallResultBlockView(content: "Invented moon").padding(16))
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.frame = CGRect(x:0,y:0,width:390,height:844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for:.milliseconds(300)); window.layoutIfNeeded()
        controller.rootView = ToolCallResultBlockView(content:content).padding(16)
        try await Task.sleep(for:.milliseconds(300)); window.layoutIfNeeded()
        func scrolls(_ root:UIView) -> [UIScrollView] {
            (root as? UIScrollView).map { [$0] } ?? root.subviews.flatMap(scrolls)
        }
        let scroll = try XCTUnwrap(scrolls(controller.view).first { $0.contentSize.width > $0.bounds.width + 100 })
        scroll.setContentOffset(CGPoint(x:100,y:0), animated:false)
        XCTAssertEqual(scroll.contentOffset.x,100,accuracy:1)
        XCTAssertEqual(labels(controller.view).first?.attributedText.string,content)
    }
    func testPreviewPreservesUnicodeAndCompleteContent() async throws {
        let content = "Invented moon 🌙\n" + text(2000)
        let controller = UIHostingController(rootView: ToolCallResultFullPreviewSheet(content:content))
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.frame = CGRect(x:0,y:0,width:390,height:844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for:.milliseconds(300)); window.layoutIfNeeded()
        let label = try XCTUnwrap(labels(controller.view).first)
        XCTAssertEqual(label.attributedText.string,content)
        XCTAssertTrue(label.isSelectable)
    }

}
