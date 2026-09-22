#!/usr/bin/env python3
"""Compile the production entry and fetch gates with a synthetic server counter."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift").read_text()
start = source.index("    func syncOnEntry() {")
end = source.index("\n    }", start) + len("\n    }")
entry = source[start:end]
start = source.index("    func syncWithServer() async {")
end = source.index("            let serverMessages = serverConversation.messages", start)
# Stop after the fetch and success timestamp; reconciliation is outside this test.
fetch = source[start:end] + "            _ = serverConversation\n        } catch {}\n    }"
harness = (Path(__file__).parent / "Checks.swift").read_text()
harness = harness.replace("// ENTRY_METHOD", entry).replace("// FETCH_GATE", fetch)
with tempfile.TemporaryDirectory(prefix="relay-entry-tests-") as directory:
    swift = Path(directory) / "Checks.swift"
    binary = Path(directory) / "checks"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
