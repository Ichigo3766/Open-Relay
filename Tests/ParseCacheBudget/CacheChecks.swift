import Foundation
import Darwin

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return info.phys_footprint
}

private func snapshot(_ index: Int) -> String {
    "<details type=\"reasoning\"><summary>Thinking</summary>" +
        String(repeating: "An invented paper rover checks a painted rock.\n", count: 2800) +
        "Checkpoint \(index).</details>"
}

@main struct CacheChecks {
    static func main() async {
        let cache = MessageParseCache()
        let warm = CommandLine.arguments.contains("--warm")
        let before = footprint()
        for index in 0..<200 {
            if warm { await cache.warmBatch([snapshot(index)]) }
            else { _ = await cache.parseAndStore(content: snapshot(index)) }
            if (index + 1).isMultiple(of: 50) {
                print("CACHE_MEMORY warm=\(warm) snapshots=\(index + 1) footprint_mib=\(Double(footprint()) / 1048576) increase_mib=\(Double(footprint() - before) / 1048576)")
            }
        }
        var retained = 0
        for index in 0..<200 {
            if cache.lookupSync(snapshot(index)) != nil { retained += 1 }
        }
        // NSCache may evict any entry. An evicted snapshot must still reparse correctly.
        for index in [0, 99, 199] {
            let value = snapshot(index)
            let result = await cache.parseAndStore(content: value)
            guard case .reasoning(let reasoning)? = result.segments.first else {
                preconditionFailure("Missing reasoning after cache pressure")
            }
            precondition(reasoning.content.contains("Checkpoint \(index)."))
            if let cached = cache.lookupSync(value) {
                precondition(cached.segments.count == result.segments.count)
            }
        }
        print("CACHE_MEMORY retained=\(retained) reparsing_checks=3 passed")
    }
}
