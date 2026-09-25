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
        // Exercise every reveal budget, including nested formatting, grapheme
        // clusters, ordered-list starts and atomic attachments.
        let revealFixtures = fixtures.map(\.1) + [
            "", "~~~text\n~~~", "- \n- Item",
            "# Heading **bold** and *italic* with `code` and ~~strike~~.",
            "- One\n  - Nested 👨‍👩‍👧‍👦 e\u{301} 星\n\n> Quote [link](https://example.com)",
            "3. Three\n4. Four\n\n- [x] Done\n- [ ] Pending",
            "> [!NOTE]\n> Synthetic note.",
            "| A | B |\n|---|---|\n| 1 | 2 |\n\n---\n\n$x^2$",
            "![image](https://example.com/image.png)\n\n<strong>Text</strong>",
        ]
        for text in revealFixtures {
            let nodes = MarkdownParser().parse(text).document
            let length = nodes.reduce(0) { $0 + RevealPrefix.length($1) }
            for amount in 0...length {
                var budget = amount
                let prefix = RevealPrefix.blocks(nodes, budget: &budget)
                check(prefix.reduce(0) { $0 + RevealPrefix.length($1) } == amount, "reveal consumes exact budget")
                if amount == length { check(prefix == nodes, "reveal restores exact final AST") }
            }
        }
        let reveal = StreamingTextReveal()
        let first = await parser.parse("Copper telescope.")
        reveal.receive(first, source: "Copper telescope.", streaming: true)
        check(reveal.isAnimating, "clock starts only with unrevealed text")
        check(reveal.chunks?.flatMap(\.blocks) != first.flatMap(\.blocks), "first snapshot is not a whole-chunk jump")
        reveal.advance(by: 1.0 / 60)
        let earlyLength = reveal.chunks?.flatMap(\.blocks).reduce(0) { $0 + RevealPrefix.length($1) } ?? 0
        check(earlyLength >= 2 && earlyLength <= 3, "one frame reveals characters")
        // Completion preserves an in-progress reveal rather than replacing it.
        reveal.receive(first, source: "Copper telescope.", streaming: false)
        check(reveal.isAnimating, "completion keeps remaining animation")
        reveal.advance(by: 1)
        check(!reveal.isAnimating && reveal.chunks?.first === first.first, "caught-up clock stops and target object survives")
        let next = await parser.parse("Copper telescope. Seven stars.")
        reveal.receive(next, source: "Copper telescope. Seven stars.", streaming: true)
        check(reveal.isAnimating, "arrival restarts stopped clock")
        reveal.receive(replaced, source: "Replacement.", streaming: true)
        check(!reveal.isAnimating && reveal.chunks?.first === replaced.first, "authoritative replacement cannot replay stale characters")
        let historical = StreamingTextReveal()
        historical.receive(before, source: long, streaming: false)
        check(!historical.isAnimating && historical.chunks?.count == before.count, "history never typewrites")
        let reduced = StreamingTextReveal()
        reduced.receive(before, source: long, streaming: true, reduceMotion: true)
        check(!reduced.isAnimating && reduced.chunks?.first === before.first, "Reduce Motion bypasses animation")
        let stable = StreamingTextReveal()
        stable.receive(before, source: long, streaming: true)
        stable.advance(by: 1)
        stable.receive(after, source: long + "New paragraph.", streaming: true)
        check(stable.chunks?.first === before.first, "animation preserves settled render objects")
        stable.finish()
        check(!stable.isAnimating, "disappearing view leaves no running clock")
        weak var released: StreamingTextReveal?
        do {
            let transient = StreamingTextReveal()
            transient.receive(first, source: "Copper telescope.", streaming: true)
            released = transient
        }
        check(released == nil, "clock does not retain the reveal controller")
        // Deterministic packet timing: callbacks do not need to sleep or rely
        // on the display-link stub. A fixed drain speed used to stop every batch.
        let paced = StreamingTypewriter()
        var inputCount = 0, previousCount = 0, lastChange = 0, largestGap = 0
        for frame in 0..<420 {
            if frame % 30 == 0 {
                inputCount += 20
                paced.receive(String(repeating: "x", count: inputCount), count: inputCount,
                              streaming: true, now: Double(frame) / 60)
            }
            paced.advance(by: 1.0 / 60)
            check(paced.visibleCount >= previousCount && paced.visibleCount <= inputCount,
                  "pacing never rewinds or invents characters")
            if paced.visibleCount > previousCount {
                if lastChange >= 60 { largestGap = max(largestGap, frame - lastChange) }
                lastChange = frame
            }
            previousCount = paced.visibleCount
        }
        check(largestGap <= 4, "steady packets have no repeated catch-up pauses after warmup: \(largestGap) frames")
        paced.finish()
        let delayed = StreamingTypewriter()
        var lastDelayedChange = 0, delayedCount = 0, delayedGap = 0
        for frame in 0..<240 {
            // First layout is late; subsequent packets keep their original cadence.
            if frame == 15 || (frame >= 30 && frame % 30 == 0) {
                let count = (frame / 30 + 1) * 20
                delayed.receive(String(repeating: "x", count: count), count: count,
                                streaming: true, now: Double(frame) / 60)
            }
            delayed.advance(by: 1.0 / 60)
            if delayed.visibleCount > delayedCount {
                if lastDelayedChange >= 60 { delayedGap = max(delayedGap, frame - lastDelayedChange) }
                lastDelayedChange = frame
            }
            delayedCount = delayed.visibleCount
        }
        check(delayedGap <= 9, "late first layout recovers to the 150 ms cadence budget: \(delayedGap) frames")
        delayed.finish()
        let burst = StreamingTypewriter()
        burst.receive(String(repeating: "x", count: 100_000), count: 100_000, streaming: true, now: 0)
        for _ in 0..<54 { burst.advance(by: 1.0 / 60) }
        check(burst.visibleCount == 100_000 && !burst.isAnimating, "one large burst finishes within 900 ms")
        burst.receive(String(repeating: "x", count: 100_020), count: 100_020, streaming: true, now: 2)
        burst.advance(by: 1.0 / 60)
        check(burst.visibleCount < 100_020, "a completed large burst must not make the next packet jump")
        burst.finish()
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
            // Let the bounded initial reveal finish before counting views.
            // Completion-during-reveal is checked separately above.
            for _ in 0..<90 {
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
