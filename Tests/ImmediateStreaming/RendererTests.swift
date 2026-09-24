import AppKit
import SwiftUI
import MarkdownParser

@MainActor final class RenderState: ObservableObject {
    @Published var text = ""
    @Published var streaming = true
}
struct RenderFixture: View {
    @ObservedObject var state: RenderState
    var body: some View {
        StableStreamingMarkdown(text: state.text, isStreaming: state.streaming, theme: .default)
    }
}
@main struct RendererTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL \(name)") }
        }
        let sentence = "A synthetic copper telescope stands beside an imaginary blue notebook. "
        let fence = String(repeating: "\u{0060}", count: 4)
        let fixtures = [
            ("plain", String(repeating: sentence, count: 6)),
            ("list", (1...5).map { "1. Item \($0). " + sentence }.joined(separator: "\n\n")),
            ("tilde", "~~~text\n" + String(repeating: sentence + "\n\n", count: 5) + "~~~"),
            ("backtick", fence + "text\n\n" + sentence + "\n" + fence),
            ("quote", "> " + sentence + "\n>\n> " + sentence),
            ("reference", "[a][ref]\n\nParagraph\n\n[ref]: https://example.com"),
        ]
        for (name, text) in fixtures {
            let parser = StreamingMarkdownParser()
            for count in stride(from: 1, through: text.count, by: 7) {
                let partial = String(text.prefix(count))
                let chunks = await parser.parse(partial)
                check(chunks.flatMap(\.blocks) == MarkdownParser().parse(partial).document, "\(name) prefix \(count)")
            }
            let actual = await parser.parse(text)
            check(actual.flatMap(\.blocks) == MarkdownParser().parse(text).document, "\(name) complete AST")
            let original = IncrementalStreamingParser()
            _ = original.parse(String(text.prefix(text.count / 2)), theme: .default)
            let baseline = original.parse(text, theme: .default)
            if name == "list" || name == "tilde" {
                check(baseline.blocks != MarkdownParser().parse(text).document, "\(name) baseline defect reproduced")
            }
        }
        let parser = StreamingMarkdownParser()
        let genericFence = String(repeating: "\u{0060}", count: 3)
        for language in ["text", "swift", "javascript", ""] {
            let open = "Intro.\n\n" + genericFence + language + "\n" + sentence
            let closed = open + "\n" + genericFence + "\n\nOutro."
            for text in [open, closed] {
                let segments = SegmentParsingHarness(isStreaming: true).segments(text)
                check(segments.count == 1 && segments.first?.id == "md-0", "generic fence retains document parent")
                if case .markdown(let value) = segments.first?.kind {
                    check(value == text, "generic fence preserves exact source")
                } else { check(false, "generic fence stays Markdown") }
            }
        }
        for language in ["html", "svg", "mermaid", "chart"] {
            let code = language == "svg" ? "<svg>synthetic</svg>" :
                language == "html" ? "<p>synthetic</p>" :
                language == "mermaid" ? "graph TD; A-->B" : "{\"data\": []}"
            let open = "Intro.\n\n" + genericFence + language + "\n" + code
            let live = SegmentParsingHarness(isStreaming: true).segments(open)
            let final = SegmentParsingHarness(isStreaming: false).segments(open + "\n" + genericFence)
            check(live.map(\.id) == final.map(\.id), "preview identity survives close: \(language)")
        }
        let long = String(repeating: sentence + "\n\n", count: 160)
        let before = await parser.parse(long)
        let after = await parser.parse(long + "New paragraph.")
        check(before.count > 1, "long prose bounded chunks")
        check(before[0] === after[0], "unchanged chunk object reused")
        let replaced = await parser.parse("Replacement.")
        check(replaced.flatMap(\.blocks) == MarkdownParser().parse("Replacement.").document, "replacement clears old chunks")
        for size in [1000, 10000, 100000] {
            let content = String(repeating: sentence + "\n\n", count: max(1, size / sentence.count))
            var times: [Double] = []
            for trial in 0..<20 {
                let started = ProcessInfo.processInfo.systemUptime
                _ = await parser.parse(content + String(repeating: "x", count: trial))
                times.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
            times.sort()
            print("PARSE chars=\(content.count) median_ms=\(times[10]) p95_ms=\(times[18])")
        }
        for text in [sentence, long, "~~~swift\nlet star = 7\n~~~"] {
            MarkdownView.made = 0
            StreamingCodeBlockView.made = 0
            let state = RenderState()
            state.text = text
            let host = NSHostingView(rootView: RenderFixture(state: state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let before = MarkdownView.made + StreamingCodeBlockView.made
            state.streaming = false
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            check(before > 0 && MarkdownView.made + StreamingCodeBlockView.made == before,
                  "native views survive completion, chars \(text.count)")
            if text.hasPrefix("~~~") {
                check(StreamingCodeBlockView.made == 1, "code uses one dedicated native view")
                check(StreamingCodeBlockView.lastContent == "let star = 7", "parser newline does not defeat native append path")
            }
            window.contentView = nil
        }
        print("RENDER RESULT checks=\(checks) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}
