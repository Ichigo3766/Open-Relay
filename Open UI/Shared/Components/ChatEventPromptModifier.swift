import SwiftUI

struct ChatEventPromptModifier: ViewModifier {
    let prompts: ChatEventPrompts

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { !prompts.requests.isEmpty },
                set: { if !$0 { prompts.cancelAll() } }
            )) {
                if let request = prompts.requests.first {
                    ChatEventPromptSheet(request: request) { value in
                        prompts.respond(id: request.id, value: value)
                    }
                    .id(request.id)
                    .interactiveDismissDisabled()
                }
            }
            .overlay(alignment: .top) {
                if let notice = prompts.notice {
                    Text(notice.message)
                        .font(.callout)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                        .padding(.top, 60)
                        .allowsHitTesting(false)
                        .task(id: notice.id) {
                            try? await Task.sleep(for: .seconds(5))
                            if !Task.isCancelled, prompts.notice?.id == notice.id { prompts.notice = nil }
                        }
                }
            }
    }
}

private struct ChatEventPromptSheet: View {
    let request: ChatEventPrompts.Request
    let respond: (Any) -> Void
    @State private var text: String

    init(request: ChatEventPrompts.Request, respond: @escaping (Any) -> Void) {
        self.request = request
        self.respond = respond
        _text = State(initialValue: request.value)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !request.message.isEmpty { Text(request.message) }
                if request.isInput {
                    if request.inputType == "password" {
                        SecureField(request.placeholder, text: $text)
                    } else if request.inputType == "select", !request.options.isEmpty {
                        Picker(request.placeholder, selection: $text) {
                            Text("Select an option").tag("")
                            ForEach(Array(request.options.enumerated()), id: \.offset) { _, option in
                                Text(option.label).tag(option.value)
                            }
                        }
                    } else {
                        TextField(request.placeholder, text: $text, axis: .vertical)
                            .lineLimit(3...8)
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { respond(false) }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm", systemImage: "checkmark") { respond(request.isInput ? text as Any : true) }
                        .labelStyle(.iconOnly)
                        .disabled(request.isInput && text.isEmpty)
                }
            }
        }
    }
}
