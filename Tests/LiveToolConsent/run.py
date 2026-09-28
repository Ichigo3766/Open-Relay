"""Compile production prompt state; --baseline reproduces the original auto-approval."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="relay-consent-") as directory:
    directory = pathlib.Path(directory)
    if "--baseline" in sys.argv:
        source = subprocess.check_output(["git", "show", "origin/main:Open UI/Features/Chat/ViewModels/ChatViewModel.swift"], cwd=root, text=True)
        body = source.split('case "confirmation":', 1)[1].split('case "execute":', 1)[0]
        main = directory / "main.swift"
        main.write_text('var replies: [Any?] = []\nlet ack: ((Any?) -> Void)? = { replies.append($0) }\n' + body + '\nprecondition(replies.isEmpty, "Confirmation must wait for the user")\n')
        sources = [main]
    else:
        socket = (root / "Open UI/Core/Networking/SocketIOService.swift").read_text()
        ack = socket[socket.index("    func emitAck("):socket.index("    /// Emits a Socket.IO event and waits")]
        transport = directory / "Transport.swift"
        transport.write_text("import Foundation\nfinal class Transport { var sid: String? = \"first\"; var isConnected = true; var sent: [String] = []; func send(_ text: String) { sent.append(text) }\n" + ack + "\n}")
        sources = [root / "Open UI/Core/Services/ChatEventPrompts.swift", root / "Tests/LiveToolConsent/Checks.swift", transport]
    binary = directory / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", *map(str, sources), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
