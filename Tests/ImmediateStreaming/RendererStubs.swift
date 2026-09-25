import AppKit
import SwiftUI
import MarkdownParser

// macOS component tests drive the same reveal controller without an iOS screen.
// Native tests use the real CADisplayLink and UIKit renderer.
final class CADisplayLink: NSObject {
    private let target: NSObject
    private let selector: Selector
    private var timer: Timer?
    var timestamp = ProcessInfo.processInfo.systemUptime
    var targetTimestamp: Double { timestamp + 1.0 / 60 }
    var preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    init(target: NSObject, selector: Selector) { self.target = target; self.selector = selector }
    func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(fire), userInfo: nil, repeats: true)
        self.timer = timer
        runLoop.add(timer, forMode: mode)
    }
    @objc private func fire() {
        timestamp = ProcessInfo.processInfo.systemUptime
        _ = target.perform(selector, with: self)
    }
    func invalidate() { timer?.invalidate(); timer = nil }
}

enum RenderedTextContent { typealias Map = [String: String] }
struct MarkdownTheme: Equatable {
    struct Fonts: Equatable { var body: Font = .init() }
    struct Font: Equatable { var lineHeight: CGFloat = 20 }
    var fonts = Fonts()
    static let `default` = Self()
}
public enum MarkdownTextView {
    public final class PreprocessedContent {
        let blocks: [MarkdownBlockNode]
        var rendered: RenderedTextContent.Map
        let highlightMaps: [Int: Int]
        init(blocks: [MarkdownBlockNode], rendered: RenderedTextContent.Map, highlightMaps: [Int: Int]) {
            self.blocks = blocks; self.rendered = rendered; self.highlightMaps = highlightMaps
        }
        init(parserResultNoMath result: MarkdownParser.ParseResult) {
            blocks = result.document; rendered = [:]; highlightMaps = [:]
        }
        convenience init(parserResult: MarkdownParser.ParseResult, theme: MarkdownTheme) {
            self.init(parserResultNoMath: parserResult)
        }
    }
}
@MainActor struct MarkdownView: NSViewRepresentable {
    typealias PreprocessedContent = MarkdownTextView.PreprocessedContent
    static var made = 0
    let content: PreprocessedContent
    init(_ content: PreprocessedContent, theme: MarkdownTheme) { self.content = content }
    func codeAutoScroll(_ value: Bool) -> Self { self }
    func makeNSView(context: Context) -> NSTextField {
        Self.made += 1
        return NSTextField(labelWithString: "Synthetic text view")
    }
    func updateNSView(_ view: NSTextField, context: Context) {}
}
@MainActor final class MarkdownBlockRenderCache {
    static let shared = MarkdownBlockRenderCache()
    func lookup(content: String, theme: MarkdownTheme) -> [MarkdownView.PreprocessedContent]? { nil }
    func build(content: String, theme: MarkdownTheme,
               completion: @escaping @MainActor ([MarkdownView.PreprocessedContent]) -> Void) {
        completion(MarkdownView.PreprocessedContent(parserResultNoMath: MarkdownParser().parse(content)).split())
    }
}

@MainActor struct StreamingCodeBlockView: NSViewRepresentable {
    static var made = 0
    static var lastContent = ""
    let language: String
    let content: String
    let isStreaming: Bool
    let theme: MarkdownTheme
    func makeNSView(context: Context) -> NSTextField {
        Self.made += 1
        Self.lastContent = content
        return NSTextField(labelWithString: "Synthetic code view")
    }
    func updateNSView(_ view: NSTextField, context: Context) { Self.lastContent = content }
}
