import Foundation
import Darwin

actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

@main struct ParseCacheChecks {
    static func cpu() -> Double {
        var value = rusage(); getrusage(0, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    static func peak() -> Int { var value = rusage(); getrusage(0, &value); return value.ru_maxrss }
    static func waitFor(_ n: Int, in gate: Gate) async {
        while await gate.count != n { await Task.yield() }
    }
    static func reasoning(_ text: String, id: Int) -> String {
        "<details type=\"reasoning\" done=\"true\"><summary>Invented calculation \(id)</summary>\(text)</details>\n\nAn invented emerald satellite."
    }
    static func benchmark() async {
        let cache = MessageParseCache(), gate = Gate()
        let body = String(repeating: "An invented emerald satellite calculation.\n", count: 30000)
        let inputs = (0..<12).map { reasoning(body, id: $0) }
        let beforeCPU = cpu(), start = ProcessInfo.processInfo.systemUptime, initialPeak = peak()
        let jobs = inputs.map { source in Task { await gate.wait(); return await cache.parseAndStore(content: source) } }
        await waitFor(jobs.count, in: gate)
        for job in jobs { job.cancel() }
        await gate.release()
        var segments = 0
        for job in jobs { segments += await job.value.segments.count }
        let result: [String: Any] = ["jobs":12,"input_bytes":inputs.reduce(0) { $0 + $1.utf8.count },
            "wall_ms":(ProcessInfo.processInfo.systemUptime-start)*1000,"cpu_ms":(cpu()-beforeCPU)*1000,
            "initial_peak_rss_bytes":initialPeak,"peak_rss_bytes":peak(),"returned_segments":segments]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
    }

    static func benchmarkWarm() async {
        let cache = MessageParseCache()
        let body = String(repeating: "An invented emerald satellite calculation.\n", count: 30000)
        let inputs = (0..<12).map { SyntheticMessage(role:.assistant,content:body+"\n[Invented chart](/api/v1/files/example-\($0)/content)") }
        let beforeCPU=cpu(),start=ProcessInfo.processInfo.systemUptime,initialPeak=peak()
        let selected=warmInputs(inputs)
        await cache.warmBatch(selected)
        let result:[String:Any]=["jobs":12,"input_bytes":inputs.reduce(0){$0+$1.content.utf8.count},"selected_inputs":selected.count,"cached_inputs":selected.filter{cache.lookupSync($0) != nil}.count,"wall_ms":(ProcessInfo.processInfo.systemUptime-start)*1000,"cpu_ms":(cpu()-beforeCPU)*1000,"initial_peak_rss_bytes":initialPeak,"peak_rss_bytes":peak()]
        print(String(data:try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
    }

    static func main() async {
        if CommandLine.arguments.contains("--benchmark-warm") { await benchmarkWarm(); return }
        if CommandLine.arguments.contains("--benchmark") { await benchmark(); return }
        var checks = 0, failures = 0
        func expect(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + name) }
        }
        let cache = MessageParseCache(), gate = Gate()
        let cancelledContent = reasoning("Fresh synthetic cancelled calculation.", id: 1)
        let job = Task { await gate.wait(); return await cache.parseAndStore(content: cancelledContent) }
        await waitFor(1, in: gate)
        job.cancel()
        await gate.release()
        let cancelled = await job.value
        expect(cancelled.segments.isEmpty, "discarded row avoids structural parsing")
        expect(cache.lookupSync(cancelledContent) == nil, "discarded row avoids storing an unused snapshot")
        for content in ["An invented plain satellite.", reasoning("Invented visible calculation.", id: 2),
            "<details type=\"tool_calls\" done=\"true\" id=\"invented-tool\" name=\"inspect_aster\" result=\"{&quot;count&quot;:7}\"><summary>Inspect satellite</summary></details>"] {
            let parsed = await cache.parseAndStore(content: content)
            expect(!parsed.segments.isEmpty, "visible content still parses")
            expect(cache.lookupSync(content) != nil, "visible content is cached")
            let again = await cache.parseAndStore(content: content)
            expect(again.segments.count == parsed.segments.count, "visible cache result remains stable")
        }

        for scalar in 0...0x10FFFF where scalar % 257 == 0 {
            guard let unicode = UnicodeScalar(scalar) else { continue }
            let content = "Invented marker sample " + String(unicode)
            expect(MessageParseCache.containsStructuralMarkers(content) == (content.contains("<") || content.contains("◁")), "structural classification preserves Unicode sample")
        }
        for content in ["<", "◁", "A◁B", "<\u{0338}", "<\u{0301}", "<\u{FE0F}", "<\u{200D}", "◁\u{FE0F}", "≮", "é", "e\u{301}", "🪐", "“invented”", "\u{FE0F}", "🇺🇳", "한", "A\u{202E}<", "<details>synthetic</details>"] {
            expect(MessageParseCache.containsStructuralMarkers(content) == (content.contains("<") || content.contains("◁")), "structural classification preserves marker edge case")
        }
        for content in ["", " \n\t", "An invented plain satellite.", "# Invented Markdown\n[Chart](/api/v1/files/example/content)", "An invented citation [1].", "```swift\nlet comet = 7\n```", "Invented Unicode 🪐 café"] {
            expect(warmInputs([SyntheticMessage(role:.assistant,content:content)]).isEmpty,"plain content does not warm an unused cache")
        }
        for content in [reasoning("Invented warm calculation.",id:3),"<details type=\"tool_calls\"><summary>Invented tool</summary></details>","◁think▷Invented alternate reasoning◁/think▷", "<div>Invented HTML</div>", "<details><summary>Chart</summary>[Invented chart](/api/v1/files/example/content)</details>"] {
            let expected=IsolatedAssistantMessage.resolveRelativeURLs(content,baseURL:"https://example.test")
            expect(warmInputs([SyntheticMessage(role:.assistant,content:content)]) == [expected],"structural warming preserves resolved content")
            expect(warmInputs([SyntheticMessage(role:.user,content:content)]).isEmpty,"user messages do not warm assistant cache")
        }

        print("\(checks-failures)/\(checks) synthetic structural-cache checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
