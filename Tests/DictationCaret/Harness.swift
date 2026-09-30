import SwiftUI

// Only unrelated attachment services are stubbed. The editor/layout are production sources.
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
    @Published var alternateTint = false
    static let transcript = (1...24).map {
        "Step \($0): Arrange paper stars on the table, then label each one with a different color."
    }.joined(separator: " ") + " FINAL SENTENCE: The display is ready. 🌟"
}

struct ReproComposer: View {
    @ObservedObject var state: FixtureState
    var body: some View {
        VStack {
            Button("Insert synthetic transcript") {
                state.text = String(repeating: "kite ", count: 65).trimmingCharacters(in: .whitespaces)
            }
            Spacer()
            if state.processing {
                ProgressView("Transcribing synthetic audio")
            } else {
                ComposerLayout(compact: state.text.isEmpty, direction: .leftToRight) {
                    PasteableTextView(text: $state.text, placeholder: "Message", font: .systemFont(ofSize: 16),
                                      textColor: .label, placeholderColor: .secondaryLabel,
                                      tintColor: state.alternateTint ? .systemGreen : .systemBlue,
                                      isEnabled: true, sendOnReturn: false)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "plus").frame(width: 26, height: 26)
                    HStack { Image(systemName: "mic"); Image(systemName: "arrow.up") }
                        .frame(width: 60, height: 26)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .frame(width: state.width)
        .padding(.bottom, 24)
    }
}

@main struct DictationCaretQAApp: App {
    @StateObject var state = FixtureState()
    var body: some Scene {
        WindowGroup { ReproComposer(state: state) }
    }
}
