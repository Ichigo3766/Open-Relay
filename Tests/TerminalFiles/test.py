"""Run with the fixture's Python environment; all generated files stay in --work."""
import argparse
import json
import subprocess
from pathlib import Path
from fixture import CHATS

parser = argparse.ArgumentParser()
parser.add_argument("--work", type=Path, required=True)
parser.add_argument("--url", default="http://127.0.0.1:18191")
args = parser.parse_args()
here = Path(__file__).resolve().parent
root = here.parent.parent
args.work.mkdir(parents=True, exist_ok=True)
source = (root / "Open UI/Shared/Components/ToolCallView.swift").read_text()
parser_code = source[source.index("// MARK: - Tool Call Data"):source.index("// MARK: - Rich UI Embed View")]
extracted = args.work / "Parser.swift"
extracted.write_text("import Foundation\n" + parser_code)
binary = args.work / "tests"
subprocess.run(["xcrun", "swiftc", "-o", str(binary), str(here / "Tests.swift"), str(extracted),
                str(root / "Open UI/Core/Networking/TerminalFileDownload.swift"),
                *[str(root / "Open UI/Core/Models" / name) for name in
                  ["TerminalFileAttachment.swift", "ChatMessage.swift", "MessageHistory.swift"]]], check=True)
subprocess.run([str(binary), args.url, str(args.work / "motion.mp4")], input=json.dumps(CHATS).encode(), check=True)
