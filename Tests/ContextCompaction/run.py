"""Compile actual history models; no server modules or private data."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def source(path):
    return subprocess.check_output(["git", "show", "4151a735512d5d6dbc9fd1962fa806517a0d4ea7:" + path], cwd=root, text=True) if baseline else (root / path).read_text()
with tempfile.TemporaryDirectory(prefix="relay-context-checks-") as directory:
    work = Path(directory)
    production = (source("Open UI/Core/Models/ChatMessage.swift")
        + source("Open UI/Core/Models/MessageHistory.swift")
        + "\nenum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }\n")
    if not baseline:
        vm = source("Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
        methods = vm.split("    var isCompactingContext = false", 1)[1].split("    /// Bumped each time a regenerate begins.", 1)[0]
        production += source("Open UI/Core/Models/ChatContextUsage.swift")
        production += (root / "Tests/ContextCompaction/Stubs.swift").read_text()
        production += source("Open UI/Core/Networking/APIClient+Context.swift")
        production += "\n@MainActor final class Harness { var manager: Manager? = Manager(); var conversationId: String? = \"demo\"; var conversation: Chat? = Chat(); var selectedModelId: String? = \"demo-model\"; var isStreaming = false; var isCompactingContext = false\n" + methods + "\n}\n"
    (work / "Production.swift").write_text(production)
    subprocess.run(["swiftc", "-swift-version", "5", *(["-D", "BASELINE"] if baseline else []), str(work / "Production.swift"), str(root / "Tests/ContextCompaction/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
