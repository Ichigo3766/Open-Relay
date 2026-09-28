"""Stage unchanged production editor/layout in an external synthetic test host."""
import argparse
from pathlib import Path
import shutil
import subprocess

here = Path(__file__).resolve().parent
root = here.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--baseline")
args = parser.parse_args()
output = args.output.resolve()
assert root != output and root not in output.parents
output.mkdir(parents=True, exist_ok=True)

def source(name):
    if args.baseline:
        return subprocess.check_output(["git", "show", f"{args.baseline}:{name}"], cwd=root).decode()
    return (root / name).read_text()

layout = source("Open UI/Shared/Components/ChatInputField.swift")
layout = layout.split("private struct ComposerLayout: Layout {", 1)[1].split("private struct PDFKitView", 1)[0]
(output / "ComposerLayout.swift").write_text("import SwiftUI\nstruct ComposerLayout: Layout {" + layout)
(output / "PasteableTextView.swift").write_text(source("Open UI/Shared/Components/PasteableTextView.swift"))
for name in ["Harness.swift", "CaretTests.swift", "project.yml"]:
    shutil.copyfile(here / name, output / name)
