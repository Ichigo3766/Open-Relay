"""Copy tracked client sources to a new disposable QA directory; never edit source.

The gallery renders real sheets, not mockups. For container-owned close buttons,
extract their complete ToolbarItem directly and replace only the dismiss action.
"""
import argparse
import re
import shutil
import subprocess
from pathlib import Path
from audit import ROOT, close_toolbars, closing_brace

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--refresh-gallery", action="store_true")
args = parser.parse_args()
output = args.output.resolve()
assert output != ROOT and ROOT not in output.parents
assert args.refresh_gallery or not output.exists()
if args.refresh_gallery:
    assert (output / "Open UI/CloseButtonGallery.swift").is_file()
output.mkdir(parents=True, exist_ok=args.refresh_gallery)
paths = [] if args.refresh_gallery else subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
for name in filter(None, paths):
    source = ROOT / name
    if source.is_file():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)

mapping = {
    "Features/Chat/Views/MainChatView.swift": ["notes", "channels", "memories", "admin"],
    "Features/Chat/Views/iPadMainChatView.swift": ["ipad-admin", "ipad-memories", "ipad-notes"],
    "App/Open_UIApp.swift": ["server-switcher", "server-sheet"],
}
cases = []
for name, screens in mapping.items():
    blocks = list(close_toolbars((output / "Open UI" / name).read_text()))
    assert len(blocks) == len(screens), name
    for screen, (_, block) in zip(screens, blocks):
        button = re.search(r'Button(?:\([^\n]*\))?\s*\{', block)
        start = block.index("{", button.start())
        end = closing_brace(block, start)
        block = block[:start] + "{ dismiss() }" + block[end:]
        cases.append(f'case "{screen}": return AnyView(NavigationStack {{ containerContent.toolbar {{\n{block}\n}} }})')
gallery = (Path(__file__).parent / "Gallery.swift").read_text()
gallery = gallery.replace("// EXTRACTED_TOOLBARS", 'switch screen {\n' + "\n".join(cases) + '\ndefault: return AnyView(EmptyView())\n}')
(output / "Open UI/CloseButtonGallery.swift").write_text(gallery)
if args.refresh_gallery:
    print(output)
    raise SystemExit

app = output / "Open UI/App/Open_UIApp.swift"
text = app.read_text().replace("private var dependencies = AppDependencyContainer()", "private var dependencies = CloseButtonQARoot.dependencies()", 1)
text = text.replace("            RootView()\n", "            CloseButtonQARoot()\n", 1)
app.write_text(text)

# Test-only visibility, without changing this private sheet's implementation.
prompt = output / "Open UI/Features/Workspace/Views/PromptEditorView.swift"
prompt.write_text(prompt.read_text().replace("private struct PromptHistoryView:", "struct PromptHistoryView:"))

# Xcode's expression checker needs this split in the unmodified large chat body.
# Identical in both QA builds; not part of the close-button production patch.
chat = output / "Open UI/Features/Chat/Views/ChatDetailView.swift"
text = chat.read_text().replace("    var body: some View {\n        @Bindable var vm = viewModel", "    @ViewBuilder private var qaChatContent: some View {\n        @Bindable var vm = viewModel", 1)
text = text.replace("        // Toasts & banners", "    }\n\n    var body: some View {\n        qaChatContent\n        // Toasts & banners", 1)
text = text.replace(".sheet(isPresented: Binding(\n            get: { editingAssistantMessageId", ".sheet(isPresented: Binding<Bool>(\n            get: { editingAssistantMessageId", 1)
chat.write_text(text)
print(output)
