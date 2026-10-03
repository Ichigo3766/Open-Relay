"""Execute the app's exact background-audio guards with synthetic session doubles."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--revision", help="Run the regression against a Git revision")
parser.add_argument("--output", type=Path, required=True, help="Disposable build directory")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
path = "Open UI/App/Open_UIApp.swift"
source = subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=root).decode() if args.revision else (root / path).read_text()
start = source.index("let keepMicrophoneActive =") if "let keepMicrophoneActive =" in source else source.index("if CallAudioSession.isCallActive {")
end = source.index('print("🌙[APP] AudioSession after BG handling', start)
body = source[start:end]
fixture = '''import Foundation
enum Engine: String, CaseIterable { case system, server, kokoro, qwen3 }
enum State: CaseIterable { case idle, listening, processing }
enum CallAudioSession { static var isCallActive = false }
final class Audio { var stops = 0; func stopAndUnload() { stops += 1 } }
final class Speech {
    var activeEngine = Engine.system
    var stops = 0
    let kokoroService = Audio()
    func stop() { stops += 1 }
}
final class Dictation { var state = State.idle }
final class Dependencies { let dictationService = Dictation() }
func background(_ tts: Speech, _ dependencies: Dependencies) {
''' + body + '''
}
var failures = 0
var checks = 0
for engine in Engine.allCases {
    for call in [false, true] {
        for state in State.allCases {
            let speech = Speech(); speech.activeEngine = engine
            let dependencies = Dependencies(); dependencies.dictationService.state = state
            CallAudioSession.isCallActive = call
            background(speech, dependencies)
            let recording = call || state == .listening
            let expectedStops = !recording && (engine == .kokoro || engine == .qwen3) ? 1 : 0
            let expectedUnloads = !recording && engine != .server ? 1 : 0
            checks += 1
            if speech.stops != expectedStops || speech.kokoroService.stops != expectedUnloads {
                failures += 1
                print("FAIL engine=\\(engine) call=\\(call) dictation=\\(state)")
            }
        }
    }
}
print("Background audio: \\(checks - failures)/\\(checks) passed")
exit(failures == 0 ? 0 : 1)
'''
args.output.mkdir(parents=True, exist_ok=True)
environment = os.environ.copy()
for variable, directory in [("TMPDIR", "tmp"), ("CLANG_MODULE_CACHE_PATH", "module-cache")]:
    location = args.output.resolve() / directory
    location.mkdir(exist_ok=True)
    environment[variable] = str(location)
swift = args.output / "BackgroundAudio.swift"
swift.write_text(fixture)
executable = args.output / "BackgroundAudio"
subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(executable)], check=True, env=environment)
raise SystemExit(subprocess.run([str(executable)]).returncode)
