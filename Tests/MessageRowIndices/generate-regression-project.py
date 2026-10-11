"""Generate a native fixture using the production message-list body unchanged.
Usage: python3 Tests/MessageRowIndices/generate-regression-project.py /external/scratch
Use --source /path/to/ChatDetailView.swift to test another production revision.
"""
from pathlib import Path
import argparse
import subprocess

root = Path(__file__).resolve().parents[2]
args = argparse.ArgumentParser(description=__doc__)
args.add_argument("output", type=Path)
args.add_argument("--source", type=Path, default=root / "Open UI/Features/Chat/Views/ChatDetailView.swift")
options = args.parse_args()
out = options.output.resolve()
if out == root or root in out.parents:
    raise SystemExit("Use a scratch directory outside the checkout.")
for folder in ["Host", "Tests"]:
    (out / folder).mkdir(parents=True, exist_ok=True)
source = options.source.read_text()
start = source.index("    private var messagesList: some View {")
end = source.index("    /// One message slot:", start)
legacy = "    @State private var cachedIndexMap: [String: Int] = [:]\n" if "cachedIndexMap" in source[start:end] else ""
stubs = '''import SwiftUI
import Observation
struct ChatMessage: Identifiable {
    var id: String
    var role: Role = .user
    enum Role { case user, assistant }
}
struct RowFixtureSlot: Equatable { var index: Int; var drawn: Bool }
@MainActor @Observable final class RowFixtureStream {
    var isActive = false
    var streamingMessageId: String?
}
@MainActor @Observable final class RowFixtureModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var editingMessageId: String?
    let streamingStore = RowFixtureStream()
}
@MainActor final class RowFixtureRecorder { var slots: [String: RowFixtureSlot] = [:] }
@MainActor final class RowFixtureVirtualizer {
    func bottomRange(messages: [ChatMessage], viewportHeight: CGFloat) -> ClosedRange<Int>? {
        messages.isEmpty ? nil : max(0, messages.count - 6)...(messages.count - 1)
    }
}
@MainActor struct RowIndexSubject: View {
    let viewModel: RowFixtureModel
    let recorder: RowFixtureRecorder
    let virtualizer = RowFixtureVirtualizer()
    let drawnRange: ClosedRange<Int>? = 10...12
    let viewState_containerHeight: CGFloat = 800
    var editingMessageId: String? { viewModel.editingMessageId }
    var body: some View { VStack(spacing: 0) { messagesList } }
    func messageSlot(message: ChatMessage, index: Int, isDrawn: Bool) -> some View {
        recorder.slots[message.id] = RowFixtureSlot(index: index, drawn: isDrawn)
        return Text(isDrawn ? message.id + " · index " + String(index) : "Spacer")
            .font(.system(size: 14, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 24)
            .foregroundStyle(isDrawn ? Color.primary : Color.secondary)
    }
'''
(out / "Tests/Production.swift").write_text(stubs + legacy + source[start:end] + "\n}\n")
(out / "Tests/Checks.swift").write_text((root / "Tests/MessageRowIndices/RegressionChecks.swift").read_text())
(out / "Host/Host.swift").write_text('import SwiftUI\n@main struct Host: App { var body: some Scene { WindowGroup { Text("Invented row-index fixture") } } }\n')
project = '''name: Regression
options:
  deploymentTarget:
    iOS: '18.1'
settings:
  base:
    CODE_SIGNING_ALLOWED: NO
    GENERATE_INFOPLIST_FILE: YES
    SWIFT_VERSION: '5.0'
targets:
  Host:
    type: application
    platform: iOS
    sources: Host
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: org.example.rowindex.host
  Checks:
    type: bundle.unit-test
    platform: iOS
    sources: Tests
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: org.example.rowindex.checks
      TEST_HOST: '$(BUILT_PRODUCTS_DIR)/Host.app/Host'
      BUNDLE_LOADER: '$(TEST_HOST)'
    dependencies:
      - target: Host
schemes:
  Regression:
    build:
      targets:
        Host: all
        Checks: [test]
    test:
      targets: [Checks]
'''
(out / "project.yml").write_text(project)
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml")], check=True)
