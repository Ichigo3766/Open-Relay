"""Compile the actual exporter, message model, and tool parser; verify with PDFKit."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = (root / "Open UI/Shared/Components/ToolCallView.swift").read_text()
parser = parser.split("// MARK: - Tool Call Data", 1)[1].split("// MARK: - Rich UI Embed View", 1)[0]
# Terminal file metadata is not used by text export. Its parser remains outside this harness.
stub = "import Foundation\nimport os\nstruct TerminalFileAttachment { init?(result: String?, arguments: String?) { return nil } }\n"
for view in ["MainChatView", "iPadMainChatView"]:
    source = (root / f"Open UI/Features/Chat/Views/{view}.swift").read_text()
    assert "ChatPDFExporter.export(title: title, messages: messages)" in source
    assert "downloadChatAsPDF" not in source
assert "/api/v1/utils/pdf" not in (root / "Open UI/Core/Networking/APIClient.swift").read_text()
with tempfile.TemporaryDirectory(prefix="relay-pdf-checks-") as directory:
    work = Path(directory)
    (work / "Parser.swift").write_text(stub + parser)
    subprocess.run(["swiftc", "-swift-version", "5", str(root / "Open UI/Core/Models/ChatMessage.swift"),
                    str(root / "Open UI/Core/Services/ChatPDFExporter.swift"), str(work / "Parser.swift"),
                    str(root / "Tests/ChatPDF/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
