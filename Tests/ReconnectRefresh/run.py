#!/usr/bin/env python3
"""Compile the actual callback registration methods with synthetic dependencies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def method(path, name):
    source = (root / path).read_text()
    start = source.index(f"    private func {name}(")
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end].replace("private func", "func", 1)


source = (root / "Open UI/Core/Networking/SocketIOService.swift").read_text()
start = source.index("            DispatchQueue.main.async { [weak self] in\n                self?.onConnect?()")
end = source.index('\n        case "1":', start)
handshake = source[start:end]
harness = (Path(__file__).parent / "Checks.swift").read_text()
for name, view in [("PHONE", "MainChatView"), ("TABLET", "iPadMainChatView")]:
    harness = harness.replace(f"// {name}_REGISTRATION", method(
        f"Open UI/Features/Chat/Views/{view}.swift", "registerSocketReconnectHandler"))
harness = harness.replace("// SOCKET_HANDSHAKE", handshake)
with tempfile.TemporaryDirectory(prefix="relay-reconnect-tests-") as directory:
    swift = Path(directory) / "Checks.swift"
    binary = Path(directory) / "checks"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
