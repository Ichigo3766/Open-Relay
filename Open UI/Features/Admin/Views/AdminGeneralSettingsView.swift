import SwiftUI

// MARK: - Admin Section Enum

private enum AdminSection: String, CaseIterable {
    case auth     = "auth"
    case features = "features"
    case webhook  = "webhook"
    case ldap     = "ldap"
    case banners  = "banners"
}

// MARK: - Admin General Settings View

/// The admin "General" tab — Authentication, Features, Webhook, LDAP, and Banners.
struct AdminGeneralSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminGeneralSettingsViewModel()
    @State private var visibleSection: AdminSection = .auth

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // MARK: Authentication Section
                    authSection
                        .id(AdminSection.auth)
                        .onAppear { visibleSection = .auth }

                    // MARK: Features Section
                    featuresSection
                        .id(AdminSection.features)
                        .onAppear { visibleSection = .features }

                    // MARK: Webhook Section
                    webhookSection
                        .id(AdminSection.webhook)
                        .onAppear { visibleSection = .webhook }

                    // MARK: LDAP Section
                    ldapSection
                        .id(AdminSection.ldap)
                        .onAppear { visibleSection = .ldap }

                    // MARK: Banners Section
                    bannersSection
                        .id(AdminSection.banners)
                        .onAppear { visibleSection = .banners }

                    Spacer(minLength: 100)
                }
                .padding(.top, Spacing.md)
            }
            .background(theme.background)

            // MARK: Floating Save Button
            floatingSaveButton
        }
        .task {
            viewModel.configure(
                apiClient: dependencies.apiClient,
                defaultAdminEmail: dependencies.authViewModel.currentUser?.email ?? "",
                defaultServerURL: dependencies.serverConfigStore.activeServer?.url ?? ""
            )
            await viewModel.loadAll()
        }
        .sheet(isPresented: $viewModel.showBannerEditor) {
            BannerEditorSheet(viewModel: viewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    // MARK: - Floating Save Button

    private var floatingSaveButton: some View {
        let isSaving = currentSectionIsSaving
        let isSuccess = currentSectionIsSuccess
        let error = currentSectionError

        return VStack(alignment: .trailing, spacing: Spacing.xs) {
            // Error pill above the button
            if let error {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .scaledFont(size: 11)
                    Text(error)
                        .scaledFont(size: 12)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 6)
                .background(theme.error)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button(action: performSave) {
                HStack(spacing: Spacing.xs) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else if isSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 14)
                        Text("Saved")
                            .scaledFont(size: 14, weight: .semibold)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Save")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    isSuccess
                        ? Color.green
                        : theme.brandPrimary
                )
                .clipShape(Capsule())
                .shadow(color: (isSuccess ? Color.green : theme.brandPrimary).opacity(0.4), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .animation(.easeInOut(duration: 0.2), value: isSuccess)
            .animation(.easeInOut(duration: 0.2), value: isSaving)
        }
        .padding(.trailing, Spacing.screenPadding)
        .padding(.bottom, Spacing.lg)
        .animation(.easeInOut(duration: 0.25), value: error)
    }

    private var currentSectionIsSaving: Bool {
        switch visibleSection {
        case .auth, .features: return viewModel.isSavingAuthConfig
        case .webhook:         return viewModel.isSavingWebhook
        case .ldap:            return viewModel.isSavingLdap
        case .banners:         return viewModel.isSavingBanners
        }
    }

    private var currentSectionIsSuccess: Bool {
        switch visibleSection {
        case .auth, .features: return viewModel.authConfigSuccess
        case .webhook:         return viewModel.webhookSuccess
        case .ldap:            return viewModel.ldapSuccess
        case .banners:         return viewModel.bannersSuccess
        }
    }

    private var currentSectionError: String? {
        switch visibleSection {
        case .auth, .features: return viewModel.authConfigError
        case .webhook:         return viewModel.webhookError
        case .ldap:            return viewModel.ldapError
        case .banners:         return viewModel.bannersError
        }
    }

    private func performSave() {
        Task {
            switch visibleSection {
            case .auth, .features: await viewModel.saveAuthConfig()
            case .webhook:         await viewModel.saveWebhook()
            case .ldap:            await viewModel.saveLdapConfig()
            case .banners:         await viewModel.saveBanners()
            }
        }
        Haptics.play(.light)
    }

    // MARK: - Auth Section

    private var authSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(
                icon: "lock.shield",
                title: "Authentication"
            )

            if viewModel.isLoadingAuthConfig {
                sectionLoadingView()
            } else {
                SettingsSection {
                    // Show Admin Details
                    inlineToggleRow(
                        title: "Show Admin Details",
                        subtitle: "Display admin contact info on the login page.",
                        isOn: Binding(
                            get: { viewModel.authConfig.showAdminDetails },
                            set: { viewModel.authConfig.showAdminDetails = $0 }
                        )
                    )

                    if viewModel.authConfig.showAdminDetails {
                        Divider().padding(.leading, Spacing.md)

                        // Admin Email
                        inlineTextFieldRow(
                            title: "Admin Contact Email",
                            placeholder: "admin@example.com",
                            text: Binding(
                                get: { viewModel.authConfig.adminEmail },
                                set: { viewModel.authConfig.adminEmail = $0 }
                            ),
                            keyboardType: .emailAddress
                        )

                        Divider().padding(.leading, Spacing.md)

                        // WebUI URL
                        inlineTextFieldRow(
                            title: "WebUI URL",
                            placeholder: "https://your-server.com",
                            text: Binding(
                                get: { viewModel.authConfig.webuiURL },
                                set: { viewModel.authConfig.webuiURL = $0 }
                            ),
                            keyboardType: .URL
                        )
                    }

                    Divider().padding(.leading, Spacing.md)

                    // Enable Signup
                    inlineToggleRow(
                        title: "Enable New Sign Ups",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableSignup },
                            set: { viewModel.authConfig.enableSignup = $0 }
                        )
                    )
                }

                // API Keys
                SettingsSection(header: "API Keys") {
                    inlineToggleRow(
                        title: "Enable API Keys",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableAPIKeys },
                            set: { viewModel.authConfig.enableAPIKeys = $0 }
                        )
                    )

                    if viewModel.authConfig.enableAPIKeys {
                        Divider().padding(.leading, Spacing.md)

                        inlineToggleRow(
                            title: "Endpoint Restrictions",
                            subtitle: "Restrict which endpoints API keys can access.",
                            isOn: Binding(
                                get: { viewModel.authConfig.enableAPIKeysEndpointRestrictions },
                                set: { viewModel.authConfig.enableAPIKeysEndpointRestrictions = $0 }
                            )
                        )

                        if viewModel.authConfig.enableAPIKeysEndpointRestrictions {
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(
                                title: "Allowed Endpoints",
                                placeholder: "/api/v1/messages,/api/v1/chat",
                                text: Binding(
                                    get: { viewModel.authConfig.apiKeysAllowedEndpoints },
                                    set: { viewModel.authConfig.apiKeysAllowedEndpoints = $0 }
                                )
                            )
                        }
                    }
                }

                // User Defaults
                SettingsSection(header: "User Defaults") {
                    // Default User Role
                    inlinePickerRow(
                        title: "Default User Role",
                        selection: Binding(
                            get: { viewModel.authConfig.defaultUserRole },
                            set: { viewModel.authConfig.defaultUserRole = $0 }
                        ),
                        options: [
                            ("pending", "Pending"),
                            ("user", "User"),
                            ("admin", "Admin")
                        ]
                    )

                    Divider().padding(.leading, Spacing.md)

                    // Default Group
                    inlinePickerRow(
                        title: "Default Group",
                        selection: Binding(
                            get: { viewModel.authConfig.defaultGroupID },
                            set: { viewModel.authConfig.defaultGroupID = $0 }
                        ),
                        options: [("", "None")] + viewModel.groups.map { ($0.id, $0.name) }
                    )
                }

                // JWT
                SettingsSection(
                    header: "JWT",
                    footer: "Valid time units: 's', 'm', 'h', 'd', 'w' or '-1' for no expiration."
                ) {
                    inlineTextFieldRow(
                        title: "Token Expiration",
                        placeholder: "-1",
                        text: Binding(
                            get: { viewModel.authConfig.jwtExpiresIn },
                            set: { viewModel.authConfig.jwtExpiresIn = $0 }
                        )
                    )
                }

                // Pending User Overlay
                SettingsSection(header: "Pending User Overlay") {
                    inlineTextFieldRow(
                        title: "Title",
                        placeholder: "Leave empty for default",
                        text: Binding(
                            get: { viewModel.authConfig.pendingUserOverlayTitle },
                            set: { viewModel.authConfig.pendingUserOverlayTitle = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextAreaRow(
                        title: "Content",
                        placeholder: "Leave empty for default",
                        text: Binding(
                            get: { viewModel.authConfig.pendingUserOverlayContent },
                            set: { viewModel.authConfig.pendingUserOverlayContent = $0 }
                        )
                    )
                }

                // Response Watermark
                SettingsSection(
                    header: "Response Watermark",
                    footer: "Appended to every AI response. Leave empty to disable."
                ) {
                    inlineTextAreaRow(
                        title: "Watermark Text",
                        placeholder: "No watermark",
                        text: Binding(
                            get: { viewModel.authConfig.responseWatermark },
                            set: { viewModel.authConfig.responseWatermark = $0 }
                        )
                    )
                }
            }
        }
    }

    // MARK: - Features Section

    private var featuresSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(
                icon: "star.circle",
                title: "Features"
            )

            if viewModel.isLoadingAuthConfig {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(
                        title: "Community Sharing",
                        subtitle: "Allow users to share chats publicly.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableCommunitySharing },
                            set: { viewModel.authConfig.enableCommunitySharing = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Message Rating",
                        subtitle: "Allow users to rate AI messages.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableMessageRating },
                            set: { viewModel.authConfig.enableMessageRating = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Folders",
                        subtitle: "Allow users to organise chats into folders.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableFolders },
                            set: { viewModel.authConfig.enableFolders = $0 }
                        )
                    )

                    if viewModel.authConfig.enableFolders {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "Folder Max File Count",
                            placeholder: "Leave empty for unlimited",
                            text: Binding(
                                get: { viewModel.authConfig.folderMaxFileCount },
                                set: { viewModel.authConfig.folderMaxFileCount = $0 }
                            ),
                            keyboardType: .numberPad
                        )
                    }

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Channels",
                        subtitle: "Enable the Channels feature for all users.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableChannels },
                            set: { viewModel.authConfig.enableChannels = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Calendar",
                        subtitle: "Enable the Calendar feature for all users.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableCalendar },
                            set: { viewModel.authConfig.enableCalendar = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Automations",
                        subtitle: "Enable the Automations feature for all users.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableAutomations },
                            set: { viewModel.authConfig.enableAutomations = $0 }
                        )
                    )

                    if viewModel.authConfig.enableAutomations {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "Max Automation Count",
                            placeholder: "Leave empty for unlimited",
                            text: Binding(
                                get: { viewModel.authConfig.automationMaxCount },
                                set: { viewModel.authConfig.automationMaxCount = $0 }
                            ),
                            keyboardType: .numberPad
                        )
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "Min Automation Interval",
                            placeholder: "Minimum interval in seconds",
                            text: Binding(
                                get: { viewModel.authConfig.automationMinInterval },
                                set: { viewModel.authConfig.automationMinInterval = $0 }
                            ),
                            keyboardType: .numberPad
                        )
                    }

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Memories",
                        subtitle: "Allow users to save memories across conversations.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableMemories },
                            set: { viewModel.authConfig.enableMemories = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Notes",
                        subtitle: "Allow users to create and manage notes.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableNotes },
                            set: { viewModel.authConfig.enableNotes = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "User Webhooks",
                        subtitle: "Allow users to configure personal webhooks.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableUserWebhooks },
                            set: { viewModel.authConfig.enableUserWebhooks = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "User Status",
                        subtitle: "Show online/away status indicators.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableUserStatus },
                            set: { viewModel.authConfig.enableUserStatus = $0 }
                        ),
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - Webhook Section

    private var webhookSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(
                icon: "arrow.triangle.2.circlepath",
                title: "Webhook"
            )

            if viewModel.isLoadingWebhook {
                sectionLoadingView()
            } else {
                SettingsSection(footer: "Receive a POST notification when a user completes a conversation.") {
                    inlineTextFieldRow(
                        title: "Webhook URL",
                        placeholder: "https://your-server.com/webhook",
                        text: $viewModel.webhookURL,
                        keyboardType: .URL,
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - LDAP Section

    private var ldapSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(
                icon: "person.badge.key",
                title: "LDAP"
            )

            if viewModel.isLoadingLdap {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(
                        title: "Enable LDAP",
                        subtitle: "Authenticate users via your LDAP/Active Directory server.",
                        isOn: Binding(
                            get: { viewModel.ldapConfig.enableLdap ?? false },
                            set: { viewModel.ldapConfig.enableLdap = $0 }
                        ),
                        showDivider: viewModel.ldapConfig.enableLdap == true
                    )

                    if viewModel.ldapConfig.enableLdap == true {
                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Label",
                            placeholder: "LDAP",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.label },
                                set: { viewModel.ldapServerConfig.label = $0 }
                            )
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Host",
                            placeholder: "ldap.example.com",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.host },
                                set: { viewModel.ldapServerConfig.host = $0 }
                            )
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Port",
                            placeholder: "389",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.port.map { String($0) } ?? "" },
                                set: { viewModel.ldapServerConfig.port = Int($0) }
                            ),
                            keyboardType: .numberPad
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Mail Attribute",
                            placeholder: "mail",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.attributeForMail },
                                set: { viewModel.ldapServerConfig.attributeForMail = $0 }
                            )
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Username Attribute",
                            placeholder: "uid",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.attributeForUsername },
                                set: { viewModel.ldapServerConfig.attributeForUsername = $0 }
                            )
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "App DN",
                            placeholder: "cn=admin,dc=example,dc=com",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.appDN },
                                set: { viewModel.ldapServerConfig.appDN = $0 }
                            )
                        )

                        Divider().padding(.leading, Spacing.md)

                        ldapPasswordRow

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Search Base",
                            placeholder: "dc=example,dc=com",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.searchBase },
                                set: { viewModel.ldapServerConfig.searchBase = $0 }
                            )
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Search Filters",
                            placeholder: "(objectClass=person)",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.searchFilters },
                                set: { viewModel.ldapServerConfig.searchFilters = $0 }
                            )
                        )

                        Divider().padding(.leading, Spacing.md)

                        inlineToggleRow(
                            title: "Use TLS",
                            isOn: Binding(
                                get: { viewModel.ldapServerConfig.useTLS },
                                set: { viewModel.ldapServerConfig.useTLS = $0 }
                            )
                        )

                        if viewModel.ldapServerConfig.useTLS {
                            Divider().padding(.leading, Spacing.md)

                            inlineTextFieldRow(
                                title: "Certificate Path",
                                placeholder: "/path/to/cert.pem",
                                text: Binding(
                                    get: { viewModel.ldapServerConfig.certificatePath ?? "" },
                                    set: { viewModel.ldapServerConfig.certificatePath = $0.isEmpty ? nil : $0 }
                                )
                            )

                            Divider().padding(.leading, Spacing.md)

                            inlineToggleRow(
                                title: "Validate Certificate",
                                isOn: Binding(
                                    get: { viewModel.ldapServerConfig.validateCert },
                                    set: { viewModel.ldapServerConfig.validateCert = $0 }
                                )
                            )

                            Divider().padding(.leading, Spacing.md)

                            inlineTextFieldRow(
                                title: "Ciphers",
                                placeholder: "ALL",
                                text: Binding(
                                    get: { viewModel.ldapServerConfig.ciphers ?? "" },
                                    set: { viewModel.ldapServerConfig.ciphers = $0.isEmpty ? nil : $0 }
                                ),
                                showDivider: false
                            )
                        }
                    }
                }
            }
        }
    }

    private var ldapPasswordRow: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("App DN Password")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                Group {
                    if viewModel.showLdapPassword {
                        TextField("password", text: Binding(
                            get: { viewModel.ldapServerConfig.appDNPassword },
                            set: { viewModel.ldapServerConfig.appDNPassword = $0 }
                        ))
                    } else {
                        SecureField("password", text: Binding(
                            get: { viewModel.ldapServerConfig.appDNPassword },
                            set: { viewModel.ldapServerConfig.appDNPassword = $0 }
                        ))
                    }
                }
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Spacer()

            Button {
                viewModel.showLdapPassword.toggle()
            } label: {
                Image(systemName: viewModel.showLdapPassword ? "eye.slash" : "eye")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    // MARK: - Banners Section

    private var bannersSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(
                icon: "bell.badge",
                title: "Banners",
                trailingAction: {
                    AnyView(
                        Button {
                            viewModel.startAddingBanner()
                            Haptics.play(.light)
                        } label: {
                            Image(systemName: "plus")
                                .scaledFont(size: 14, weight: .semibold)
                                .foregroundStyle(theme.brandPrimary)
                                .frame(width: 28, height: 28)
                                .background(theme.brandPrimary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    )
                }
            )

            if viewModel.isLoadingBanners {
                sectionLoadingView()
            } else if viewModel.banners.isEmpty {
                SettingsSection(footer: "Banners are displayed at the top of the chat for all users.") {
                    HStack {
                        Spacer()
                        VStack(spacing: Spacing.sm) {
                            Image(systemName: "bell.slash")
                                .scaledFont(size: 28)
                                .foregroundStyle(theme.textTertiary)
                            Text("No banners configured")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.vertical, Spacing.lg)
                        Spacer()
                    }
                }
            } else {
                SettingsSection(footer: "Banners are displayed at the top of the chat for all users.") {
                    ForEach(Array(viewModel.banners.enumerated()), id: \.element.id) { index, banner in
                        BannerRow(
                            banner: banner,
                            showDivider: index < viewModel.banners.count - 1,
                            onEdit: { viewModel.startEditingBanner(banner) },
                            onDelete: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.deleteBanner(id: banner.id)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Shared Row Builders

    private func sectionHeader(
        icon: String,
        title: String,
        trailingAction: (() -> AnyView)? = nil
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)

            Text(title.uppercased())
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .tracking(0.8)

            Spacer()

            if let trailingAction {
                trailingAction()
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func sectionLoadingView() -> some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
                .padding(.vertical, Spacing.lg)
            Spacer()
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func inlineToggleRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlineTextFieldRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                TextField(placeholder, text: text)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlineTextAreaRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                TextField(placeholder, text: text, axis: .vertical)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlinePickerRow(
        title: String,
        selection: Binding<String>,
        options: [(value: String, label: String)]
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Text(title)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)

            Spacer()

            Picker("", selection: selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .tint(theme.brandPrimary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }
}

// MARK: - Banner Row

private struct BannerRow: View {
    let banner: AdminBannerItem
    let showDivider: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                // Type indicator dot
                Circle()
                    .fill(bannerColor)
                    .frame(width: 8, height: 8)
                    .padding(.leading, Spacing.xs)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        Text(bannerTypeLabel)
                            .scaledFont(size: 11, weight: .heavy)
                            .foregroundStyle(bannerColor)
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(bannerColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        if banner.dismissible {
                            Text("Dismissible")
                                .scaledFont(size: 10, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }

                    if let title = banner.title, !title.isEmpty {
                        Text(title)
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                    }

                    Text(banner.content)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 2) {
                    bannerActionButton(icon: "pencil", action: onEdit)
                    bannerActionButton(icon: "trash", color: theme.error, action: onDelete)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private var bannerColor: Color {
        switch banner.type {
        case "info":    return .blue
        case "warning": return .orange
        case "error":   return .red
        case "success": return .green
        default:        return .blue
        }
    }

    private var bannerTypeLabel: String {
        banner.type.capitalized
    }

    private func bannerActionButton(icon: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(color ?? theme.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Banner Editor Sheet

struct BannerEditorSheet: View {
    @Bindable var viewModel: AdminGeneralSettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private let bannerTypes = ["info", "warning", "error", "success"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Banner Type", selection: $viewModel.bannerEditorType) {
                        ForEach(bannerTypes, id: \.self) { type in
                            HStack {
                                Circle()
                                    .fill(bannerTypeColor(type))
                                    .frame(width: 8, height: 8)
                                Text(type.capitalized)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Content") {
                    TextField("Title (optional)", text: $viewModel.bannerEditorTitle)
                        .textInputAutocapitalization(.sentences)

                    TextField("Message", text: $viewModel.bannerEditorContent, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    Toggle("Dismissible", isOn: $viewModel.bannerEditorDismissible)
                        .tint(theme.brandPrimary)
                }
            }
            .navigationTitle(viewModel.editingBanner == nil ? "Add Banner" : "Edit Banner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showBannerEditor = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.commitBannerEdit()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(viewModel.bannerEditorContent.isEmpty)
                }
            }
        }
    }

    private func bannerTypeColor(_ type: String) -> Color {
        switch type {
        case "info":    return .blue
        case "warning": return .orange
        case "error":   return .red
        case "success": return .green
        default:        return .blue
        }
    }
}
