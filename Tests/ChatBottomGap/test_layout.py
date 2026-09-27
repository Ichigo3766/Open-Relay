"""Execute the production minimum-height closure, not a reimplementation."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class LastTurnHeightTests(unittest.TestCase):
    def test_production_height_policy(self):
        source = (ROOT / "Open UI/Features/Chat/Views/ChatDetailView.swift").read_text()
        start = source.index(".frame(minHeight: {", source.index("private var messagesList:"))
        expression = source[start + len(".frame(minHeight: {"):source.index("}(), alignment: .top)", start)]
        harness = """import Foundation
struct Model { let isStreaming: Bool }
func height(windowIncludesEnd: Bool, content: CGFloat, viewport: CGFloat, streaming: Bool) -> CGFloat? {
    let viewState_contentHeight = content
    let viewState_containerHeight = viewport
    let viewModel = Model(isStreaming: streaming)
    return { () -> CGFloat? in
""" + expression + """
    }()
}
var failures = 0
func check(_ name: String, _ actual: CGFloat?, _ expected: CGFloat?) {
    if actual != expected { print("FAIL \\(name): \\(String(describing: actual)) != \\(String(describing: expected))"); failures += 1 }
    else { print("PASS \\(name)") }
}
check("completed conversation with history", height(windowIncludesEnd: true, content: 2000, viewport: 800, streaming: false), nil)
check("completed after padded measurement", height(windowIncludesEnd: true, content: 816, viewport: 800, streaming: false), nil)
check("short completed conversation", height(windowIncludesEnd: true, content: 200, viewport: 800, streaming: false), nil)
check("streaming keeps writing room", height(windowIncludesEnd: true, content: 200, viewport: 800, streaming: true), 800)
check("streaming never pads older pagination window", height(windowIncludesEnd: false, content: 2000, viewport: 800, streaming: true), nil)
check("keyboard-reduced viewport", height(windowIncludesEnd: true, content: 2000, viewport: 460, streaming: false), nil)
exit(failures == 0 ? 0 : 1)
"""
        with tempfile.TemporaryDirectory(prefix="relay-height-test-") as folder:
            path = Path(folder) / "main.swift"
            path.write_text(harness)
            result = subprocess.run(["swift", str(path)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
