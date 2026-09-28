"""Compile actual embed handling and message/history persistence with a stub chat."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def source(path):
    return subprocess.check_output(["git", "show", "origin/main:" + path], cwd=root, text=True) if baseline else (root / path).read_text()

message = source("Open UI/Core/Models/ChatMessage.swift")
history = source("Open UI/Core/Models/MessageHistory.swift").split("    // MARK: - Parsing")[0] + "\n}\n"
vm = source("Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
method = ""
if not baseline:
    method = vm.split("    private func applyMessageEmbeds(", 1)[1].split("    private func handleChatEvent(", 1)[0]
    method = "    func applyMessageEmbeds(" + method
    assert vm.count('case "embeds", "chat:message:embeds":') == 2
    assert vm.index('case "embeds", "chat:message:embeds":') < vm.index("if let recentId = lastCompletedSelfInitiatedMessageId")
stub = """
struct Chat { var id = "demo-chat"; var history = MessageHistory(); var messages: [ChatMessage] = [] }
final class Harness { var conversationId: String? = "demo-chat"; var conversation: Chat? = Chat()
"""
with tempfile.TemporaryDirectory(prefix="relay-live-embeds-") as directory:
    work = Path(directory)
    (work / "Production.swift").write_text(message + history + stub + method + "\n}\n")
    subprocess.run(["swiftc", "-swift-version", "5", *(["-D", "BASELINE"] if baseline else []), str(work / "Production.swift"), str(root / "Tests/LiveEmbeds/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
