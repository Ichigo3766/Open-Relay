#!/usr/bin/env python3
"""Compile the production cache/parser without the unrelated SwiftUI views."""
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
source = (here.parents[1] / "Open UI/Shared/Components/ToolCallView.swift").read_text()
start = source.index("// MARK: - Global Off-Main Parse Cache")
end = source.index("    // MARK: - File ID Extraction from Tool Results")

with tempfile.TemporaryDirectory(prefix="message-parse-cache-tests-") as directory:
    temporary = Path(directory)
    extracted = temporary / "Parser.swift"
    # The omitted file-extraction method belongs to the parser enum; close it.
    extracted.write_text("import Foundation\nimport os\n" + source[start:end] + "}\n")
    executable = temporary / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-O", "-swift-version", "5",
        "-default-isolation", "MainActor", "-parse-as-library",
        str(extracted), str(here / "CacheChecks.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
