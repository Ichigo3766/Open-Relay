"""Use the unchanged production composer layout in the isolated test app."""
from pathlib import Path
import argparse
import subprocess

here = Path(__file__).resolve().parent
root = here.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--baseline", metavar="REF")
args = parser.parse_args()

def read(name):
    if args.baseline:
        return subprocess.check_output(["git", "show", f"{args.baseline}:{name}"], cwd=root).decode()
    return (root / name).read_text()

source = read("Open UI/Shared/Components/ChatInputField.swift")
layout = source.split("private struct ComposerLayout: Layout {", 1)[1].split("private struct PDFKitView", 1)[0]
output = here / ".generated"
output.mkdir(exist_ok=True)
(output / "ComposerLayout.swift").write_text("import SwiftUI\nstruct ComposerLayout: Layout {" + layout)
(output / "PasteableTextView.swift").write_text(read("Open UI/Shared/Components/PasteableTextView.swift"))
