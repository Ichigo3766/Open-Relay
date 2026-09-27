import SwiftUI

struct ServerFilesPickerSheet: View {
    @Binding var isPresented: Bool
    var apiClient: APIClient?
    var onFilesSelected: ([ChatAttachment]) -> Void

    var body: some View {
        NavigationStack {
            InlineFilesPickerView(apiClient: apiClient) { attachments in
                onFilesSelected(attachments)
                isPresented = false
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { isPresented = false }
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}
