"""Prepare a disposable client with synthetic dictation, never live audio/data."""
import argparse
from pathlib import Path
import shutil
import subprocess

here = Path(__file__).resolve().parent
root = here.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
output = args.output.resolve()
assert not output.exists() and output != root and root not in output.parents
for name in filter(None, subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")):
    source, target = root / name, output / name
    if not source.is_file():
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
shutil.copyfile(here / "QARoot.swift", output / "Open UI/DictationQARoot.swift")
app = output / "Open UI/App/Open_UIApp.swift"
text = app.read_text().replace("private var dependencies = AppDependencyContainer()",
                               "private var dependencies = DictationQARoot.dependencies()", 1)
app.write_text(text.replace("            RootView()\n", "            DictationQARoot()\n", 1))

# Keep the real mic button, overlay, completion callback, and composer. Replace
# only recording/transcription in this QA copy; no microphone permission needed.
service = output / "Open UI/Core/Services/DictationService.swift"
text = service.read_text().replace("    func startDictation() async {", """    func startDictation() async {
        state = .listening
        activeEngine = "server"
        return
""", 1).replace("    func stopDictation() {", """    func stopDictation() {
        state = .processing
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            state = .idle
            onTranscriptReady?(DictationQARoot.transcript)
        }
        return
""", 1)
service.write_text(text)

# QA-only expression split for Xcode's type checker, identical in both builds.
chat = output / "Open UI/Features/Chat/Views/ChatDetailView.swift"
text = chat.read_text().replace("    var body: some View {\n        @Bindable var vm = viewModel",
                               "    @ViewBuilder private var qaChatContent: some View {\n        @Bindable var vm = viewModel", 1)
text = text.replace("        // Toasts & banners", "    }\n\n    var body: some View {\n        qaChatContent\n        // Toasts & banners", 1)
text = text.replace(".sheet(isPresented: Binding(\n            get: { editingAssistantMessageId",
                    ".sheet(isPresented: Binding<Bool>(\n            get: { editingAssistantMessageId", 1)
chat.write_text(text)
print(output)
