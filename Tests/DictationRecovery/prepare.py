"""Build isolated tests from production components; never access a microphone/server."""
import argparse
from pathlib import Path
import subprocess

here = Path(__file__).resolve().parent
root = here.parents[1]
out = here / ".generated"
out.mkdir(exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument("--baseline")
args = parser.parse_args()

def source(name):
    if args.baseline:
        return subprocess.check_output(["git", "show", f"{args.baseline}:{name}"], cwd=root).decode()
    return (root / name).read_text()

service = source("Open UI/Core/Services/DictationService.swift")
marker = "    private func startRecording() async {"
assert service.count(marker) == 1
service = service.replace(marker, marker + '\n        preconditionFailure("The fixture must not access the microphone")', 1)
if args.baseline:
    service += """
extension DictationService {
    func qaRecord(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try data.write(to: url)
        recordingURL = url
        activeEngine = "server"
        state = .listening
        return url
    }
}
"""
else:
    service += """
extension DictationService {
    func qaRecord(_ data: Data) throws -> URL {
        guard let context, pendingRecording == nil else { throw DictationRecoveryStore.RecoveryError.pendingRecording }
        let recording = try recoveryStore.begin(context, draft: currentDraft?() ?? "", engine: "server")
        pendingRecording = recording
        let url = recoveryStore.audioURL(recording)
        try data.write(to: url)
        activeEngine = "server"
        recordingDuration = 300
        intensity = 5
        state = .listening
        return url
    }
}
"""
(out / "DictationService.swift").write_text(service)
(out / "DictationOverlayView.swift").write_text(source("Open UI/Shared/Components/DictationOverlayView.swift"))
(out / "DictationRecoveryStore.swift").write_text((root / "Open UI/Core/Services/DictationRecoveryStore.swift").read_text())
(out / "SelectedTests.swift").write_text((here / ("BaselineTests.swift" if args.baseline else "RecoveryTests.swift")).read_text())
(out / "Harness.swift").write_text('import SwiftUI\n@main struct Fixture: App { var body: some Scene { WindowGroup { Text("Synthetic baseline") } } }' if args.baseline else (here / "Harness.swift").read_text())
# Compile the exact draft integration properties/method, without unrelated chat dependencies.
model = (root / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift").read_text()
conversation = model[model.index("    var conversation: Conversation?"):model.index("    var availableModels:")]
draft = model[model.index('    var inputText: String = ""'):model.index('    /// Toggled to `true` by the Ask')]
(out / "ChatDraftQA.swift").write_text('import Foundation\nimport Observation\nstruct Conversation { let id: String }\n@MainActor @Observable final class ChatDraftQA {\n let conversationId: String? = nil\n var errorMessage: String?\n' + conversation + draft + '\n}')
audio = out / "five-minute.m4a"
if not audio.exists():
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=300:sample_rate=16000", "-ac", "1", "-c:a", "aac", "-b:a", "32k", str(audio)], check=True)
