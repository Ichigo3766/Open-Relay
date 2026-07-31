import SwiftUI

// MARK: - Admin Authentication Section Enum

private enum AuthSection: String, CaseIterable {
    case userAccess    = "userAccess"
    case pending       = "pending"
    case ldap          = "ldap"
    case oauth         = "oauth"
}

// MARK: - Admin Authentication View

/// The admin "Authentication" tab — User Access, Pending Accounts, LDAP, and OAuth/OIDC.
/// Matches the web UI's Authentication settings page.
struct AdminAuthenticationView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminAuthenticationViewModel()
    @State private var visibleSection: AuthSection = .userAccess

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    Color.clear.frame(height: 0)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                                    .fontWeight(.semibold)
                            }
                        }
                    // User Access
                    userAccessSection
                        .id(AuthSection.userAccess)
                        .onAppear { visibleSection = .userAccess }

                    // Pending Accounts
                    pendingAccountsSection
                        .id(AuthSection.pending)
                        .onAppear { visibleSection = .pending }

                    // LDAP
                    ldapSection
                        .id(AuthSection.ldap)
                        .onAppear { visibleSection = .ldap }

                    // OAuth / OIDC
                    if viewModel.oauthAvailable {
                        oauthSection
                            .id(AuthSection.oauth)
                            .onAppear { visibleSection = .oauth }
                    }

                    Spacer(minLength: 100)
                }
                .padding(.top, Spacing.md)
            }
            .background(theme.background)

            floatingSaveButton
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.loadAll()
        }
    }

    // MARK: - Floating Save Button

    private var floatingSaveButton: some View {
        let isSaving = currentSectionIsSaving
        let isSuccess = currentSectionIsSuccess
        let error = currentSectionError

        return VStack(alignment: .trailing, spacing: Spacing.xs) {
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
                        ProgressView().controlSize(.small).tint(.white)
                    } else if isSuccess {
                        Image(systemName: "checkmark.circle.fill").scaledFont(size: 14)
                        Text("Saved").scaledFont(size: 14, weight: .semibold)
                    } else {
                        Image(systemName: "square.and.arrow.down").scaledFont(size: 14, weight: .semibold)
                        Text("Save").scaledFont(size: 14, weight: .semibold)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(isSuccess ? Color.green : theme.brandPrimary)
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
        case .userAccess, .pending: return viewModel.isSavingAuthConfig
        case .ldap:                 return viewModel.isSavingLdap
        case .oauth:                return viewModel.isSavingOAuth
        }
    }

    private var currentSectionIsSuccess: Bool {
        switch visibleSection {
        case .userAccess, .pending: return viewModel.authConfigSuccess
        case .ldap:                 return viewModel.ldapSuccess
        case .oauth:                return viewModel.oauthSuccess
        }
    }

    private var currentSectionError: String? {
        switch visibleSection {
        case .userAccess, .pending: return viewModel.authConfigError
        case .ldap:                 return viewModel.ldapError
        case .oauth:                return viewModel.oauthError
        }
    }

    private func performSave() {
        Task {
            switch visibleSection {
            case .userAccess, .pending: await viewModel.saveAuthConfig()
            case .ldap:                 await viewModel.saveLdapConfig()
            case .oauth:                await viewModel.saveOAuthConfig()
            }
        }
        Haptics.play(.light)
    }

    // MARK: - User Access Section

    private var userAccessSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "person.badge.key", title: "User Access")

            if viewModel.isLoadingAuthConfig {
                sectionLoadingView()
            } else {
                // Default User Role + Default Group
                SettingsSection(header: "Defaults") {
                    inlinePickerRow(
                        title: "Default User Role",
                        selection: Binding(
                            get: { viewModel.authConfig.defaultUserRole },
                            set: { viewModel.authConfig.defaultUserRole = $0 }
                        ),
                        options: [("pending", "Pending"), ("user", "User"), ("admin", "Admin")]
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlinePickerRow(
                        title: "Default Group",
                        selection: Binding(
                            get: { viewModel.authConfig.defaultGroupID },
                            set: { viewModel.authConfig.defaultGroupID = $0 }
                        ),
                        options: [("", "None")] + viewModel.groups.map { ($0.id, $0.name) }
                    )
                }

                // Sign-ups and API Keys
                SettingsSection {
                    inlineToggleRow(
                        title: "New Sign Ups",
                        subtitle: "Allow new users to create accounts.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableSignup },
                            set: { viewModel.authConfig.enableSignup = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "API Keys",
                        subtitle: "Allow users to create API keys for programmatic access.",
                        isOn: Binding(
                            get: { viewModel.authConfig.enableAPIKeys },
                            set: { viewModel.authConfig.enableAPIKeys = $0 }
                        )
                    )

                    if viewModel.authConfig.enableAPIKeys {
                        Divider().padding(.leading, Spacing.md)

                        inlineToggleRow(
                            title: "API Key Endpoint Restrictions",
                            subtitle: "Limit API keys to configured endpoints.",
                            isOn: Binding(
                                get: { viewModel.authConfig.enableAPIKeysEndpointRestrictions },
                                set: { viewModel.authConfig.enableAPIKeysEndpointRestrictions = $0 }
                            )
                        )

                        if viewModel.authConfig.enableAPIKeysEndpointRestrictions {
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(
                                title: "Allowed Endpoints",
                                placeholder: "/api/v1/messages, /api/v1/channels",
                                text: Binding(
                                    get: { viewModel.authConfig.apiKeysAllowedEndpoints },
                                    set: { viewModel.authConfig.apiKeysAllowedEndpoints = $0 }
                                )
                            )
                        }
                    }
                }

                // JWT Expiration
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
                        ),
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - Pending Accounts Section

    private var pendingAccountsSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "clock.badge.questionmark", title: "Pending Accounts")

            if viewModel.isLoadingAuthConfig {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(
                        title: "Admin Details",
                        subtitle: "Show admin contact details while an account waits for approval.",
                        isOn: Binding(
                            get: { viewModel.authConfig.showAdminDetails },
                            set: { viewModel.authConfig.showAdminDetails = $0 }
                        )
                    )

                    if viewModel.authConfig.showAdminDetails {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "Admin Contact Email",
                            placeholder: "Leave empty to use first admin user",
                            text: Binding(
                                get: { viewModel.authConfig.adminEmail },
                                set: { viewModel.authConfig.adminEmail = $0 }
                            ),
                            keyboardType: .emailAddress
                        )
                    }
                }

                SettingsSection {
                    inlineTextAreaRow(
                        title: "Pending User Overlay Title",
                        placeholder: "Enter a title for the pending user overlay. Leave empty for default.",
                        text: Binding(
                            get: { viewModel.authConfig.pendingUserOverlayTitle },
                            set: { viewModel.authConfig.pendingUserOverlayTitle = $0 }
                        )
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextAreaRow(
                        title: "Pending User Overlay Content",
                        placeholder: "Enter content for the pending user overlay. Leave empty for default.",
                        text: Binding(
                            get: { viewModel.authConfig.pendingUserOverlayContent },
                            set: { viewModel.authConfig.pendingUserOverlayContent = $0 }
                        ),
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - LDAP Section

    private var ldapSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "person.badge.key", title: "LDAP")

            if viewModel.isLoadingLdap {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(
                        title: "LDAP",
                        subtitle: "Allow users to authenticate with an LDAP directory.",
                        isOn: Binding(
                            get: { viewModel.ldapConfig.enableLdap ?? false },
                            set: { viewModel.ldapConfig.enableLdap = $0 }
                        ),
                        showDivider: viewModel.ldapConfig.enableLdap == true
                    )

                    if viewModel.ldapConfig.enableLdap == true {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Label", placeholder: "LDAP",
                            text: Binding(get: { viewModel.ldapServerConfig.label }, set: { viewModel.ldapServerConfig.label = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Host", placeholder: "ldap.example.com",
                            text: Binding(get: { viewModel.ldapServerConfig.host }, set: { viewModel.ldapServerConfig.host = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Port", placeholder: "389",
                            text: Binding(
                                get: { viewModel.ldapServerConfig.port.map { String($0) } ?? "" },
                                set: { viewModel.ldapServerConfig.port = Int($0) }
                            ), keyboardType: .numberPad)
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Application DN", placeholder: "cn=admin,dc=example,dc=com",
                            text: Binding(get: { viewModel.ldapServerConfig.appDN }, set: { viewModel.ldapServerConfig.appDN = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        ldapPasswordRow
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Attribute for Mail", placeholder: "mail",
                            text: Binding(get: { viewModel.ldapServerConfig.attributeForMail }, set: { viewModel.ldapServerConfig.attributeForMail = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Attribute for Username", placeholder: "uid",
                            text: Binding(get: { viewModel.ldapServerConfig.attributeForUsername }, set: { viewModel.ldapServerConfig.attributeForUsername = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Search Base", placeholder: "ou=users,dc=foo,dc=example",
                            text: Binding(get: { viewModel.ldapServerConfig.searchBase }, set: { viewModel.ldapServerConfig.searchBase = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Search Filters", placeholder: "(&(objectClass=inetOrgPerson)(uid=%s))",
                            text: Binding(get: { viewModel.ldapServerConfig.searchFilters }, set: { viewModel.ldapServerConfig.searchFilters = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Use TLS",
                            isOn: Binding(get: { viewModel.ldapServerConfig.useTLS }, set: { viewModel.ldapServerConfig.useTLS = $0 }))

                        if viewModel.ldapServerConfig.useTLS {
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Certificate Path", placeholder: "/path/to/cert.pem",
                                text: Binding(
                                    get: { viewModel.ldapServerConfig.certificatePath ?? "" },
                                    set: { viewModel.ldapServerConfig.certificatePath = $0.isEmpty ? nil : $0 }
                                ))
                            Divider().padding(.leading, Spacing.md)
                            inlineToggleRow(title: "Validate Certificate",
                                isOn: Binding(get: { viewModel.ldapServerConfig.validateCert }, set: { viewModel.ldapServerConfig.validateCert = $0 }))
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Ciphers", placeholder: "ALL",
                                text: Binding(
                                    get: { viewModel.ldapServerConfig.ciphers ?? "" },
                                    set: { viewModel.ldapServerConfig.ciphers = $0.isEmpty ? nil : $0 }
                                ))
                        }

                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(
                            title: "Group Mapping",
                            subtitle: "Map LDAP groups to Open WebUI groups.",
                            isOn: Binding(get: { viewModel.ldapServerConfig.enableGroupManagement }, set: { viewModel.ldapServerConfig.enableGroupManagement = $0 }))

                        if viewModel.ldapServerConfig.enableGroupManagement {
                            Divider().padding(.leading, Spacing.md)
                            inlineToggleRow(
                                title: "Auto-Create Groups",
                                subtitle: "Create missing groups from LDAP groups.",
                                isOn: Binding(get: { viewModel.ldapServerConfig.enableGroupCreation }, set: { viewModel.ldapServerConfig.enableGroupCreation = $0 }))
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Group Attribute", placeholder: "memberOf",
                                text: Binding(get: { viewModel.ldapServerConfig.attributeForGroups }, set: { viewModel.ldapServerConfig.attributeForGroups = $0 }),
                                showDivider: false)
                        }
                    }
                }
            }
        }
    }

    private var ldapPasswordRow: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Application DN Password")
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
            Button { viewModel.showLdapPassword.toggle() } label: {
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

    // MARK: - OAuth / OIDC Section

    private var oauthSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "lock.shield", title: "OAuth / OIDC")

            if viewModel.isLoadingOAuth {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(
                        title: "OAuth / OIDC",
                        subtitle: "Allow users to authenticate with an OAuth / OIDC provider.",
                        isOn: Binding(
                            get: { viewModel.oauthConfig.enableOAuth },
                            set: { viewModel.oauthConfig.enableOAuth = $0 }
                        ),
                        showDivider: viewModel.oauthConfig.enableOAuth
                    )

                    if viewModel.oauthConfig.enableOAuth {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Provider Name", placeholder: "SSO",
                            text: Binding(get: { viewModel.oauthConfig.oauthProviderName }, set: { viewModel.oauthConfig.oauthProviderName = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Provider URL", placeholder: "https://accounts.google.com/.well-known/openid-configuration",
                            text: Binding(get: { viewModel.oauthConfig.openidProviderURL }, set: { viewModel.oauthConfig.openidProviderURL = $0 }),
                            keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Client ID", placeholder: "Enter Client ID",
                            text: Binding(get: { viewModel.oauthConfig.oauthClientId }, set: { viewModel.oauthConfig.oauthClientId = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        oauthSecretRow
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Redirect URI", placeholder: "Enter Redirect URI",
                            text: Binding(get: { viewModel.oauthConfig.openidRedirectURI }, set: { viewModel.oauthConfig.openidRedirectURI = $0 }),
                            keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Scopes", placeholder: "openid email profile",
                            text: Binding(get: { viewModel.oauthConfig.oauthScopes }, set: { viewModel.oauthConfig.oauthScopes = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Email Claim", placeholder: "email",
                            text: Binding(get: { viewModel.oauthConfig.oauthEmailClaim }, set: { viewModel.oauthConfig.oauthEmailClaim = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Username Claim", placeholder: "name",
                            text: Binding(get: { viewModel.oauthConfig.oauthUsernameClaim }, set: { viewModel.oauthConfig.oauthUsernameClaim = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Picture Claim", placeholder: "picture",
                            text: Binding(get: { viewModel.oauthConfig.oauthPictureClaim }, set: { viewModel.oauthConfig.oauthPictureClaim = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Sub Claim", placeholder: "sub",
                            text: Binding(get: { viewModel.oauthConfig.oauthSubClaim }, set: { viewModel.oauthConfig.oauthSubClaim = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "OAuth Signup", subtitle: "Allow users to create accounts through OAuth.",
                            isOn: Binding(get: { viewModel.oauthConfig.enableOAuthSignup }, set: { viewModel.oauthConfig.enableOAuthSignup = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Merge Accounts by Email", subtitle: "Link OAuth sign-ins to existing accounts with the same email.",
                            isOn: Binding(get: { viewModel.oauthConfig.oauthMergeAccountsByEmail }, set: { viewModel.oauthConfig.oauthMergeAccountsByEmail = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Auto Redirect", subtitle: "Send users directly to the OAuth provider from the sign-in page.",
                            isOn: Binding(get: { viewModel.oauthConfig.oauthAutoRedirect }, set: { viewModel.oauthConfig.oauthAutoRedirect = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Allowed Domains", placeholder: "* (all domains)",
                            text: Binding(get: { viewModel.oauthConfig.oauthAllowedDomains }, set: { viewModel.oauthConfig.oauthAllowedDomains = $0 }))
                    }
                }

                if viewModel.oauthConfig.enableOAuth {
                    // Role Mapping
                    SettingsSection(header: "Role Mapping") {
                        inlineToggleRow(
                            title: "Role Mapping",
                            subtitle: "Map OAuth claims to Open WebUI roles.",
                            isOn: Binding(get: { viewModel.oauthConfig.enableOAuthRoleManagement }, set: { viewModel.oauthConfig.enableOAuthRoleManagement = $0 })
                        )

                        if viewModel.oauthConfig.enableOAuthRoleManagement {
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Roles Claim", placeholder: "roles",
                                text: Binding(get: { viewModel.oauthConfig.oauthRolesClaim }, set: { viewModel.oauthConfig.oauthRolesClaim = $0 }))
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Admin Roles", placeholder: "admin",
                                text: Binding(get: { viewModel.oauthConfig.oauthAdminRoles }, set: { viewModel.oauthConfig.oauthAdminRoles = $0 }))
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Allowed Roles", placeholder: "*",
                                text: Binding(get: { viewModel.oauthConfig.oauthAllowedRoles }, set: { viewModel.oauthConfig.oauthAllowedRoles = $0 }),
                                showDivider: false)
                        }
                    }

                    // Group Mapping
                    SettingsSection(header: "Group Mapping") {
                        inlineToggleRow(
                            title: "Group Mapping",
                            subtitle: "Map OAuth claims to Open WebUI groups.",
                            isOn: Binding(get: { viewModel.oauthConfig.enableOAuthGroupManagement }, set: { viewModel.oauthConfig.enableOAuthGroupManagement = $0 })
                        )

                        if viewModel.oauthConfig.enableOAuthGroupManagement {
                            Divider().padding(.leading, Spacing.md)
                            inlineToggleRow(title: "Auto-Create Groups", subtitle: "Create missing groups from OAuth claims.",
                                isOn: Binding(get: { viewModel.oauthConfig.enableOAuthGroupCreation }, set: { viewModel.oauthConfig.enableOAuthGroupCreation = $0 }))
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Group Claim", placeholder: "groups",
                                text: Binding(get: { viewModel.oauthConfig.oauthGroupClaim }, set: { viewModel.oauthConfig.oauthGroupClaim = $0 }))
                            Divider().padding(.leading, Spacing.md)
                            inlineTextFieldRow(title: "Blocked Groups", placeholder: "Comma-separated group names",
                                text: Binding(get: { viewModel.oauthConfig.oauthBlockedGroups }, set: { viewModel.oauthConfig.oauthBlockedGroups = $0 }),
                                showDivider: false)
                        }
                    }

                    // Profile Sync
                    SettingsSection(header: "Profile Sync") {
                        inlineToggleRow(title: "Update Email on Login", subtitle: "Refresh the account email from OAuth on sign-in.",
                            isOn: Binding(get: { viewModel.oauthConfig.oauthUpdateEmailOnLogin }, set: { viewModel.oauthConfig.oauthUpdateEmailOnLogin = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Update Name on Login", subtitle: "Refresh the account name from OAuth on sign-in.",
                            isOn: Binding(get: { viewModel.oauthConfig.oauthUpdateNameOnLogin }, set: { viewModel.oauthConfig.oauthUpdateNameOnLogin = $0 }))
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Update Picture on Login", subtitle: "Refresh the profile picture from OAuth on sign-in.",
                            isOn: Binding(get: { viewModel.oauthConfig.oauthUpdatePictureOnLogin }, set: { viewModel.oauthConfig.oauthUpdatePictureOnLogin = $0 }),
                            showDivider: false)
                    }
                }
            }
        }
    }

    @State private var showOAuthSecret = false

    private var oauthSecretRow: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Client Secret")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Group {
                    if showOAuthSecret {
                        TextField("Enter Client Secret", text: Binding(
                            get: { viewModel.oauthConfig.oauthClientSecret },
                            set: { viewModel.oauthConfig.oauthClientSecret = $0 }
                        ))
                    } else {
                        SecureField("Enter Client Secret", text: Binding(
                            get: { viewModel.oauthConfig.oauthClientSecret },
                            set: { viewModel.oauthConfig.oauthClientSecret = $0 }
                        ))
                    }
                }
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            Spacer()
            Button { showOAuthSecret.toggle() } label: {
                Image(systemName: showOAuthSecret ? "eye.slash" : "eye")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    // MARK: - Shared Row Builders

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(title.uppercased())
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func sectionLoadingView() -> some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.regular).padding(.vertical, Spacing.lg)
            Spacer()
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
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
                    Text(title).scaledFont(size: 15).foregroundStyle(theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("", isOn: isOn).labelsHidden().tint(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)
            if showDivider { Divider().padding(.leading, Spacing.md) }
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
            ExpandableTextField(
                text: text,
                placeholder: placeholder,
                label: title,
                keyboardType: keyboardType
            )
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)
            if showDivider { Divider().padding(.leading, Spacing.md) }
        }
    }

    private func inlineTextAreaRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            ExpandableTextField(
                text: text,
                placeholder: placeholder,
                label: title
            )
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)
            if showDivider { Divider().padding(.leading, Spacing.md) }
        }
    }

    private func inlinePickerRow(
        title: String,
        selection: Binding<String>,
        options: [(value: String, label: String)]
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Text(title).scaledFont(size: 15).foregroundStyle(theme.textPrimary)
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
