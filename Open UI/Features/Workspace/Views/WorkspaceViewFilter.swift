import SwiftUI

/// "All / Created by you / Shared with you" — the web `ViewSelector`. The server's
/// `view_option` compares `user_id` with the caller, and so does `matches` here, for the
/// workspace lists whose items are already fully loaded (prompts, skills, tools).
enum WorkspaceViewFilter: String, CaseIterable, Identifiable {
    case all = "", created = "created", shared = "shared"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .created: return "Created by you"
        case .shared: return "Shared with you"
        }
    }

    func matches(ownerId: String, currentUserId: String?) -> Bool {
        switch self {
        case .all: return true
        case .created: return ownerId == currentUserId
        case .shared: return ownerId != currentUserId
        }
    }
}

struct WorkspaceViewFilterMenu: View {
    @Environment(\.theme) private var theme
    @Binding var selection: WorkspaceViewFilter

    var body: some View {
        Menu {
            ForEach(WorkspaceViewFilter.allCases) { option in
                Button { selection = option } label: {
                    if selection == option { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2").scaledFont(size: 12, weight: .medium)
                Text(selection.label).scaledFont(size: 13, weight: selection == .all ? .regular : .semibold)
            }
            .foregroundStyle(selection == .all ? theme.textTertiary : theme.brandPrimary)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .fill(selection == .all ? theme.surfaceContainer.opacity(0.5) : theme.brandPrimary.opacity(0.12)))
        }
    }
}
