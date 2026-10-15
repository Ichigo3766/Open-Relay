"""Compile production startup orchestration against invented, delayed transports."""
from pathlib import Path
import argparse
import os
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
args = parser.parse_args()
repo, out = args.source_root.resolve(), args.output.resolve()
if out == repo or repo in out.parents:
    raise SystemExit("Build output must be outside the checkout.")
out.mkdir(parents=True, exist_ok=True)


def body(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


vm = (repo / "Open UI/Features/Chat/ViewModels/ChatListViewModel.swift").read_text()
load = body(vm, "    func loadConversations(")
views = []
for filename, marker in [
    ("MainChatView.swift", "private func applyLifecycleHandlers"),
    ("iPadMainChatView.swift", "onSocketSetup: @escaping () -> Void"),
]:
    source = (repo / "Open UI/Features/Chat/Views" / filename).read_text()
    task = body(source[source.index(marker):], ".task {")
    task = task[len(".task {"):-1]
    for name in ["activeConversationId", "activeChannelId", "activeFolderWorkspaceId", "newChatGeneration"]:
        task = task.replace(name + ".wrappedValue", name)
    # SwiftUI views are values; the test host is a reference so it can record navigation.
    task = re.sub(r"(?<![\w.])(dependencies|listViewModel|channelListVM|activeConversationId|activeChannelId|activeFolderWorkspaceId|newChatGeneration|registerSocketReconnectHandler|onSocketSetup|openChannelFromLink)\b", r"self.\1", task)
    views.append("func run" + ("Phone" if filename == "MainChatView.swift" else "Pad") + "() async {\n" + task + "\n}")

swift = Path(__file__).with_name("checks.swift").read_text()
swift = swift.replace("// PRODUCTION_LOAD", load).replace("// PRODUCTION_VIEWS", "\n".join(views))
(out / "checks.swift").write_text(swift)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / "module-cache"), TMPDIR=str(out))
subprocess.run(["swiftc", "-parse-as-library", "-O", "-module-cache-path", str(out / "module-cache"),
                str(out / "checks.swift"), "-o", str(out / "checks")], check=True, env=env)
subprocess.run([str(out / "checks")], check=True, env=env)
