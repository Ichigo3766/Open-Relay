"""Run production chat ownership and retention rules with synthetic models.
Usage: python3 Tests/TieredCache/run-active-chat-tests.py /external/scratch
"""
from pathlib import Path
import os
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
if out == root or root in out.parents:
    raise SystemExit("Use a scratch directory outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
source = (root / "Open UI/Core/Services/DependencyContainer.swift").read_text()
start = source.index("@MainActor @Observable\nfinal class ActiveChatStore")
end = source.index("/// The live dependency container", start)
(out / "Store.swift").write_text("import Foundation\nimport Observation\n" + source[start:end])
model = (root / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift").read_text()
start = model.index("    var needsBackgroundRetention: Bool {")
end = model.index("    /// Whether any attachment", start)
rules = model[start:end]
flags = sorted(set(re.findall(r"\bis[A-Z]\w*", rules)) - {"isTranscribing"})
stubs = '''import Foundation
import Observation
struct AIModel { var id: String }
struct TerminalServer {}
struct ToolItem {}
struct TaskConfig { static let `default` = TaskConfig() }
struct GroupFeaturePermissions {}
struct UserDefaultParams {}
struct ChatAttachment { var id = UUID(); var name: String; var isTranscribing = false }
struct QueuedMessage { var text: String }
struct FixtureConversation { var id: String; var payload: Data = Data() }
@MainActor @Observable final class Prompts { var requests: [Int] = [] }
final class Consent { func reset() {} }
@MainActor @Observable final class ChatViewModel {
    var conversationId: String?
    var conversation: FixtureConversation?
    var availableModels: [AIModel] = []
    var selectedModelId: String?
    var inputText = ""
    var attachments: [ChatAttachment] = []
    var messageQueue: [QueuedMessage] = []
    var pendingQueueDrains = 0
    static var deliveries: [String] = []
    func sendMessage(directText: String) async { Self.deliveries.append(directText) }
    var pendingTextAfterUpload: String?
    var liveAskUserPrompt: Int?
    var hasActiveTranscriptions = false
    var hasUploadingAttachments = false
    var toolEventPrompts = Prompts()
    let webSearchConsent = Consent()
    var recoveries = 0
    init(conversationId: String? = nil) { self.conversationId = conversationId }
    func seedFromSessionCache(terminalServers: [TerminalServer]?, tools: [ToolItem]?) {}
    func configure(with: Int, socket: Int?, store: Any, asr: Int?, notes: Int? = nil) { isConfigured = true }
    func loadModels() async {}
    func recoverAfterSocketReconnect() async { recoveries += 1 }
'''
stubs += "".join("    var " + flag + " = false\n" for flag in sorted(set(flags + ["isConfigured", "isExternallyStreaming"])))
start = model.index("    private func drainMessageQueue(after delay: UInt64) {")
end = re.search(r"^    }$", model[start:], re.M).end() + start
stubs += rules + model[start:end].replace("private func", "func", 1) + "\n}\n"
stubs += '''@MainActor final class AppDependencyContainer {
    var conversationManager: Int? = 1
    var socketService: Int? = 1
    var asrService: Int? = 1
}
'''
(out / "Stubs.swift").write_text(stubs)
(out / "Checks.swift").write_text((root / "Tests/TieredCache/ActiveChatStoreTests.swift").read_text())
subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules"),
    str(out / "Store.swift"), str(out / "Stubs.swift"), str(out / "Checks.swift"), "-o", str(out / "checks")], check=True)
subprocess.run([str(out / "checks")], env=dict(os.environ, TMPDIR=str(out)), check=True)
