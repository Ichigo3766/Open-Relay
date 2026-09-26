"""Copy tracked client source into an isolated, loopback-only QA application."""
import argparse
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--baseline", metavar="REF")
parser.add_argument("--refresh", action="store_true")
args = parser.parse_args()
output = args.output.resolve()
assert output != ROOT and ROOT not in output.parents
assert (output / "Open UI/SidebarQARoot.swift").is_file() if args.refresh else not output.exists()
output.mkdir(parents=True, exist_ok=args.refresh)
command = ["git", "ls-tree", "-rz", "--name-only", args.baseline] if args.baseline else ["git", "ls-files", "-z"]
for name in filter(None, subprocess.check_output(command, cwd=ROOT).decode().split("\0")):
    source, target = ROOT / name, output / name
    if not args.baseline and not source.is_file():
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    if args.baseline:
        target.write_bytes(subprocess.check_output(["git", "show", f"{args.baseline}:{name}"], cwd=ROOT))
    else:
        shutil.copyfile(source, target)
shutil.copyfile(Path(__file__).with_name("QARoot.swift"), output / "Open UI/SidebarQARoot.swift")
app = output / "Open UI/App/Open_UIApp.swift"
text = app.read_text().replace("private var dependencies = AppDependencyContainer()",
                               "private var dependencies = SidebarQARoot.dependencies()", 1)
app.write_text(text.replace("            RootView()\n", "            SidebarQARoot()\n", 1))

# Accessibility instrumentation only; separator appearance/layout is unchanged.
main = output / "Open UI/Features/Chat/Views/MainChatView.swift"
text = main.read_text()
anchor = "            .padding(.vertical, 6)\n    }\n\n    // MARK: - Drawer Section Label"
assert text.count(anchor) == 1
main.write_text(text.replace(anchor, "            .padding(.vertical, 6)\n"
    '            .accessibilityElement(children: .ignore)\n'
    '            .accessibilityLabel("Section separator")\n'
    '            .accessibilityIdentifier("qa-sidebar-divider")\n'
    '            .accessibilityHidden(false)\n    }\n\n    // MARK: - Drawer Section Label'))

# Identical QA-only expression split for Xcode's type checker in both versions.
chat = output / "Open UI/Features/Chat/Views/ChatDetailView.swift"
text = chat.read_text().replace("    var body: some View {\n        @Bindable var vm = viewModel",
                               "    @ViewBuilder private var qaChatContent: some View {\n        @Bindable var vm = viewModel", 1)
text = text.replace("        // Toasts & banners", "    }\n\n    var body: some View {\n        qaChatContent\n        // Toasts & banners", 1)
text = text.replace(".sheet(isPresented: Binding(\n            get: { editingAssistantMessageId",
                    ".sheet(isPresented: Binding<Bool>(\n            get: { editingAssistantMessageId", 1)
chat.write_text(text)
print(output)
