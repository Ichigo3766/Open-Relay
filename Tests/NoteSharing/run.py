"""Compile the production sharing model/API with a synthetic network boundary."""
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[1]
with tempfile.TemporaryDirectory(prefix="note-sharing-") as directory:
    binary = Path(directory) / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
                    str(root / "Open UI/Core/Services/NoteSharingModel.swift"),
                    str(here / "Checks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
