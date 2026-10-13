import Foundation
import Darwin

@main struct RenderBenchmark {
    @MainActor static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let history = (json["chat"] as! [String: Any])["history"] as! [String: Any]
        let nodes = history["messages"] as! [String: [String: Any]]
        let tree = MessageHistory(nodes: Dictionary(uniqueKeysWithValues: nodes.map {
            ($0.key, MessageHistory.parseNode(id: $0.key, from: $0.value))
        }), currentId: history["currentId"] as? String)
        let messages = tree.createMessagesList()
        let virtualizer = ChatRowVirtualizer()
        virtualizer.updateWidth(393); virtualizer.updateViewport(top: 1000, height: 800)
        _ = virtualizer.updatedRange(messages: messages, current: nil)
        var renderer = Renderer(viewModel: Owner(messages: messages), drawnRange: 20...40, virtualizer: virtualizer)
        if CommandLine.arguments.count > 2, !messages.isEmpty {
            renderer.viewModel.streamingStore.isActive = true
            renderer.viewModel.streamingStore.streamingMessageId = messages.last!.id
            renderer.editingMessageId = messages[min(2, messages.count - 1)].id
        }
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = DispatchTime.now().uptimeNanoseconds
        var checksum = 0
        for iteration in 0..<100 {
            renderer.drawnRange = (20 + iteration)...(40 + iteration)
            checksum += renderer.items().count
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        getrusage(RUSAGE_SELF, &after)
        func cpu(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let result: [String: Any] = ["messages": messages.count, "iterations": 100, "checksum": checksum,
            "cpu_ms": (cpu(after) - cpu(before)) * 1000, "wall_ms": wall,
            "peak_rss_mib": Double(after.ru_maxrss) / 1048576]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
