import Foundation

@main
@MainActor
struct ParserChecks {
    static var checks = 0
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func signature(_ segments: [ContentSegment]) -> [[String?]] {
        segments.map { segment in
            switch segment {
            case .text(let text): return ["text", text]
            case .reasoning(let value):
                return ["reasoning", value.id, value.summary, value.content, value.duration, String(value.isDone)]
            case .toolCall(let value):
                // A missing tool ID is deliberately random on each parse.
                return ["tool", value.name, value.arguments, value.result, String(value.isDone), value.status] + value.embeds.map { Optional($0) }
            }
        }
    }

    static func compare(_ input: String, label: String) {
        let actual = ToolCallParser.parseOrdered(input)
        let reference = ReferenceToolCallParser.parseOrdered(input)
        expect(signature(actual.segments) == signature(reference.segments), "segment equivalence: \(label)")
        expect(signature(actual.allToolCalls.map(ContentSegment.toolCall)) == signature(reference.allToolCalls.map(ContentSegment.toolCall)), "tool equivalence: \(label)")
    }

    static func wrapped(_ body: String) -> String {
        "<details type=\"reasoning\" done=\"true\"><summary>Thinking</summary>\(body)</details>\n\nAn invented answer."
    }

    static func main() {
        print("Runtime: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let pairs = [
            ("<|begin_of_thought|>", "<|end_of_thought|>"), ("◁think▷", "◁/think▷"),
            ("<thinking>", "</thinking>"), ("<reasoning>", "</reasoning>"),
            ("<thought>", "</thought>"), ("<reason>", "</reason>"), ("<think>", "</think>"),
        ]
        let prefixes = ["", "An invented preface. ", "星 👨‍👩‍👧‍👦 e\u{301} "]
        for (index, pair) in pairs.enumerated() {
            for suffix in ["\u{301}", "\u{FE0F}", "\u{200D}🌙", "\u{200C}"] {
                compare(pair.0 + suffix + "Synthetic thought." + pair.1 + suffix, label: "tag \(index), adjacent Unicode")
                compare(wrapped("Synthetic thought." + pair.1 + suffix + " Answer."), label: "tag \(index), Unicode spillover")
            }
            for prefix in prefixes {
                for (open, close) in [pair, (pair.0.uppercased(), pair.1.uppercased()), (pair.0, pair.1.uppercased())] {
                    let variants = [
                        prefix + open + "Synthetic thought." + close + " Final answer.",
                        prefix + open + "Unfinished synthetic thought.",
                        prefix + "Orphan thought." + close + " Final answer.",
                        wrapped(prefix + "Synthetic thought." + close + " Final answer."),
                        prefix + open + "First." + close + open + "Second." + close,
                        prefix + "`" + open + "quoted" + close + "`",
                    ]
                    for (variant, input) in variants.enumerated() {
                        compare(input, label: "tag \(index), variant \(variant)")
                    }
                }
            }
        }

        let details = [
            "", "Plain invented prose.", "Literal **bold** and 3 < 7.",
            wrapped("星 🌙 e\u{301} synthetic body"),
            "<details type='reasoning' done='true' duration='2'><summary>Invented summary</summary>Body.</details>Answer.",
            "<details type=\"reasoning\" done=\"false\"><summary>Thinking</summary>Still working",
            "<details type=\"reasoning\"><summary>Outer</summary><details><summary>Inner</summary>Nested body</details></details>",
            "<details type=\"tool_calls\" id=\"fixture-1\" name=\"lookup\" done=\"true\" arguments=\"{&quot;n&quot;:1}\" result=\"3 > 2 &amp; 1 < 2\"><summary>Tool</summary></details>",
            "<details type='tool_calls' name='lookup' done='false'><summary>Tool</summary>Partial result",
            "<details type='tool_calls' name='lookup' done='true'><summary>Tool</summary>Body result.</details>",
            "<details type=\"reasoning\" done=\"true\"><summary>Thinking</summary>Literal &lt;think&gt; marker.</details>",
            "<thİnk>Unicode case.</thİnk>", "<thınk>Unicode case.</thınk>",
            "<reaſoning>Unicode case.</reaſoning>", "<think\u{301}>Combining mark.</think\u{301}>",
            "<ThInK>Mixed case.</tHiNk>",
        ]
        for (index, input) in details.enumerated() {
            compare(input, label: "details \(index)")
            // Exercise every partial prefix, including incomplete opening/closing
            // tags and quoted attributes, as seen during incremental streaming.
            for length in 0...input.count {
                compare(String(input.prefix(length)), label: "details \(index), prefix \(length)")
            }
        }

        let parsed = ToolCallParser.parseAll(wrapped("Synthetic thought."))
        expect(parsed.reasoning.count == 1, "completed reasoning remains separate")
        expect(parsed.reasoning.first?.content == "Synthetic thought.", "reasoning body is intact")
        expect(parsed.reasoning.first?.isDone == true, "completed state is intact")
        expect(parsed.cleanedContent == "An invented answer.", "final answer stays outside reasoning")

        if CommandLine.arguments.contains("--benchmark") { benchmark() }
        print("ReasoningParsing: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }

    static func benchmark() {
        let body = String(repeating: "A silver compass marks an invented trail. Seven paper flags stand beside a quiet observatory.\n\n", count: 1250)
        let input = wrapped(body)
        _ = ToolCallParser.parseOrdered(input)
        _ = ReferenceToolCallParser.parseOrdered(input)
        var current: [Double] = [], reference: [Double] = []
        for iteration in 0..<9 {
            // Alternate order to reduce first-run/host-load bias.
            for baselineFirst in [iteration.isMultiple(of: 2), !iteration.isMultiple(of: 2)] {
                let start = ProcessInfo.processInfo.systemUptime
                let segments = baselineFirst
                    ? ReferenceToolCallParser.parseOrdered(input).segments
                    : ToolCallParser.parseOrdered(input).segments
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                expect(segments.count == 2, "benchmark parses reasoning and final answer")
                if baselineFirst { reference.append(elapsed) } else { current.append(elapsed) }
            }
        }
        let old = reference.sorted()[reference.count / 2]
        let new = current.sorted()[current.count / 2]
        print(String(format: "Synthetic %d-character body: reference %.2f ms, current %.2f ms (median of 9 each)", body.count, old * 1000, new * 1000))
        // Opt in on a runtime exhibiting the slow reference search path. Older
        // Foundation implementations may already have an efficient search path.
        if CommandLine.arguments.contains("--require-speedup") {
            expect(new < old * 0.5, "optimized median is less than half the reference parser")
        }
    }
}
