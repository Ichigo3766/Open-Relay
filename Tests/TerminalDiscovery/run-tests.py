"""Compile the production terminal-discovery method with invented gated inputs."""
from pathlib import Path
import os
import argparse
import subprocess
import re

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
parser.add_argument("output", type=Path)
args = parser.parse_args()
out = args.output.resolve()
repo = Path(__file__).resolve().parents[2]
if out == repo or repo in out.parents:
    raise SystemExit("Keep generated binaries and module caches outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
(out / "tmp").mkdir(exist_ok=True)
os.environ["TMPDIR"] = str(out / "tmp") + "/"
source = args.source.read_text()
start = source.index("    func loadTerminalServers()")
end = source.index("    /// Model-configured default terminal", start)
method = source[start:end]
socket_start = source.index("        if let socket = socketService, !socket.isConnected {")
socket_end = source.index("        // Start listening for app foreground events", socket_start)
socket_startup = source[socket_start:socket_end]
param_start = source.index("    func fetchUserDefaultParamsFromServer()")
param_end = source.index("    // MARK: - Pinned Models", param_start)
param_method = source[param_start:param_end]
param_startup = [line.strip() for line in source.splitlines() if "userDefaultParamsTask = " in line][0]
startup = [line for line in source.splitlines() if line.startswith("        ")
           and "loadTerminalServers()" in line and not line.lstrip().startswith("//")][0]
stub = """import Foundation
import Observation
import Darwin
struct TerminalServer: Equatable { let id: String }
struct Params: Equatable { var defaultUploadContext: String?; var hasAnyOverride: Bool }
struct Attachment { var uploadContext: String? }
struct Knowledge { var context: String? }
@MainActor final class ParametersAPI {
    var pending: [CheckedContinuation<Params, Error>] = []
    func fetchUserDefaultParams() async throws -> Params {
        let value: Params = try await withCheckedThrowingContinuation { pending.append($0) }
        try Task.checkCancellation()
        return value
    }
    func finish(_ result: Result<Params, Error>) { let waiting=pending;pending.removeAll();for request in waiting { request.resume(with:result) } }
}
@MainActor final class Store { var cachedTerminalServers: [TerminalServer]?; var cachedUserDefaultParams: Params? }
@MainActor final class Logger {
    var errors = 0; var infos = 0
    func debug(_ message: String) { errors += 1 }
    func info(_ message: String) { infos += 1 }
}
@MainActor final class SyntheticSocket {
    var isConnected = false
    var pending: [CheckedContinuation<Bool, Never>] = []
    func ensureConnected(timeout: Double) async -> Bool {
        await withCheckedContinuation { pending.append($0) }
    }
    func finish(_ connected: Bool) {
        isConnected = connected
        let waiters = pending; pending.removeAll()
        for waiter in waiters { waiter.resume(returning: connected) }
    }
}
@MainActor final class ConversationManager {
    let apiClient = ParametersAPI()
    var pending: [CheckedContinuation<[TerminalServer], Error>] = []
    var fetches = 0
    func fetchTerminalServers() async throws -> [TerminalServer] {
        fetches += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ result: Result<[TerminalServer], Error>) {
        let requests = pending
        pending.removeAll()
        for request in requests { request.resume(with: result) }
    }
}
@MainActor @Observable final class Subject {
    let manager: ConversationManager?
    let socketService: SyntheticSocket?
    var isNew = false
    var listenerStarts = 0
    let logger = Logger()
    var availableTerminalServers: [TerminalServer] = []
    var selectedTerminalServer: TerminalServer?
    var terminalEnabled = false
    var activeChatStore: Store? = Store()
    var pendingApplies = 0
    var userDefaultParamsTask: Task<Void,Never>?
    var attachments: [Attachment] = []
    var selectedKnowledgeItems: [Knowledge] = []
    var approvalRestores = 0
    func restoreToolApprovalMode() { approvalRestores += 1 }
    var history: Data
    init(manager: ConversationManager?, size: Int = 0, seed: UInt8 = 1, socket: SyntheticSocket? = nil) {
        self.manager = manager
        self.socketService = socket
        history = Data(repeating: seed, count: size)
    }
    func startPassiveSocketListener() { if socketService != nil { listenerStarts += 1 } }
    func applyPendingModelDefaultTerminal() { pendingApplies += 1 }
    func startup() {
""" + startup + "\n    }\n" + method + "\n    func startupSocket() {\n let isNew = self.isNew\n" + socket_startup + "\n    }\n" + param_method + "\n    func startupParams() {\n" + param_startup + "\n    }\n}\n"
(out / "Subject.swift").write_text(stub)
(out / "Checks.swift").write_text((Path(__file__).parent / "TerminalChecks.swift").read_text())
subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules"),
                str(out / "Subject.swift"), str(out / "Checks.swift"), "-o", str(out / "checks")], check=True)
raise SystemExit(subprocess.run([str(out / "checks")]).returncode)
