#!/usr/bin/env python3
"""Exercise exact production API/view-model methods with a mock transport."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
api = (root / "Open UI/Core/Networking/APIClient.swift").read_text()
start = api.index("    func verifyImageConfigURL(")
end = api.index("    // MARK: - Retrieval", start)
vm = (root / "Open UI/Features/Admin/ViewModels/AdminImagesViewModel.swift").read_text()
vm_start = vm.index("    func verifyURL(")
vm_end = vm.index("    // MARK: - Workflow", vm_start)
baseline = ["-D", "BASELINE"] if "func verifyImageConfigURL()" in api else []
with tempfile.TemporaryDirectory(prefix="relay-image-verification-", dir=os.environ.get("TMPDIR")) as directory:
    output = Path(directory)
    method = output / "Methods.swift"
    method.write_text("import Foundation\nextension APIClient {\n" + api[start:end] +
                      "\n}\nextension AdminImagesViewModel {\n" + vm[vm_start:vm_end] + "\n}\n")
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
                    "-module-cache-path", str(output / "ModuleCache"), *baseline,
                    str(method), str(root / "Tests/ImageVerification/Checks.swift"),
                    "-o", str(output / "checks")], check=True)
    subprocess.run([str(output / "checks")], check=True)
