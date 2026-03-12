import SwiftUI

/// Sheet presented when creating a new folder or renaming an existing one.
///
/// - For **create**: pass `existingName: nil` and the `onCreate` callback.
/// - For **rename**: pass the current `existingName` and the `onRename` callback.
struct CreateFolderSheet: View {
    // MARK: - Configuration

    let existingName: String?
    var onCreate: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    // MARK: - State

    @State private var folderName: String
    @FocusState private var isFocused: Bool

    // MARK: - Init

    init(
        existingName: String? = nil,
        onCreate: ((String) -> Void)? = nil,
        onRename: ((String) -> Void)? = nil
    ) {
        self.existingName = existingName
        self.onCreate = onCreate
        self.onRename = onRename
        _folderName = State(initialValue: existingName ?? "")
    }

    // MARK: - Computed

    private var isRenaming: Bool { existingName != nil }

    private var title: String {
        isRenaming
            ? String(localized: "Rename Folder")
            : String(localized: "New Folder")
    }

    private var actionLabel: String {
        isRenaming
            ? String(localized: "Rename")
            : String(localized: "Create")
    }

    private var isActionEnabled: Bool {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isRenaming { return trimmed != existingName }
        return true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                // Folder icon preview
                HStack {
                    Spacer()
                    folderPreview
                    Spacer()
                }
                .padding(.top, Spacing.lg)

                // Name field
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Folder Name")
                        .font(AppTypography.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, Spacing.md)

                    TextField(
                        String(localized: "Enter folder name"),
                        text: $folderName
                    )
                    .focused($isFocused)
                    .font(AppTypography.bodyMediumFont)
                    .padding(Spacing.md)
                    .background(theme.inputBackground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isFocused ? theme.brandPrimary : theme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
                    .padding(.horizontal, Spacing.md)
                    .onSubmit { commitAction() }
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .animation(.easeInOut(duration: AnimDuration.fast), value: isFocused)
                }

                Spacer()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionLabel) {
                        commitAction()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isActionEnabled)
                }
            }
            .onAppear {
                // Auto-focus after a short delay for smooth sheet presentation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFocused = true
                }
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.background)
    }

    // MARK: - Folder Preview

    private var folderPreview: some View {
        ZStack {
            Image(systemName: folderName.isEmpty ? "folder" : "folder.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(theme.brandPrimary)
                .symbolEffect(.bounce, value: folderName)

            if !folderName.isEmpty {
                Text(String(folderName.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: 6)
            }
        }
        .frame(width: 80, height: 80)
        .animation(.easeInOut(duration: AnimDuration.fast), value: folderName.isEmpty)
    }

    // MARK: - Actions

    private func commitAction() {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        if isRenaming {
            onRename?(trimmed)
        } else {
            onCreate?(trimmed)
        }
    }
}

#Preview("Create") {
    CreateFolderSheet(onCreate: { _ in })
}

#Preview("Rename") {
    CreateFolderSheet(existingName: "Work", onRename: { _ in })
}
