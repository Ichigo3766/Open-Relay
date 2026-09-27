import Foundation

struct Player { var isVisible = false }
struct SpeechService { var readAloudPlayer = Player() }
struct Dependencies { var textToSpeechService = SpeechService() }

@main
enum VisibilityTests {
    static func main() {
        for visible in [false, true] {
            for speaking in [false, true] {
                for generating in [false, true] {
                    let state = HeaderState(
                        dependencies: Dependencies(textToSpeechService: SpeechService(
                            readAloudPlayer: Player(isVisible: visible))),
                        speakingMessageId: speaking ? "synthetic-message" : nil,
                        ttsGeneratingMessageId: generating ? "synthetic-message" : nil)
                    precondition(state.showsReadAloudPlayer == (visible || speaking || generating))
                }
            }
        }
        // Paused, finished and failed server sessions remain visible until closed.
        var state = HeaderState()
        state.dependencies.textToSpeechService.readAloudPlayer.isVisible = true
        precondition(state.showsReadAloudPlayer)
        state.dependencies.textToSpeechService.readAloudPlayer.isVisible = false
        precondition(!state.showsReadAloudPlayer)
        print("10 audio-header visibility checks passed")
    }
}
