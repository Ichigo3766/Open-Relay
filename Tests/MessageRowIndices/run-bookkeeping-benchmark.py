"""Measure production turn grouping and row decisions, excluding SwiftUI rendering.
Usage: python3 Tests/MessageRowIndices/run-bookkeeping-benchmark.py /external/scratch
Use --source /path/to/ChatDetailView.swift for a paired earlier-revision run.
"""
from pathlib import Path
import argparse
import os
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--source", type=Path, default=root / "Open UI/Features/Chat/Views/ChatDetailView.swift")
options = parser.parse_args()
out = options.output.resolve()
if out == root or root in out.parents:
    raise SystemExit("Use a scratch directory outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
source = options.source.read_text()
start = source.index("    private var messagesList: some View {")
end = source.index("    /// One message slot:", start)
body = source[start:end]
prefix = body[body.index("        let allMessages"):body.index("        return ForEach(turns")]
# The baseline cache write is immediate here. Warm-up excludes rebuilding and
# the asynchronous SwiftUI invalidation, which the native regression covers.
prefix = prefix.replace("Task { @MainActor in cachedIndexMap = freshMap }", "cachedIndexMap = freshMap")
slot = body.index("                    let isDrawn")
finish = body.index("                    messageSlot(", slot)
if "ForEach(turn.messages, id:" in body:
    loop = "for turn in turns { for row in turn.messages {\n                    let message = row.message\n                    let index = row.index\n"
else:
    loop = "for turn in turns { for message in turn.messages {\n                    let index = indexMap[message.id] ?? 0\n"
legacy = "var cachedIndexMap: [String: Int] = [:]" if "cachedIndexMap" in body else ""
preamble = r'''
import Darwin
import Foundation

struct ChatMessage {
  var id: String
  var role: Role = .user
  enum Role { case user, assistant }
}
struct Slot {
  var index: Int
  var drawn: Bool
}
final class Stream {
  var isActive = false
  var streamingMessageId: String?
}
final class Model {
  var messages: [ChatMessage] = []
  var isStreaming = false
  let streamingStore = Stream()
}
final class Virtualizer {
  func bottomRange(messages: [ChatMessage], viewportHeight: CGFloat) -> ClosedRange<Int>? {
    messages.isEmpty ? nil : max(0, messages.count - 6)...(messages.count - 1)
  }
}
final class Subject {
  __LEGACY__
  let viewModel = Model()
  let virtualizer = Virtualizer()
  var drawnRange: ClosedRange<Int>? = 10...12
  var viewState_containerHeight: CGFloat = 800
  var editingMessageId: String?
'''
footer = r'''
import Darwin

func cpuMS() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(
    usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
}
func resident() -> Int64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) { p in
    p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  precondition(result == KERN_SUCCESS)
  return Int64(info.resident_size)
}
let subject = Subject()
subject.viewModel.messages = (0..<6000).map {
  ChatMessage(id: "invented-\($0)", role: $0 % 2 == 0 ? .user : .assistant)
}
var sum = 0
for _ in 0..<20 { sum &+= subject.render() }
let start = DispatchTime.now().uptimeNanoseconds
let cpu = cpuMS()
for _ in 0..<500 { sum &+= subject.render() }
let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
let row: [String: Any] = [
  "case": "6000_rows_grouping_and_indices", "iterations": 500, "wall_ms": wall,
  "cpu_ms": cpuMS() - cpu, "end_rss_bytes": resident(), "checksum": sum,
]
print(
  String(
    data: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!
)
'''
measured = preamble.replace("__LEGACY__", legacy) + " func render()->Int {\n" + prefix
measured += "var checksum = 0\n" + loop + body[slot:finish]
measured += "checksum &+= index &+ (isDrawn ? 1 : 0)\n}}\nreturn checksum\n}\n}\n" + footer
(out / "Benchmark.swift").write_text(measured)
subprocess.run(["swiftc", "-O", "-module-cache-path", str(out / "modules"), str(out / "Benchmark.swift"), "-o", str(out / "benchmark")], check=True)
subprocess.run([str(out / "benchmark")], env=dict(os.environ, TMPDIR=str(out)), check=True)
