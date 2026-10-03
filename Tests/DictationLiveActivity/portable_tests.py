"""Run dictation lifecycle tests on macOS with deterministic platform doubles.

Only staged copies are adapted: unavailable framework imports and iOS file
protection are omitted. Microphone, ActivityKit presentation, and Data Protection
are not tested by this runner. Production lifecycle code is otherwise unchanged.
"""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--without-duration-guard", action="store_true",
                    help="Reproduce the stopped-recorder duration regression")
parser.add_argument("--revision", help="Use production sources from a Git revision for a negative control")
args = parser.parse_args()
output = args.output.resolve()
root = Path(__file__).resolve().parents[2]
sources = output / "Tests" / "LifecycleTests"
sources.mkdir(parents=True, exist_ok=True)
paths = [
    "Open UI/Core/Models/DictationActivityAttributes.swift",
    "Open UI/Core/Services/DictationLiveActivityController.swift",
    "Open UI/Core/Services/DictationService.swift",
    "Open UI/Core/Services/DictationRecoveryStore.swift",
    "Tests/DictationLiveActivity/PlatformDoubles.swift",
    "Tests/DictationLiveActivity/RecordingTests.swift",
    "Tests/DictationLiveActivity/TranscriptionTests.swift",
]
for path in paths:
    source = (subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=root, text=True)
              if args.revision and path.startswith("Open UI/") else (root / path).read_text())
    source = source.replace("import ActivityKit\n", "").replace("import AVFoundation\n", "").replace("import UIKit\n", "")
    source = source.replace("[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]", "[:]")
    source = source.replace("[.atomic, .completeFileProtectionUntilFirstUserAuthentication]", "[.atomic]")
    source = source.replace("#if targetEnvironment(simulator)", "#if os(macOS) || targetEnvironment(simulator)")
    if args.without_duration_guard:
        source = source.replace(
            "if let recorder, recorder.isRecording { recordingDuration = recorder.currentTime }",
            "recordingDuration = recorder?.currentTime ?? recordingDuration")
    (sources / Path(path).name).write_text(source)

(sources / "UnavailablePlatformTypes.swift").write_text('''import Foundation
protocol ActivityAttributes {
    associatedtype ContentState: Codable, Hashable
}
struct ActivityContent<State> {
    var state: State
    var staleDate: Date?
}
enum ActivityUIDismissalPolicy { case immediate }
let AVAudioSessionInterruptionTypeKey = "SyntheticInterruptionType"
let AVFormatIDKey = "Format"
let AVSampleRateKey = "SampleRate"
let AVNumberOfChannelsKey = "Channels"
let AVEncoderAudioQualityKey = "Quality"
let AVEncoderBitRateKey = "BitRate"
let kAudioFormatMPEG4AAC: UInt32 = 0
enum AVAudioQuality: Int { case medium = 64 }
''')
(output / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DictationLifecycleQA", platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "LifecycleTests")])
''')
environment = os.environ.copy()
for variable, directory in [("TMPDIR", "tmp"), ("CLANG_MODULE_CACHE_PATH", "module-cache"),
                            ("SWIFT_MODULE_CACHE_PATH", "module-cache")]:
    location = output / directory
    location.mkdir(exist_ok=True)
    environment[variable] = str(location)
command = ["xcrun", "swift", "test", "--package-path", str(output),
           "--scratch-path", str(output / "build"), "--cache-path", str(output / "cache"),
           "--config-path", str(output / "config"), "--security-path", str(output / "security"),
           "--disable-sandbox", "--jobs", "2"]
raise SystemExit(subprocess.run(command, env=environment).returncode)
