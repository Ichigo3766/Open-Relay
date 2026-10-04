#!/usr/bin/env python3
"""Run actual public client methods with synthetic service boundaries on macOS."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

PIN = "84ea58b4e05b967fde923ac09206f17668777450"
HERE = Path(__file__).resolve().parent
VM = "Open UI/Features/Chat/ViewModels/ChatViewModel.swift"
MODELS = ["ChatMessage", "MessageHistory", "Conversation", "ChatAdvancedParams", "ChatContextUsage"]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("checkout", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--working-tree", action="store_true")
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    hashes = {}

    def source(path):
        if args.working_tree:
            content = (args.checkout / path).read_text()
        else:
            content = subprocess.check_output(["git", "show", f"{PIN}:{path}"], cwd=args.checkout, text=True)
        hashes[path] = hashlib.sha256(content.encode()).hexdigest()
        return content

    vm = source(VM)
    sections = [
        ("    private func syncFlatMessagesToTreeNodes()", "    var selectedModel:"),
        ("    func syncWithServer()", "    // MARK: - Entry Sync"),
        ("    @discardableResult\n    func sendMessage", "    /// Stops the current streaming response"),
        ("    func reloadConversation()", "    /// Syncs local conversation state with the server."),
        ("    private func cleanupStreaming()", "    // MARK: - Message Queue Actions"),
    ]
    methods = "\n".join(vm[vm.index(start):vm.index(end, vm.index(start))] for start, end in sections)
    prelude = (HERE / "Stubs.swift").read_text()
    (out / "Client.swift").write_text(prelude + methods + "\n}\n")
    for model in MODELS:
        (out / f"{model}.swift").write_text(source(f"Open UI/Core/Models/{model}.swift"))
    (out / "Checks.swift").write_text((HERE / "Checks.swift").read_text())
    (out / "manifest.json").write_text(json.dumps({"revision": PIN, "working_tree": args.working_tree, "sha256": hashes}, indent=2) + "\n")


if __name__ == "__main__":
    main()
