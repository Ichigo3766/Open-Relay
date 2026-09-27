import Foundation
import Darwin

@main struct ParserChecks {
    static var checks = 0
    static func signature(_ segments: [ContentSegment]) -> [[String?]] {
        segments.map {
            switch $0 {
            case .text(let text): return ["text", text]
            case .reasoning(let value):
                return ["reasoning", value.id, value.summary, value.content, value.duration,
                        String(value.isDone), String(value.characterCount)]
            case .toolCall(let value):
                return ["tool", value.name, value.arguments, value.result, String(value.isDone), value.status]
                    + value.embeds.map { Optional($0) }
            }
        }
    }
    static func compare(_ input: String) {
        let current = ToolCallParser.parseOrdered(input)
        let original = ReferenceToolCallParser.parseOrdered(input)
        precondition(signature(current.segments) == signature(original.segments))
        precondition(signature(current.allToolCalls.map(ContentSegment.toolCall)) == signature(original.allToolCalls.map(ContentSegment.toolCall)))
        checks += 2
    }
    static func wrapped(_ body: String, complete: Bool = true) -> String {
        "<details type=\"reasoning\" done=\"\(complete)\"><summary>Thinking</summary>" + body
            + (complete ? "</details>\n\nAn invented answer." : "")
    }
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func main() {
        let pairs = [("<think>", "</think>"), ("<thinking>", "</thinking>"),
                     ("<thought>", "</thought>"), ("<reason>", "</reason>"),
                     ("<reasoning>", "</reasoning>"), ("◁think▷", "◁/think▷"),
                     ("<|begin_of_thought|>", "<|end_of_thought|>")]
        let bodies = ["", "An invented copper telescope.", "星 🌙 e\u{301} 👨‍👩‍👧‍👦",
                      "&quot;&amp;&lt;&gt;&apos;&#x27;&#39;", "&amp;lt; &amp;quot; &unknown;",
                      "3 < 7 > 2", "<details><summary>Inner</summary>Body</details>"]
        var fixtures = bodies
        for (open, close) in pairs {
            for (start, end) in [(open, close), (open.uppercased(), close.uppercased()),
                                 (open.capitalized, close), (open, close.uppercased())] {
                for body in bodies {
                    for mark in ["", "\u{301}", "\u{FE0F}", "\u{200D}🌙"] {
                        fixtures += [start + mark + body + end + mark + " Answer.",
                                     start + mark + body, wrapped(body + end + mark + " Answer.")]
                    }
                }
            }
        }
        fixtures += ["<thİnk>Unicode.</thİnk>", "<thınk>Unicode.</thınk>",
                     "<reaſoning>Unicode.</reaſoning>",
                     "<details type='tool_calls' name='lookup' arguments='&quot;x&quot;' done='false'><summary>Tool</summary>Partial result",
                     "<details type=\"tool_calls\" name=\"lookup\" result=\"3 > 2 &amp; 1 < 2\"><summary>Tool</summary></details>"]
        for body in bodies {
            for done in [false, true] {
                let input = wrapped(body, complete: done)
                for end in input.indices { compare(String(input[..<end])) }
                fixtures.append(input)
            }
        }
        for input in fixtures { compare(input) }
        // Exercise Foundation's non-ASCII case equivalents inside marker names.
        // These are independent of the candidate regex's interpretation.
        let letters = Set(pairs.map { $0.0 + $0.1 }.joined().filter { $0.isLetter })
        for value in Array(0...0x2fff) + Array(0xff00...0xffff) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let variant = String(scalar)
            for letter in letters where variant.compare(String(letter), options: .caseInsensitive) == .orderedSame {
                for (open, close) in pairs where open.contains(letter) {
                    let start = open.replacingOccurrences(of: String(letter), with: variant)
                    let end = close.replacingOccurrences(of: String(letter), with: variant)
                    compare(start + "Synthetic thought." + end + " Answer.")
                    compare(wrapped("Synthetic thought." + end + " Answer."))
                }
            }
        }
        // Deterministic mixtures exercise replacement ordering and malformed tags.
        var seed: UInt64 = 123456789
        for _ in 0..<4000 {
            seed = seed &* 6364136223846793005 &+ 1
            let a = fixtures[Int(seed % UInt64(fixtures.count))]
            seed = seed &* 6364136223846793005 &+ 1
            let b = fixtures[Int(seed % UInt64(fixtures.count))]
            compare(a + "\n\n" + b)
        }
        print("PARSER_SCAN checks=\(checks) passed")
        guard CommandLine.arguments.contains("--benchmark") else { return }
        var checksum = 0
        for count in [10, 100, 1000, 3000] {
            for unicode in [false, true] {
                let line = unicode ? "星 🌙 e\u{301} 👨‍👩‍👧‍👦 Invented telescope.\n\n" : "A silver compass marks an invented trail.\n\n"
                let body = String(repeating: line, count: count)
                let input = wrapped(body, complete: false)
                compare(input)
                for candidate in [false, true, true, false] {
                    var samples: [Double] = []
                    for _ in 0..<15 {
                        let start = cpu()
                        let segments = candidate ? ToolCallParser.parseOrdered(input).segments : ReferenceToolCallParser.parseOrdered(input).segments
                        checksum += segments.count
                        samples.append((cpu() - start) * 1000)
                    }
                    samples.sort()
                    print("PARSER_BENCH chars=\(body.count) unicode=\(unicode) candidate=\(candidate) median_ms=\(samples[7]) p95_ms=\(samples[14])")
                }
            }
        }
        print("CHECKSUM \(checksum)")
    }
}
