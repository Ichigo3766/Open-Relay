import Darwin
import Foundation

/// Pipeline-only A/B benchmark. No network, UIKit, or personal data is involved.
@main struct Benchmark {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    @MainActor static func main() async throws {
        for (name, size, interval, count) in [
            ("slow", 20, 500, 8), ("medium", 20, 100, 20),
            ("fast", 200, 100, 20), ("reasoning", 17, 20, 100),
        ] {
            for trial in 1...3 {
                var output = "", first: Double?, finished: Double?
                let pipeline = StreamingPipeline { value in
                    if value.isActive {
                        output = value.displayContent
                        if first == nil && !output.isEmpty { first = now() }
                    } else { finished = now() }
                }
                let prefix = name == "reasoning"
                    ? "<details type=\"reasoning\"><summary>Thinking</summary>"
                        + String(repeating: "An invented observatory has a copper telescope. ", count: 2200)
                        + "</details>\n\n" : ""
                await pipeline.beginWithPrefix(prefix)
                first = nil
                let start = now(), cpuStart = cpu()
                var input = prefix
                for _ in 0..<count {
                    input += String(repeating: "x", count: size)
                    await pipeline.append(input)
                    try await Task.sleep(for: .milliseconds(interval))
                }
                let pending = input.count - output.count, end = now()
                await pipeline.setFinalContent(input)
                while finished == nil && now() - end < 10 {
                    try await Task.sleep(for: .milliseconds(2))
                }
                precondition(finished != nil && output == input, "Final content mismatch")
                print("PIPELINE_BENCH name=\(name) trial=\(trial) first_ms=\(((first ?? start)-start)*1000) finish_ms=\(((finished ?? end)-end)*1000) pending=\(pending) cpu_ms=\((cpu()-cpuStart)*1000)")
            }
        }
    }
}
