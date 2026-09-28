#!/usr/bin/env python3
"""Compile the production model and exact API method with a deterministic transport."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
api = (root / "Open UI/Core/Networking/APIClient.swift").read_text()
start = api.index("    func updateAutomation(")
end = api.index("    func toggleAutomation(", start)
view_model = (root / "Open UI/Features/Automations/ViewModels/AutomationsViewModel.swift").read_text()
vm_start = view_model.index("    func updateAutomation(")
vm_end = view_model.index("    // MARK: - Delete", vm_start)
with tempfile.TemporaryDirectory(prefix="relay-automations-", dir=os.environ.get("TMPDIR")) as directory:
    output = Path(directory)
    method = output / "Update.swift"
    method.write_text("import Foundation\nextension APIClient {\n" + api[start:end] +
                      "\n}\nextension AutomationsViewModel {\n" + view_model[vm_start:vm_end] + "\n}\n")
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(output / "ModuleCache"),
        str(root / "Open UI/Core/Models/Automation.swift"),
        str(root / "Open UI/Core/Networking/APIError.swift"), str(method),
        str(root / "Tests/Automations/Checks.swift"), "-o", str(output / "checks"),
    ], check=True)
    subprocess.run([str(output / "checks")], check=True)
