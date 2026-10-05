#!/usr/bin/env python3
"""Exercise the actual file-population method and both completion call sites."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--ref", help="Read production source from a Git revision instead of the working tree")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
path = "Open UI/Features/Chat/ViewModels/ChatViewModel.swift"
source = subprocess.check_output(["git", "show", f"{args.ref}:{path}"], cwd=root, text=True) if args.ref else (root / path).read_text()


def section(start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


populate = section("    private func populateFilesFromToolResults(", "    private func appendSources(")
normal = section("                    // Last resort: if server still hasn't provided files", "                } else {")
empty = section("        // Last resort: extract file IDs from tool call results in content", "        // NOTE: Do NOT call saveConversationToServer() here")
swift = r'''
import Foundation
struct Log { func info(_ text: String) {} }
struct File: Equatable { let id: String }
enum Role { case user, assistant }
struct Message { var id = "synthetic-reply"; var role = Role.assistant; var content = "Synthetic text"; var files: [File] = [] }
struct Node { var files: [File] = [] }
struct History {
    var nodes = ["synthetic-reply": Node()]
    mutating func updateNode(id: String, change: (inout Node) -> Void) {
        if var node = nodes[id] { change(&node); nodes[id] = node }
    }
}
struct Conversation { var messages = [Message()]; var history = History() }
enum ToolCallParser {
    // Parsing is an unchanged dependency; inject a freshly invented file reference.
    static func extractFileReferences(from content: String) -> [File] {
        content == "Synthetic tool output" ? [File(id: "synthetic-file")] : []
    }
}
@MainActor final class ChatViewModel {
    let logger = Log()
    var conversation: Conversation? = Conversation()
    var saves = 0
    func syncToServerViaTree() async { saves += 1 }
''' + populate + '''
    func normalCompletion() async {
        let assistantMessageId = "synthetic-reply"
''' + normal + '''
    }
    func emptyCompletion() async {
        let assistantMessageId = "synthetic-reply"
''' + empty + r'''
    }
}
@main struct Checks {
    @MainActor static func main() async {
        var failures = 0
        var assertions = 0
        func check(_ condition: Bool, _ label: String) {
            assertions += 1
            if !condition { failures += 1; print("FAIL: " + label) }
        }
        for emptyPath in [false, true] {
            for scenario in 0..<9 {
                let vm = ChatViewModel()
                switch scenario {
                case 1: vm.conversation?.messages[0].content = "Synthetic tool output"
                case 2: vm.conversation?.messages[0].files = [File(id: "synthetic-server-file")]
                case 3: vm.conversation?.messages[0].content = "   "
                case 4: vm.conversation?.messages[0].role = .user; vm.conversation?.messages[0].content = "Synthetic tool output"
                case 5: vm.conversation = nil
                case 6: vm.conversation?.messages[0].id = "synthetic-other-reply"
                case 7: vm.conversation?.messages[0].content = "Synthetic tool output"; vm.conversation?.history.nodes.removeAll()
                case 8: vm.conversation?.messages[0].content = "Synthetic tool output"; vm.conversation?.history.nodes["synthetic-reply"]?.files = [File(id: "synthetic-tree-file")]
                default: break
                }
                let original = vm.conversation
                if emptyPath { await vm.emptyCompletion() } else { await vm.normalCompletion() }
                let added = [1, 7, 8].contains(scenario)
                check(vm.saves == (added ? 1 : 0), "save count, path \(emptyPath), scenario \(scenario)")
                check(vm.conversation?.messages.first?.content == original?.messages.first?.content, "content preserved")
                if added {
                    check(vm.conversation?.messages[0].files == [File(id: "synthetic-file")], "extracted file retained")
                    if scenario != 7 {
                        let expected = scenario == 8 ? "synthetic-tree-file" : "synthetic-file"
                        check(vm.conversation?.history.nodes["synthetic-reply"]?.files == [File(id: expected)], "tree files retained")
                    }
                    if emptyPath { await vm.emptyCompletion() } else { await vm.normalCompletion() }
                    check(vm.saves == 1, "repeated extraction does not save again")
                } else {
                    check(vm.conversation?.messages.first?.files == original?.messages.first?.files, "existing files preserved")
                }
            }
        }
        print("\(assertions) assertions; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
cache = output / "module-cache"
cache.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(dir=output, prefix="file-output-") as directory:
    directory = Path(directory)
    generated = directory / "Checks.swift"
    generated.write_text(swift)
    env = dict(os.environ, TMPDIR=str(directory), CLANG_MODULE_CACHE_PATH=str(cache))
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(cache), str(generated), "-o", str(directory / "checks")], env=env, check=True)
    raise SystemExit(subprocess.run([str(directory / "checks")], env=env).returncode)
