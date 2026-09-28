import Foundation

/// Uses the real recovery store with a fixed synthetic identity, never a real recording.
@main struct Seed {
    @MainActor static func main() throws {
        precondition(CommandLine.arguments.count == 3, "Usage: Seed recovery-directory synthetic-silence.m4a")
        let context = DictationContext(server: "http://127.0.0.1:18191", account: "fixture-user", conversation: "synthetic-caret")
        let store = DictationRecoveryStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        try store.discard(context)
        try store.save(.init(draft: "", recording: nil), for: context)
        var recording = try store.begin(context, draft: "", engine: "server")
        try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])).write(to: store.audioURL(recording))
        recording.duration = 1
        recording.completed = true
        try store.update(recording, for: context)
    }
}
