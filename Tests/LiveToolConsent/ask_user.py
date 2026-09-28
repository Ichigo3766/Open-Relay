"""Compile exact production ask_user parsing and response methods with a mocked API."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def source(path):
    if baseline:
        return subprocess.check_output(["git", "show", "origin/main:" + path], cwd=root, text=True)
    return (root / path).read_text()

model = source("Open UI/Shared/Components/AskUserCard.swift").split("// MARK: - AskUserCard View")[0].replace("import SwiftUI", "import Foundation")
vm = source("Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
if baseline:
    receive = vm.split('case "request:user_input":', 1)[1].split("\n            default:", 1)[0]
    methods = "func receiveAskUser(_ payload: [String: Any]?, messageId assistantMessageId: String, reply ack: ((Any?) -> Void)?) {" + receive + "}\n"
    methods += vm[vm.index("    func answerAskUser("):vm.index("    /// Rejects/cancels the currently pending ask_user call.")]
else:
    methods = vm[vm.index("    private func receiveAskUser("):vm.index("    /// Switches tool approval mode")].replace("private func", "func")
    scan = vm[vm.index("    func scanForPendingToolActions()"):vm.index("    /// Fetches and caches the `enableToolPermissions`")]
    assert "!resolvedAskUserCallIds.contains(info.callId)" in scan

stubs = '''
enum MessageHistory { struct PendingAskUserInfo { let messageId: String; let callId: String; let arguments: [String: Any] } }
struct Conversation { var id: String }
struct Logger { func error(_ message: String) {} }
@MainActor final class API {
    var requests: [[String: Any]] = []
    var fail = false
    var gate: CheckedContinuation<Void, Never>?
    var suspend = false
    func resolveToolCall(chatId: String, messageId: String, callId: String, action: String, answers: [String: Any]? = nil, timedOut: Bool = false) async throws -> [String: Any] {
        requests.append(["chat": chatId, "message": messageId, "call": callId, "action": action, "answers": answers ?? [:]])
        if suspend { await withCheckedContinuation { gate = $0 } }
        if fail { throw NSError(domain: "Synthetic", code: 503) }
        return [:]
    }
}
@MainActor final class Manager { let apiClient = API() }
@MainActor final class Harness {
    var liveAskUserPrompt: PendingAskUserPrompt?
    var pendingAskUserPrompt: PendingAskUserPrompt?
    var isResolvingAskUser = false
    var askUserError: String?
    var resolvedAskUserCallIds: Set<String> = []
    var conversationId: String? = "demo-chat"
    var conversation: Conversation?
    var manager: Manager? = Manager()
    let logger = Logger()
    func reloadConversation() async {}
'''
with tempfile.TemporaryDirectory(prefix="relay-ask-user-") as directory:
    directory = pathlib.Path(directory)
    generated = directory / "Production.swift"
    generated.write_text(model + stubs + methods + "\n}\n")
    binary = directory / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", *(["-D", "BASELINE"] if baseline else []), str(generated), str(root / "Tests/LiveToolConsent/AskUserChecks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
