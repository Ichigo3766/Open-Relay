"""Compile the real socket dispatch with synthetic transport/cache dependencies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "Open UI/Core/Networking/SocketIOService.swift").read_text()
dispatch = source.split("    private func dispatchChatEvent(", 1)[1].split("    private func dispatchChannelEvent(", 1)[0]
routing = source.split("    private func shouldDeliver(", 1)[1].split("    // MARK: - Private: Heartbeat", 1)[0]
helper = source.split("// MARK: - Client execution RPC", 1)[1] if "// MARK: - Client execution RPC" in source else ""
checks = (root / "Tests/ClientRPC/Checks.swift").read_text()
with tempfile.TemporaryDirectory(prefix="relay-client-rpc-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text(checks.replace("// PRODUCTION", "func dispatchChatEvent(" + dispatch + "private func shouldDeliver(" + routing).replace("// HELPER", helper))
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "main.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
