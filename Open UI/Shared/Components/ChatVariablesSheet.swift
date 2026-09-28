import SwiftUI

struct ChatVariablesSheet: View {
    let viewModel: ChatViewModel
    let form: ChatVariableForm

    var body: some View {
        PromptVariableSheet(promptName: form.modelName, variables: form.fields,
            onSave: { try await viewModel.saveChatVariables($0, form: form) },
            onCancel: {}, title: "Chat Variables")
    }
}
