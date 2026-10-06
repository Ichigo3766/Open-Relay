import SwiftUI

/// Toolbar button that runs the code through the server's Black formatter
/// (`/utils/code/format`, admin-only — hidden for other users, like the web).
struct FormatPythonButton: View {
    @Binding var code: String
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var formatting = false
    @State private var error: String?

    var body: some View {
        Group {
            if dependencies.authViewModel.currentUser?.role == .admin {
                if formatting {
                    ProgressView()
                } else {
                    Button("Format Code", systemImage: "text.alignleft") { Task { await format() } }
                        .labelStyle(.iconOnly)
                        .disabled(code.isEmpty)
                }
            }
        }
        .alert("Couldn't Format", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func format() async {
        guard let api = dependencies.apiClient else { return }
        formatting = true
        do {
            let formatted = try await api.formatPythonCode(code)
            if formatted != code { code = formatted }
            Haptics.notify(.success)
        } catch {
            self.error = error.localizedDescription
            Haptics.notify(.error)
        }
        formatting = false
    }
}
