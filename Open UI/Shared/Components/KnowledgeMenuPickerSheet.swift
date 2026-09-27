import SwiftUI

struct KnowledgeMenuPickerSheet: View {
    @Binding var isPresented: Bool
    @Binding var selectedItems: [KnowledgeItem]
    var apiClient: APIClient?

    var body: some View {
        NavigationStack {
            InlineKnowledgePickerView(apiClient: apiClient) { item in
                if !selectedItems.contains(where: { $0.id == item.id && $0.type == item.type }) {
                    selectedItems.append(item)
                }
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
        .themed()
    }
}
