import Foundation
import Darwin

@main struct CompletionBenchmark {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let chat = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<3 {
            precondition(autoreleasepool { !Subject.hasUnfinishedMessages(chat) })
        }
        getrusage(RUSAGE_SELF, &after)
        func cpu(_ r: rusage) -> Double {
            Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        let metrics: [String: Any] = ["cpu_ms_per_check": (cpu(after) - cpu(before)) * 1_000 / 3,
            "wall_ms_per_check": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / 3,
            "process_peak_rss_mib": Double(after.ru_maxrss) / 1_048_576]
        print(String(data: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), encoding: .utf8)!)
    }
}
