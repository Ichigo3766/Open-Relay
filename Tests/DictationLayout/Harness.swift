import SwiftUI

// Unrelated attachment/focus dependencies; no server, account, or microphone.
struct ChatAttachment {
    enum AttachmentType { case image, file }
    let type: AttachmentType
    let name: String
    var thumbnail: Image?
    var data: Data?
}
enum FileAttachmentService {
    static func downsampleForUpload(image: UIImage) -> Data { Data() }
}
extension Notification.Name {
    static let chatInputFieldRequestFocus = Notification.Name("fixture.focus")
}

@MainActor final class FixtureState: ObservableObject {
    @Published var text = ""
    @Published var processing = false
    @Published var width: CGFloat = 360
    @Published var keyboardVisible = false
    static let transcript = (1...32).map {
        "Paragraph \($0). Fold a paper kite, paint a yellow sun, and add a blue ribbon to the tail."
    }.joined(separator: " ") + " END OF TRANSCRIPT."
}

struct ReproComposer: View {
    @ObservedObject var state: FixtureState
    var body: some View {
        VStack {
            Spacer()
            if state.processing {
                ProgressView("Transcribing synthetic audio")
            } else {
                ComposerLayout(compact: state.text.isEmpty && !state.keyboardVisible, direction: .leftToRight) {
                    PasteableTextView(text: $state.text, placeholder: "Message", font: .systemFont(ofSize: 16),
                                      textColor: .label, placeholderColor: .secondaryLabel, tintColor: .systemBlue,
                                      isEnabled: true, sendOnReturn: false)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "plus").frame(width: 26, height: 26)
                    HStack(spacing: 8) {
                        Image(systemName: "mic")
                        Image(systemName: state.text.isEmpty ? "waveform" : "arrow.up")
                    }.frame(width: 60, height: 26)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .frame(width: state.width)
        .padding(.bottom, 24)
    }
}

@main struct DictationLayoutQAApp: App {
    @StateObject var state = FixtureState()
    var body: some Scene {
        WindowGroup {
            VStack {
                Text("Synthetic dictation layout").font(.headline)
                Button("Insert transcript") { state.text = FixtureState.transcript }
                Button("Clear") { state.text = "" }
                ReproComposer(state: state)
            }
        }
    }
}
