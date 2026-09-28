import SwiftUI

@main struct SpeechTestHost: App {
    var body: some Scene { WindowGroup { Text("Synthetic speech playback checks") } }
}

// Voice calls are outside this isolated read-aloud fixture.
enum CallAudioSession { static var isCallActive: Bool { false } }
