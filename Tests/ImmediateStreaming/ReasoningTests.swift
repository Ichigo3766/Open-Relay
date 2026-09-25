import Foundation

@main struct ReasoningTests {
    static let pairs = [
        ("<|begin_of_thought|>", "<|end_of_thought|>"), ("◁think▷", "◁/think▷"),
        ("<thinking>", "</thinking>"), ("<reasoning>", "</reasoning>"),
        ("<thought>", "</thought>"), ("<reason>", "</reason>"), ("<think>", "</think>"),
    ]
    static let body = "Cafe\u{301} 👩🏽‍🚀 星 مرحبا. Invented paper stars."
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { fatalError("Failed: \(label)") }
        }
        var fixtures = ["", "An invented answer.", body]
        for (open, close) in pairs {
            for (start, end) in [(open, close), (open.uppercased(), close.uppercased()), (open.capitalized, close.capitalized)] {
                fixtures += [start + body, start + body + end + " Answer.", body + end,
                             start + body + end + start + "Another thought.", end]
                // Pipe/triangle variants preserve their existing case-sensitive gate.
                if start == open || (!open.hasPrefix("<|") && !open.hasPrefix("◁")) {
                    let result = ToolCallParser.parseAll(start + body + end + " Answer.")
                    check(result.reasoning.first?.content == body, "reasoning content \(start)")
                    check(result.reasoning.first?.isDone == true, "completion \(start)")
                    check(result.cleanedContent == "Answer.", "answer separation \(start)")
                    #if !REASONING_BASELINE
                    if !CommandLine.arguments.contains("--dump"), let reasoning = result.reasoning.first {
                        check(reasoning.characterCount == reasoning.content.count, "cached grapheme count")
                        for count in 0...reasoning.characterCount + 1 {
                            let tailTrimmed = String(reasoning.content.dropLast(max(0, reasoning.characterCount - count)))
                            check(tailTrimmed == String(reasoning.content.prefix(count)), "tail-based Unicode reveal \(count)")
                        }
                    }
                    #endif
                }
            }
        }
        let blocks = fixtures
        for first in blocks.dropFirst(3) {
            for second in blocks.dropFirst(3) {
                fixtures.append(first + "\n\n" + second)
            }
        }
        for inner in blocks {
            for suffix in ["", "</details>", "</details> Answer."] {
                fixtures.append("<details type=\"reasoning\"><summary>Thinking</summary>" + inner + suffix)
            }
        }
        if CommandLine.arguments.contains("--dump") {
            // No content-derived/random IDs: compare parser semantics across revisions.
            for input in fixtures {
                let result = ToolCallParser.parseAll(input)
                let output: [String: Any] = ["input": input, "answer": result.cleanedContent,
                    "reasoning": result.reasoning.map { ["text": $0.content, "done": $0.isDone, "summary": $0.summary] },
                    "tools": result.toolCalls.map { $0.name }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
            }
            return
        }
        for size in [1_000, 10_000, 100_000] {
            let text = "<details type=\"reasoning\"><summary>Thinking</summary>"
                + String(repeating: "An invented copper telescope.\n\n", count: size / 30)
            var times: [Double] = []
            for _ in 0..<12 {
                let start = ProcessInfo.processInfo.systemUptime
                let parsed = ToolCallParser.parseAll(text)
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                check(parsed.reasoning.count == 1, "large reasoning result")
            }
            times.sort()
            print("REASONING_PARSE chars=\(size) median_ms=\(times[times.count / 2])")
        }
        print("REASONING RESULT checks=\(checks) fixtures=\(fixtures.count)")
    }
}
