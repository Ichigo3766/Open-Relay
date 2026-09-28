"""Compile actual webhook model, wire methods, and state against synthetic stubs."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
def method(text, signature):
    start = text.index(signature)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

source = (root / "Open UI/Core/Networking/APIClient.swift").read_text()
wire = (root / "Tests/ChannelWebhooks/Stubs.swift").read_text()
wire += "final class APIClient { let network = Network(); var baseURL = \"https://example.test/relay\"\n"
for name in ["getChannelWebhooks", "saveChannelWebhook", "deleteChannelWebhook"]:
    wire += method(source, "    func " + name + "(") + "\n"
wire += "}\n"
vm = (root / "Open UI/Features/Channels/ViewModels/ChannelWebhooksViewModel.swift").read_text().replace("@Observable ", "")
with tempfile.TemporaryDirectory(prefix="relay-webhooks-") as directory:
    work = Path(directory)
    (work / "Wire.swift").write_text(wire)
    (work / "State.swift").write_text(vm)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Wire.swift"), str(work / "State.swift"),
        str(root / "Open UI/Core/Models/ChannelWebhook.swift"),
        str(root / "Tests/ChannelWebhooks/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
