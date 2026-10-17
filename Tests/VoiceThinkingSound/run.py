#!/usr/bin/env python3
"""Focused native AVFoundation checks; no microphone, server, or stored chats.

Usage: python3 Tests/VoiceThinkingSound/run.py --output-dir /external/path
The state fixture compiles the production state observers and sound gate verbatim.
The audio fixture compiles the complete production CallThinkingSound file.
"""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Open UI/Features/VoiceCall"


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    vm = (BASE / "ViewModels/VoiceCallViewModel.swift").read_text()
    settings = (BASE / "Engine/VoiceCallSettings.swift").read_text()
    helpers = (BASE / "Engine/VoiceCallSettings+Advanced.swift").read_text()
    fields = ["enum CallState:", "private(set) var callState:", "private(set) var isPaused =",
              "var wasPausedByInterruption =", "func updateThinkingSound()"]
    fixture = "import Foundation\nimport AVFoundation\n"
    fixture += "@MainActor final class Settings {\nlet defaults: UserDefaults\nvar revision = 0\n"
    fixture += 'init() { defaults = UserDefaults(suiteName: "org.example.voice-thinking-checks")! }\n'
    fixture += declaration(settings, "var thinkingSoundEnabled:") + "\n"
    fixture += declaration(helpers, "func bool(") + "\n"
    fixture += declaration(helpers, "func set(") + "\n}\n"
    fixture += "@MainActor final class Session { let audioEngine = Engine() }\n"
    fixture += "@MainActor final class Engine { let thinkingSound = CallThinkingSound() }\n"
    fixture += "@MainActor final class StateFixture {\nlet settings = Settings()\nvar orchestrator: Session?\nvar realtimeCall: Session?\n"
    fixture += "\n".join(declaration(vm, f) for f in fields) + "\n"
    fixture += "func transition(_ state: CallState) { callState = state }\n"
    fixture += "func pause(_ value: Bool) { isPaused = value }\n}\n"
    realtime = (BASE / "Engine/RealtimeCallSession.swift").read_text()
    callbacks = realtime[realtime.index("        player.onStarted ="):realtime.index("        audioEngine.onRebuilt =")]
    created = realtime.split('        case "response.created":\n', 1)[1].split('        case "response.output_audio.delta":', 1)[0]
    fixture += """
@MainActor final class CallbackPlayer {
    var onStarted: (() -> Void)?
    var onFinished: (() -> Void)?
    var isSpeaking = false
    func stopImmediately() { isSpeaking = false }
    func beginSession() { stopImmediately() }
}
@MainActor final class NodeEngine {
    let playerNode = AVAudioPlayerNode()
    let engine = AVAudioEngine()
    init() { engine.attach(playerNode) }
}
@MainActor final class RealtimeStateFixture {
    let player = CallbackPlayer()
    let audioEngine = NodeEngine()
    var stopped = false
    var paused = false
    var responseID: String?
    var playback: RealtimePlaybackPosition?
    var interrupted: Set<String> = []
    var finished: Set<String> = []
    var pendingResults: [String: String] = [:]
    var replyTask: Task<Void, Never>?
    var states: [StateFixture.CallState] = []
    var events: [String] = []
    var onState: ((StateFixture.CallState) -> Void)?
    init() {
        onState = { [weak self] state in self?.states.append(state); self?.events.append("state") }
""" + callbacks + """
    }
    func created(_ event: [String: Any]) {
""" + created + """
    }
    func send(_ event: [String: Any]) async throws {
        events.append("send")
        try await Task.sleep(for: .milliseconds(50))
    }
    func fail(_ message: String) { states.append(.error(message)) }
"""
    fixture += declaration(realtime, "func interrupt() async") + "\n"
    fixture += declaration(realtime, "private func respondToResult(").replace("private func", "func", 1) + "\n}\n"
    generated = out / "StateFixture.swift"
    generated.write_text(fixture)
    binary = out / "voice-thinking-checks"
    env = dict(os.environ, TMPDIR=str(out))
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "ModuleCache"),
                    str(BASE / "Engine/Audio/CallThinkingSound.swift"), str(BASE / "Engine/RealtimeCallWire.swift"), str(generated),
                    str(Path(__file__).with_name("Checks.swift")), "-o", str(binary)], check=True, env=env)
    subprocess.run([str(binary), str(out)], check=True, env=env)


if __name__ == "__main__":
    main()
