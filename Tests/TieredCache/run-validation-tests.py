"""Compile production conversation loading with a gated synthetic transport.
Usage: python3 Tests/TieredCache/run-validation-tests.py /external/scratch
Use --source /path/to/ChatViewModel.swift to test an earlier cache revision.
"""
from pathlib import Path
import argparse
import os
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--source", type=Path, default=root / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
args = parser.parse_args()
out = args.output.resolve()
if out == root or root in out.parents:
    raise SystemExit("Use a scratch directory outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
source = args.source.read_text()
start = source.index("    func loadConversation() async {")
end = source.index("    private func prepareLoadedConversation(", start)
stubs = """import Foundation
struct Conversation { var id: String; var payload = Data(repeating: 7, count: 1024 * 1024) }
struct Snapshot { var conversation: Conversation; var isRecent = false; var allowsStale: Bool? = true; var validatedAt = Date() }
@MainActor final class Network { var conversationCacheScope: String? = "invented-account" }
@MainActor final class APIClient {
    let network = Network()
    var snapshot: Snapshot? = Snapshot(conversation: Conversation(id: "invented-cached"))
    func cachedConversation(id: String) async -> Snapshot? { snapshot }
}
@MainActor final class ConversationManager {
    let apiClient = APIClient()
    var pending: CheckedContinuation<Conversation, Error>?
    var fetches = 0
    var cancellations = 0
    func fetchConversation(id: String, preferRecent: Bool) async throws -> Conversation {
        fetches += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: {
            Task { @MainActor in self.cancellations += 1 }
        }
    }
    func finish(_ result: Result<Conversation, Error>) {
        let continuation = pending
        pending = nil
        continuation!.resume(with: result)
    }
}
enum APIError: Error {
    case offline, other
    case httpError(Int, String?, String?)
    var requiresReauth: Bool { if case .httpError(401, _, _) = self { return true }; return false }
    var isConnectivityError: Bool { if case .offline = self { return true }; return false }
    static func from(_ error: Error) -> Self { error as? Self ?? .other }
}
@MainActor final class ValidationSubject {
    var conversationId: String? = "invented-chat"
    let manager: ConversationManager?
    var cacheValidation = UUID()
    var isLoadingConversation = false
    var errorMessage: String?
    var conversation: Conversation?
    var tasks = [1]
    var chatFiles = [1]
    var lastSyncTime = Date.distantPast
    var isStreaming = false
    var syncAllowed = true
    init(manager: ConversationManager) { self.manager = manager }
    func prepareLoadedConversation(_ value: Conversation, allowSync: Bool = true) { conversation = value; syncAllowed = allowSync }
    func adoptServerMessages(serverConversation: Conversation) { conversation = serverConversation }
"""
(out / "Subject.swift").write_text(stubs + source[start:end] + "\n}\n")
(out / "Checks.swift").write_text((root / "Tests/TieredCache/ValidationTests.swift").read_text())
subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules"),
    str(out / "Subject.swift"), str(out / "Checks.swift"), "-o", str(out / "checks")], check=True)
subprocess.run([str(out / "checks")], env=dict(os.environ, TMPDIR=str(out)), check=True)
