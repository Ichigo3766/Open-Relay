import AppKit
import SwiftUI
import MarkdownParser

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
