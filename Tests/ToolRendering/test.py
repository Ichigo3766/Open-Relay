"""Run the production parser and pending-parse fallback with invented inputs."""
import argparse
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
args = argparse.ArgumentParser()
args.add_argument("--ref", help="Test a Git revision instead of the working tree")
revision = args.parse_args().ref

def read_source(path):
    return (subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT).decode()
            if revision else (ROOT / path).read_text())


source = read_source("Open UI/Shared/Components/ToolCallView.swift")
parser = source[source.index("actor MessageParseCache"):source.index("// MARK: - Rich UI Embed View")]
view = source[source.index("struct AssistantMessageContent: View"):]
fallback = view[view.index("            if let stale = resolvedResult"):view.index("        }()")]

with tempfile.TemporaryDirectory(prefix="tool-rendering-tests-") as directory:
    folder = Path(directory)
    production = folder / "Production.swift"
    production.write_text("import Foundation\n" + parser + """
func pendingResult(content: String, resolvedResult: ToolCallParser.OrderedParseResult?)
    -> ToolCallParser.OrderedParseResult {
""" + fallback + "\n}\n")
    binary = folder / "tests"
    models = [folder / name for name in ["ChatMessage.swift", "MessageHistory.swift"]]
    for model in models:
        model.write_text(read_source("Open UI/Core/Models/" + model.name))
    subprocess.run(["xcrun", "swiftc", "-O", "-o", str(binary), str(production),
                    str(HERE / "RegressionTests.swift"),
                    *map(str, models)], check=True)
    subprocess.run([str(binary)], check=True)
