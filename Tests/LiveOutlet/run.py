"""Actual message/history code, fresh synthetic text, no server imports."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def source(path):
    return subprocess.check_output(["git", "show", "4151a735512d5d6dbc9fd1962fa806517a0d4ea7:" + path], cwd=root, text=True) if baseline else (root / path).read_text()
with tempfile.TemporaryDirectory(prefix="relay-outlet-checks-") as directory:
    work = Path(directory)
    production = source("Open UI/Core/Models/ChatMessage.swift") + source("Open UI/Core/Models/MessageHistory.swift")
    production += "\nenum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }\n"
    if not baseline:
        vm = source("Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
        method = "    func applyOutletMessages(" + vm.split("    private func applyOutletMessages(", 1)[1].split("    private func handleChatEvent(", 1)[0]
        assert vm.count('case "chat:outlet":') == 2
        assert vm.index('case "chat:outlet":') < vm.index("if let recentId = lastCompletedSelfInitiatedMessageId")
        production += (root / "Tests/LiveOutlet/Stubs.swift").read_text()
        production += "\nfinal class Harness { var conversationId: String? = \"demo-chat\"; var conversation: Chat? = Chat(); let streamingStore = Store()\n" + method + "\n}\n"
    (work / "Production.swift").write_text(production)
    subprocess.run(["swiftc", "-swift-version", "5", *(["-D", "BASELINE"] if baseline else []), str(work / "Production.swift"), str(root / "Tests/LiveOutlet/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
