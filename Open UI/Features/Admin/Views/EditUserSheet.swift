import SwiftUI

/// Sheet for editing a user's role, name, email, and password.
/// Matches the OpenWebUI web admin "Edit User" modal.
struct EditUserSheet: View {
    @Bindable var viewModel: AdminViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.sectionGap) {
                    // User header
                    if let user = viewModel.editingUser {
                        userHeader(user)
                    }

                    // Role picker
                    SettingsSection(header: "Role") {
                        rolePicker
                    }

                    // User info fields
                    SettingsSection(header: "User Info") {
                        VStack(spacing: 0) {
                            fieldRow(label: "Name") {
                                TextField("Name", text: $viewModel.editName)
                                    .font(AppTypography.bodyMediumFont)
                                    .textContentType(.name)
                            }

                            Divider().padding(.leading, Spacing.md)

                            fieldRow(label: "Email") {
                                TextField("Email", text: $viewModel.editEmail)
                                    .font(AppTypography.bodyMediumFont)
                                    .textContentType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                            }
                        }
                    }

                    // OAuth info (read-only)
                    if let user = viewModel.editingUser,
                       let provider = user.oauthProviderName,
                       let providerId = user.oauthProviderId {
                        SettingsSection(header: "OAuth") {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("OAuth ID")
                                        .font(AppTypography.captionFont)
                                        .foregroundStyle(theme.textTertiary)
                                    Text("\(provider) \(providerId)")
                                        .font(AppTypography.bodyMediumFont)
                                        .foregroundStyle(theme.textPrimary)
                                }
                                Spacer()
                            }
                            .padding(Spacing.md)
                        }
                    }

                    // New password
                    SettingsSection(header: "Security") {
                        fieldRow(label: "New Password") {
                            HStack {
                                if showPassword {
                                    TextField("Enter New Password", text: $viewModel.editPassword)
                                        .font(AppTypography.bodyMediumFont)
                                        .textContentType(.newPassword)
                                } else {
                                    SecureField("Enter New Password", text: $viewModel.editPassword)
                                        .font(AppTypography.bodyMediumFont)
                                        .textContentType(.newPassword)
                                }

                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .font(.system(size: 15))
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                    }

                    // Error / Success messages
                    if let error = viewModel.saveError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.error)
                            Text(error)
                                .font(AppTypography.captionFont)
                                .foregroundStyle(theme.error)
                        }
                        .padding(.horizontal, Spacing.screenPadding)
                    }

                    if viewModel.saveSuccess {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text("Changes saved successfully!")
                                .font(AppTypography.captionFont)
                                .foregroundStyle(Color.green)
                        }
                        .padding(.horizontal, Spacing.screenPadding)
                    }

                    // Save button
                    Button {
                        Task {
                            await viewModel.saveUser()
                            if viewModel.saveSuccess {
                                try? await Task.sleep(nanoseconds: 800_000_000)
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if viewModel.isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(theme.brandPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
                    }
                    .disabled(viewModel.isSaving)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.sm)
                }
                .padding(.vertical, Spacing.lg)
            }
            .background(theme.background)
            .navigationTitle("Edit User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(theme.surfaceContainer)
                            .clipShape(Circle())
                    }
                }
            }
        }
    }

    // MARK: - User Header

    private func userHeader(_ user: AdminUser) -> some View {
        HStack(spacing: Spacing.md) {
            UserAvatar(
                size: 64,
                imageURL: avatarURL(for: user),
                name: user.displayName
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName)
                    .font(AppTypography.headlineSmallFont)
                    .foregroundStyle(theme.textPrimary)

                Text("Created at \(user.createdDateString)")
                    .font(AppTypography.captionFont)
                    .foregroundStyle(theme.textTertiary)

                HStack(spacing: Spacing.xs) {
                    RoleBadge(role: user.role)

                    if user.isCurrentlyActive {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Active now")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.green)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Role Picker

    private var rolePicker: some View {
        VStack(spacing: 0) {
            ForEach([User.UserRole.user, .admin, .pending], id: \.rawValue) { role in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.editRole = role
                    }
                    Haptics.play(.light)
                } label: {
                    HStack {
                        RoleBadge(role: role)

                        Text(roleDescription(role))
                            .font(AppTypography.captionFont)
                            .foregroundStyle(theme.textTertiary)

                        Spacer()

                        Image(systemName: viewModel.editRole == role ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(
                                viewModel.editRole == role ? theme.brandPrimary : theme.textTertiary.opacity(0.4)
                            )
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if role != .pending {
                    Divider().padding(.leading, Spacing.md)
                }
            }
        }
    }

    // MARK: - Helpers

    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppTypography.captionFont)
                .foregroundStyle(theme.textTertiary)
            content()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func roleDescription(_ role: User.UserRole) -> String {
        switch role {
        case .user: return "Standard access"
        case .admin: return "Full access"
        case .pending: return "Awaiting approval"
        }
    }

    private func avatarURL(for user: AdminUser) -> URL? {
        guard let urlString = user.profileImageURL, !urlString.isEmpty else { return nil }
        if urlString.hasPrefix("http") {
            return URL(string: urlString)
        }
        if urlString == "/user.png" { return nil }
        let serverURL = dependencies.apiClient?.baseURL ?? ""
        return URL(string: "\(serverURL)/api/v1/users/\(user.id)/profile/image")
    }
}
