#!/usr/bin/env python3
"""Compare the current parser against an unchanged public upstream revision."""
from pathlib import Path
import subprocess
import sys
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[1]
path = "Open UI/Shared/Components/ToolCallView.swift"
source = (root / path).read_text()
baseline = subprocess.check_output([
    "git", "show", "3765c48ab2a79af59ce39e4fc0d704491836648e:" + path,
], cwd=root, text=True)
end_marker = "    // MARK: - File ID Extraction from Tool Results"
current = source[source.index("// MARK: - Global Off-Main Parse Cache"):source.index(end_marker)] + "}\n"
reference = baseline[baseline.index("enum ToolCallParser {"):baseline.index(end_marker)] + "}\n"
reference = reference.replace("enum ToolCallParser {", "enum ReferenceToolCallParser {", 1)

with tempfile.TemporaryDirectory(prefix="reasoning-parser-tests-") as directory:
    temporary = Path(directory)
    extracted = temporary / "Parsers.swift"
    extracted.write_text("import Foundation\nimport os\n" + current + reference)
    executable = temporary / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-O", "-swift-version", "5",
        "-default-isolation", "MainActor", "-parse-as-library",
        str(extracted), str(here / "ParserChecks.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), *sys.argv[1:]], check=True)
