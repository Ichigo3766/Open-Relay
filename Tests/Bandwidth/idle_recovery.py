#!/usr/bin/env python3
"""Run the production recovery body and socket-update callback with synthetic services."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--ref", help="Read production source from a Git revision instead of the working tree")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
path = "Open UI/Features/Chat/ViewModels/ChatViewModel.swift"
source = subprocess.check_output(["git", "show", f"{args.ref}:{path}"], cwd=root, text=True) if args.ref else (root / path).read_text()


def section(start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


method = section("    private func runRecoveryPoll(", "    /// Returns `true` when the content string")
# Await the original Task's body directly to make request-count assertions deterministic.
body = method.split("        Task { @MainActor in\n", 1)[1].rsplit("\n        }\n    }", 1)[0]
complete = section("    private static func toolCallResponseIsComplete(", "    // MARK: - Cleanup")
callback = section("        acc.onUpdate =", "\n\n        chatSubscription =").replace("acc.onUpdate =", "let onUpdate: (String) -> Void =", 1)
swift = r'''
import Foundation
struct Log { func info(_ value: String) {}; func debug(_ value: String) {}; func warning(_ value: String) {} }
enum Role { case user, assistant }
struct Message { var role = Role.assistant; var content = ""; var isStreaming = true }
struct Conversation { var messages = [Message()] }
@MainActor final class API {
    var taskFetches = 0
    func getTasksForChat(chatId: String) async throws -> [String] { taskFetches += 1; return ["synthetic-task"] }
}
@MainActor final class Manager {
    let apiClient = API()
    var fetches = 0
    var server = Conversation()
    var fails = false
    func fetchConversation(id: String) async throws -> Conversation {
        fetches += 1
        if fails { throw URLError(.networkConnectionLost) }
        return server
    }
}
@MainActor final class Socket { var isConnected = true }
@MainActor final class ChatViewModel {
    let logger = Log()
    var manager: Manager? = Manager()
    var socketService: Socket? = Socket()
    var conversation: Conversation? = Conversation()
    var recoveryTimer: Timer?
    var isStreaming = true
    var hasFinishedStreaming = false
    var socketHasReceivedContent = false
    var lastSocketContentAt = Date.distantPast
    var streamingSessionId = 1
    var lastRecoveryPollContentLength = 0
    var emptyPollCount = 0
    var recoveryTaskCheckFailures = 0
    var recoveryTimerStartDate = Date()
    var liveAskUserPrompt: String?
    var cleanups = 0
    func updateAssistantMessage(id: String, content: String, isStreaming: Bool) {
        conversation?.messages[0].content = content
        conversation?.messages[0].isStreaming = isStreaming
    }
    func sendCompletionNotificationIfNeeded(content: String) async {}
    func cleanupStreaming() { cleanups += 1; isStreaming = false }
    func poll(assistantMessageId: String = "synthetic-reply", chatId: String? = "synthetic-chat") async {
''' + body + '''
    }
''' + complete + '''
    func deliver(_ content: String, session: Int = 1) {
        let msgId = "synthetic-reply"
        let updateSessionId = session
''' + callback + r'''
        onUpdate(content)
    }
}
@main struct Checks {
    @MainActor static func main() async {
        var assertions = 0
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            assertions += 1
            if !condition { failures += 1; print("FAIL: " + label) }
        }
        for scenario in 0..<15 {
            let vm = ChatViewModel()
            let manager = vm.manager!
            vm.lastSocketContentAt = Date().addingTimeInterval(-1)
            switch scenario {
            case 1: vm.lastSocketContentAt = Date().addingTimeInterval(-7)
            case 2: vm.lastSocketContentAt = Date().addingTimeInterval(-9)
            case 3: vm.lastSocketContentAt = .distantPast
            case 4: vm.socketService?.isConnected = false
            case 5: vm.socketService = nil
            case 6: vm.isStreaming = false
            case 7: vm.hasFinishedStreaming = true
            case 8: break // no chat ID
            case 9: vm.manager = nil
            case 10:
                vm.lastSocketContentAt = .distantPast
                manager.server.messages[0] = Message(content: "Synthetic completed response", isStreaming: false)
            case 11:
                vm.lastSocketContentAt = .distantPast
                manager.server.messages[0] = Message(content: "<details type=\"tool_calls\" done=\"false\">Synthetic tool</details>", isStreaming: false)
            case 12:
                vm.lastSocketContentAt = .distantPast
                vm.liveAskUserPrompt = "Synthetic question"
                manager.server.messages[0] = Message(content: "Synthetic response", isStreaming: false)
            case 13: vm.lastSocketContentAt = .distantPast; manager.fails = true
            case 14: vm.lastSocketContentAt = Date().addingTimeInterval(-8)
            default: break
            }
            await vm.poll(chatId: scenario == 8 ? nil : "synthetic-chat")
            let fetch = [2, 3, 4, 5, 10, 11, 12, 13, 14].contains(scenario)
            check(manager.fetches == (fetch ? 1 : 0), "conversation fetches, scenario \(scenario)")
            check(vm.cleanups == (scenario == 10 ? 1 : 0), "completion and pending tools, scenario \(scenario)")
            if !fetch { check(manager.apiClient.taskFetches == 0, "no task fetch while delivery is active") }
        }
        for scenario in 0..<3 {
            let vm = ChatViewModel()
            if scenario == 1 { vm.streamingSessionId = 2 }
            if scenario == 2 { vm.hasFinishedStreaming = true }
            vm.deliver("Synthetic thinking and answer text")
            check((vm.lastSocketContentAt != .distantPast) == (scenario == 0), "only current active socket updates renew activity")
            check((vm.conversation?.messages[0].content == "Synthetic thinking and answer text") == (scenario == 0), "socket content preserved")
            if scenario == 0 {
                await vm.poll()
                check(vm.manager?.fetches == 0, "fresh socket content suppresses recovery")
                vm.lastSocketContentAt = Date().addingTimeInterval(-9)
                await vm.poll()
                check(vm.manager?.fetches == 1, "recovery resumes after delivery stalls")
            }
        }
        print("\(assertions) assertions; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
cache = output / "module-cache"
cache.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(dir=output, prefix="idle-recovery-") as directory:
    directory = Path(directory)
    generated = directory / "Checks.swift"
    generated.write_text(swift)
    env = dict(os.environ, TMPDIR=str(directory), CLANG_MODULE_CACHE_PATH=str(cache))
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(cache), str(generated), "-o", str(directory / "checks")], env=env, check=True)
    raise SystemExit(subprocess.run([str(directory / "checks")], env=env).returncode)
