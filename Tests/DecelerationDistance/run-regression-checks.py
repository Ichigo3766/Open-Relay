"""Compile the production deceleration guard unchanged with synthetic geometry.
Usage: python3 Tests/DecelerationDistance/run-regression-checks.py /external/scratch
Use --source /path/to/ChatDetailView.swift to reproduce on another revision.
"""
from pathlib import Path
import argparse
import os
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--source", type=Path, default=root / "Open UI/Features/Chat/Views/ChatDetailView.swift")
options = parser.parse_args()
out = options.output.resolve()
if out == root or root in out.parents:
    raise SystemExit("Use a scratch directory outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
source = options.source.read_text()
start = source.index("                if viewModel.isStreaming && !isScrolledUp {", source.index(".onScrollPhaseChange"))
end = source.index("            case .idle, .interacting:", start)
subject = """import Foundation
struct Model { var isStreaming: Bool }
struct Pump { var contentHeight: CGFloat; var currentScrollOffsetY: CGFloat }
func decelerate(height: CGFloat, viewport: CGFloat, offset: CGFloat, streaming: Bool = true, paused: Bool = false) -> Bool {
    let viewModel = Model(isStreaming: streaming)
    let _pumpRef = Pump(contentHeight: height, currentScrollOffsetY: offset)
    let viewState_containerHeight = viewport
    var isScrolledUp = paused
""" + source[start:end] + "    return isScrolledUp\n}\n"
(out / "Subject.swift").write_text(subject)
(out / "Checks.swift").write_text((root / "Tests/DecelerationDistance/RegressionChecks.swift").read_text())
subprocess.run(["swiftc", "-O", "-module-cache-path", str(out / "modules"), str(out / "Subject.swift"), str(out / "Checks.swift"), "-o", str(out / "checks")], check=True)
subprocess.run([str(out / "checks")], env=dict(os.environ, TMPDIR=str(out)), check=True)
