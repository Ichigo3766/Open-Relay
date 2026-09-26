import Foundation

// No inline images in these fixtures; keep the real history decoder UI-independent.
enum InlineImageStore {
    static func extractAndReplace(content: String) -> String { content }
}

@main enum RegressionTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func prose(_ result: ToolCallParser.OrderedParseResult) -> String {
        result.segments.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined()
    }

    static func main() async {
        // Literal tool source, not a formula. Sending this to SwiftMath can trap.
        let literal = #"Literal source: $$a\\{b\\c\\d$$"#
        let log = literal + String(repeating: "\nSynthetic build step completed.", count: 4000)
        let answer = "The log is complete."
        let legacy = """
        <details type="tool_calls" id="log" name="inspect_log" done="true"><summary>Tool Executed</summary>
        \(log)
        </details>

        \(answer)
        """
        let output: [[String: Any]] = [
            ["type": "function_call", "id": "log", "call_id": "log", "name": "inspect_log",
             "arguments": "{}", "status": "completed"],
            ["type": "function_call_output", "call_id": "log", "status": "completed",
             "output": [["type": "input_text", "text": log]]],
            ["type": "message", "content": [["type": "output_text", "text": answer]]],
        ]
        let structured = MessageHistory.parseNode(id: "answer", from: [
            "role": "assistant", "content": "", "output": output, "done": true,
        ]).content
        let math = "A valid equation: $x^2 + 1$."

        for content in [legacy, structured, math, ""] {
            let pending = pendingResult(content: content, resolvedResult: nil)
            check(pending.segments.isEmpty && pending.allToolCalls.isEmpty,
                  "An initial cache miss must not render unparsed content")
        }

        let cache = MessageParseCache()
        for content in [legacy, structured] {
            check(cache.lookupSync(content) == nil, "Fixture starts with a cold cache")
            let parsed = await cache.parseAndStore(content: content)
            check(parsed.allToolCalls.count == 1, "Tool result is preserved")
            check(parsed.allToolCalls.first?.result?.contains(literal) == true,
                  "Literal tool text is not lost")
            check(prose(parsed) == answer, "Only assistant prose reaches Markdown")
            check(cache.lookupSync(content)?.segments.map(\.id) == parsed.segments.map(\.id),
                  "Completed parse is available synchronously")
            let stale = pendingResult(content: content + " More text.", resolvedResult: parsed)
            check(stale.segments.map(\.id) == parsed.segments.map(\.id),
                  "Streaming retains the last parsed segments")
            check(stale.allToolCalls.map(\.id) == parsed.allToolCalls.map(\.id),
                  "Streaming retains the last parsed tools")
        }
        check(prose(ToolCallParser.parseOrdered(math)) == math,
              "Ordinary assistant math remains Markdown")
        print("PASS: cold fallback, legacy/structured tool separation, cache completion, stale result, ordinary math")
    }
}
