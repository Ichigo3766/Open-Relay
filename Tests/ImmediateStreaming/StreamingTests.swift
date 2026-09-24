import Foundation
import Darwin

@main
struct StreamingTests {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1; print("FAIL \(name)") }
    }
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        #if BASELINE
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        #else
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        #endif
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    @MainActor static func finish(_ store: StreamingContentStore, _ content: String,
                                  completion: @escaping @MainActor () -> Void = {}) {
        #if BASELINE
        store.updateContent(content)
        store.endStreaming(onDrained: completion)
        #else
        store.endStreaming(finalContent: content, onFinished: completion)
        #endif
    }
    @MainActor static func main() async {
        var samples: [StreamingSnapshot] = []
        let pipeline = StreamingPipeline { samples.append($0) }
        await pipeline.beginWithPrefix("")
        var text = ""
        for character in "A telescope 🔭, e\u{301}, 👨‍👩‍👧‍👦, 日本語 and a final period." {
            text.append(character)
            await pipeline.append(text)
            check(samples.last?.displayContent == text, "immediate Unicode \(text.count)")
        }
        let count = samples.count
        await pipeline.append(text)
        check(samples.count == count, "duplicate suppressed")
        let prefix = "<details type=\"reasoning\"><summary>Thinking</summary>" +
            String(repeating: "Invented observation. ", count: 5000) + "</details>"
        await pipeline.append(prefix + "\n\nAnswer.")
        check(samples.last?.displayContent == prefix + "\n\nAnswer.", "reasoning and answer together")
        check(samples.last?.frozenContent == prefix, "closed prefix")
        check(samples.last?.liveTail == "\n\nAnswer.", "tail")
        await pipeline.append(prefix + "\n\nAnswer. More.")
        check(samples.last?.liveTail == "\n\nAnswer. More.", "cached prefix advances tail")
        let replacement = prefix.replacingOccurrences(of: "Invented", with: "Imagined")
        await pipeline.append(replacement + "\n\nAnswer.")
        check(samples.last?.frozenContent == replacement, "same-length replacement")
        await pipeline.append("Short.")
        check(samples.last?.frozenContent == "" && samples.last?.displayContent == "Short.", "short replacement")
        for opening in [
            "<details", "<details type=\"reasoning\"",
            "<details type=\"reasoning\"><summary>Thinking</summary>Still open",
            "<details type='tool_calls' arguments='a > b'>",
            "<details type='tool_calls' arguments=\"a \\\" > b\">",
            "<details type=\"reasoning\"><details>nested</details>",
            "<DETAILS type='reasoning'>open", "<details type='reasoning'>open</details",
        ] {
            await pipeline.append("Visible." + opening)
            check(samples.last?.displayContent == "Visible.", "partial structural markup")
        }
        let nested = "<details type='tool_calls'><details x='>'>nested</details></details>"
        await pipeline.append(nested + "Answer.")
        check(samples.last?.frozenContent == nested && samples.last?.liveTail == "Answer.", "nested details")
        await pipeline.append(nested + "Answer.<details type='reasoning'>open")
        check(samples.last?.displayContent == nested + "Answer.", "next incomplete block retains text")
        await pipeline.append("<details-extra>ordinary markup")
        check(samples.last?.displayContent == "<details-extra>ordinary markup", "tag name boundary")
        await pipeline.setFinalContent("Authoritative final.")
        check(samples.last?.isActive == false && samples.dropLast().last?.displayContent == "Authoritative final.", "exact final before idle")
        let finalCount = samples.count
        await pipeline.append("Late")
        await pipeline.setFinalContent("Duplicate")
        check(samples.count == finalCount, "no events after completion")

        let mutations = StreamingPipeline { if $0.isActive { text = $0.displayContent } }
        await mutations.beginWithPrefix("Existing answer.")
        check(text == "Existing answer.", "continue immediately visible")
        var seed: UInt64 = 12345
        for index in 0..<250 {
            seed = seed &* 6364136223846793005 &+ 1
            let value = String(repeating: ["x", "🐙", "é", "漢"][index % 4], count: Int(seed % 400))
            await mutations.append(value)
            check(text == value, "replacement \(index)")
        }
        await mutations.setFinalContent(text)

        let accumulator = ContentAccumulator()
        var values: [String] = []
        accumulator.onUpdate = {
            values.append($0)
            if $0 == "first" { accumulator.append("+second") }
        }
        accumulator.append("first")
        await waitUntil { values.count == 2 }
        check(values == ["first", "first+second"], "arrival during callback")
        let burst = ContentAccumulator()
        var delivered: [String] = []
        burst.onUpdate = { delivered.append($0) }
        for _ in 0..<10000 { burst.append("x") }
        await waitUntil { !delivered.isEmpty }
        check(delivered.count == 1 && delivered.last?.count == 10000, "coalesced burst retains all tokens")

        let concurrent = ContentAccumulator()
        var concurrentCount = 0
        concurrent.onUpdate = { concurrentCount = $0.count }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<1250 { concurrent.append("x") } }
            }
        }
        await waitUntil { concurrentCount == 10000 }
        check(concurrent.content.count == 10000 && concurrentCount == 10000, "concurrent producers retain final update")

        let store = StreamingContentStore()
        store.beginStreaming(messageId: "fixture", modelId: nil)
        store.updateContent("First")
        await waitUntil { store.displayContent == "First" }
        check(store.displayContent == "First", "store first content")
        store.appendStatus(.init(action: "search", done: false))
        store.appendStatus(.init(action: "search", done: true))
        store.appendSources([.init(id: "source", url: "https://example.com")])
        check(store.streamingStatusHistory.count == 1 && store.streamingStatusHistory[0].done == true, "status events intact")
        var completed = 0
        finish(store, "Final differs") { completed += 1 }
        var duplicateCompletion = false
        finish(store, "Duplicate final") { duplicateCompletion = true }
        await waitUntil { !store.isActive }
        check(!store.isActive && completed == 1, "completion once")
        check(!duplicateCompletion, "duplicate completion cannot replace original callback")
        store.updateContent("Late")
        check(store.displayContent.isEmpty, "late arrival ignored")
        check(store.streamingSources.count == 1, "sources survive completion")
        for trial in 0..<25 {
            store.beginStreaming(messageId: "old", modelId: nil)
            store.updateContent(prefix + "Old answer.")
            var stale = false
            finish(store, "Old final") { stale = true }
            store.beginStreaming(messageId: "new", modelId: nil)
            store.updateContent("New answer.")
            await waitUntil { store.displayContent == "New answer." }
            check(store.streamingMessageId == "new" && !stale, "generation isolation \(trial)")
            check(store.abortStreaming().content == "New answer." && !store.isActive, "abort \(trial)")
        }
        store.beginStreaming(messageId: "overload", modelId: nil)
        var answer = prefix
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<2000 {
            answer += "x"
            store.updateContent(answer)
            if index % 5 == 0 { await Task.yield() }
        }
        var ended = false
        finish(store, answer + " FINAL") { ended = true }
        await waitUntil { ended }
        check(ended && !store.isActive, "overload finishes")
        print("LOAD elapsed_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
        for trial in 0..<25 {
            store.beginStreaming(messageId: "final-only", modelId: nil)
            var done = false
            finish(store, "Final-only answer.") { done = true }
            await waitUntil { done }
            check(done && !store.isActive, "final-only \(trial)")
        }
        var disposable: StreamingContentStore? = StreamingContentStore()
        weak var weakStore = disposable
        disposable?.beginStreaming(messageId: "disposable", modelId: nil)
        disposable = nil
        check(weakStore == nil, "consumer does not retain its store")
        print("RESULT checks=\(checks) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}
