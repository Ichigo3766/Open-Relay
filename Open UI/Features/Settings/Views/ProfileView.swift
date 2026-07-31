import SwiftUI
import PhotosUI

/// Modern, sleek account page inspired by Apple Settings > Apple ID.
struct ProfileView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    // MARK: - Editable Profile Fields
    @State private var editName = ""
    @State private var editBio = ""
    @State private var editGender = "Prefer not to say"
    @State private var editBirthDate: Date? = nil
    @State private var showBirthDatePicker = false
    @State private var editWebhookURL = ""

    // MARK: - Chat Variables (v0.11.0)
    @State private var chatVariables: [String: String] = [:]
    @State private var showAddVariableSheet = false
    @State private var editingVariableKey: String? = nil
    @State private var newVarKey = ""
    @State private var newVarValue = ""
    @State private var variableKeyError: String? = nil

    // MARK: - Profile Image
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var profileImageData: Data?
    @State private var profileImageAction: ProfileImageAction = .keep
    @State private var showImageActionSheet = false
    @State private var showPhotoPicker = false

    // MARK: - Save State
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false

    // MARK: - Change Password
    @State private var showPasswordSection = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isChangingPassword = false
    @State private var passwordChangeSuccess = false
    @State private var passwordChangeError: String?

    // MARK: - Loading
    @State private var isLoadingSettings = false

    // MARK: - Original values (for smart save / change detection)
    @State private var originalName = ""
    @State private var originalBio = ""
    @State private var originalGender = "Prefer not to say"
    @State private var originalBirthDate: Date? = nil
    @State private var originalWebhookURL = ""

    // MARK: - Original avatar as base64 (captured at load to survive bio/name edits)
    /// When the user opens ProfileView we snapshot the current avatar as a base64 data URI.
    /// The `.keep` case in `saveProfile()` uses this so editing bio/name never sends an
    /// empty `profile_image_url` to the server, which would otherwise clear the avatar.
    @State private var originalAvatarBase64: String = ""

    private let genderOptions = ["Prefer not to say", "Male", "Female", "Custom"]

    // MARK: - Cached Formatters

    /// ISO 8601 date formatter used to parse and serialise the birth date (YYYY-MM-DD).
    /// Locale is fixed to en_US_POSIX so the format is never locale-sensitive.
    /// No explicit timezone — uses the device's local timezone so that "1999-12-29"
    /// parses as midnight local time and displays correctly in the UI.
    private static let dobAPIFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Parse a date string returned by the server.
    /// Handles multiple formats the server may return:
    ///   "1999-12-28"               (pure date)
    ///   "1999-12-28T00:00:00"      (datetime, no timezone)
    ///   "1999-12-28T00:00:00Z"     (datetime UTC)
    private static func parseDOB(_ string: String) -> Date? {
        // Fast path: plain date string
        if let d = dobAPIFormatter.date(from: string) {
            print("[DOB] parseDOB('\(string)') → plain parse succeeded → \(d)")
            return d
        }
        // Fallback: datetime string — strip time component and parse date part
        let datePart = String(string.prefix(10))
        if let d = dobAPIFormatter.date(from: datePart) {
            print("[DOB] parseDOB('\(string)') → fallback datePart '\(datePart)' → \(d)")
            return d
        }
        print("[DOB] parseDOB('\(string)') → ALL formats FAILED, returning nil")
        return nil
    }

    enum ProfileImageAction {
        case keep, remove, initials, newImage(Data)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Hero card — avatar + identity
                heroCard
                    .padding(.top, Spacing.sm)

                // Profile fields
                profileSection

                // Notifications
                notificationsSection

                // Chat Variables (v0.11.0)
                chatVariablesSection

                // Security
                securitySection

                // Save button
                saveButton
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.xl)
        }
        .background(theme.background)
        .navigationTitle("Your Account")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadCurrentValues() }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await handlePhotoSelection(newItem) }
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        HStack(spacing: Spacing.md + 4) {
            // Avatar with camera badge
            Button {
                showImageActionSheet = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    profileImage
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())

                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(theme.brandPrimary)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(theme.surfaceContainer, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            .confirmationDialog("Profile Photo", isPresented: $showImageActionSheet) {
                Button("Choose from Library") {
                    showPhotoPicker = true
                }
                Button("Use Initials") {
                    profileImageAction = .initials
                    profileImageData = nil
                }
                Button("Remove Photo") {
                    profileImageAction = .remove
                    profileImageData = nil
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)

            // Name + email + role
            VStack(alignment: .leading, spacing: 4) {
                Text(user?.displayName ?? "User")
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Text(user?.email ?? "")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)

                if let role = user?.role.rawValue.capitalized {
                    Text(role)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.md + 4)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("PROFILE")

            VStack(spacing: 0) {
                // Name
                inlineEditRow(label: "Name", showDivider: true) {
                    TextField("Your name", text: $editName)
                        .scaledFont(size: 16)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                }

                // Bio
                inlineEditRow(label: "Bio", showDivider: true) {
                    TextField("Share your background and interests", text: $editBio, axis: .vertical)
                        .scaledFont(size: 16)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                }

                // Gender
                inlineEditRow(label: "Gender", showDivider: true) {
                    Picker("", selection: $editGender) {
                        ForEach(genderOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .tint(theme.textPrimary)
                }

                // Birth Date
                inlineEditRow(label: "Birth Date", showDivider: false) {
                    if let date = editBirthDate {
                        HStack(spacing: Spacing.xs) {
                            Text(date, style: .date)
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textPrimary)
                            Button {
                                withAnimation { editBirthDate = nil; showBirthDatePicker = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.25)) { showBirthDatePicker.toggle() }
                        }
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                editBirthDate = Date()
                                showBirthDatePicker = true
                            }
                        } label: {
                            Text("Set birth date")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }

                if showBirthDatePicker, editBirthDate != nil {
                    DatePicker(
                        "Birth Date",
                        selection: Binding(
                            get: { editBirthDate ?? Date() },
                            set: { editBirthDate = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("NOTIFICATIONS")

            VStack(spacing: 0) {
                inlineEditRow(label: "Webhook URL", showDivider: false) {
                    TextField("Enter URL", text: $editWebhookURL)
                        .scaledFont(size: 16)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        }
    }

    // MARK: - Chat Variables Section (v0.11.0)

    private var chatVariablesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                sectionHeader("CHAT VARIABLES")
                Spacer()
                Button {
                    newVarKey = ""
                    newVarValue = ""
                    editingVariableKey = nil
                    variableKeyError = nil
                    showAddVariableSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Spacing.md)
            }

            if chatVariables.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "curlybraces")
                        .scaledFont(size: 28)
                        .foregroundStyle(theme.textTertiary)
                    Text("No variables yet")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                    Text("Use {{VAR_NAME}} in any chat message to insert the variable's value.")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.lg)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(chatVariables.keys.sorted().enumerated()), id: \.element) { index, key in
                        let value = chatVariables[key] ?? ""
                        let isLast = index == chatVariables.count - 1

                        VStack(spacing: 0) {
                            HStack(spacing: Spacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("{{\(key)}}")
                                        .scaledFont(size: 13, weight: .semibold)
                                        .foregroundStyle(theme.brandPrimary)
                                        .fontDesign(.monospaced)
                                    Text(value.isEmpty ? "(empty)" : value)
                                        .scaledFont(size: 14)
                                        .foregroundStyle(value.isEmpty ? theme.textTertiary : theme.textPrimary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button {
                                    newVarKey = key
                                    newVarValue = value
                                    editingVariableKey = key
                                    variableKeyError = nil
                                    showAddVariableSheet = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .scaledFont(size: 13)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    withAnimation { chatVariables.removeValue(forKey: key) }
                                    Task { await saveVariables() }
                                } label: {
                                    Image(systemName: "trash")
                                        .scaledFont(size: 13)
                                        .foregroundStyle(theme.error)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 12)

                            if !isLast {
                                Divider().padding(.leading, Spacing.md)
                            }
                        }
                    }
                }
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            }
        }
        .sheet(isPresented: $showAddVariableSheet) {
            chatVariableSheet
        }
    }

    private var chatVariableSheet: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Variable names must be letters, numbers, and underscores only. Use {{VARIABLE_NAME}} in chat messages.")) {
                    HStack {
                        Text("{{")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                            .fontDesign(.monospaced)
                        TextField("VARIABLE_NAME", text: $newVarKey)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: newVarKey) { _, v in
                                // Only allow valid identifier chars
                                let filtered = v.filter { $0.isLetter || $0.isNumber || $0 == "_" }
                                if filtered != v { newVarKey = filtered }
                                variableKeyError = nil
                            }
                            .disabled(editingVariableKey != nil)
                        Text("}}")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                            .fontDesign(.monospaced)
                    }

                    TextField("Value", text: $newVarValue, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                }

                if let error = variableKeyError {
                    Section {
                        Text(error)
                            .foregroundStyle(theme.error)
                            .scaledFont(size: 13)
                    }
                }
            }
            .navigationTitle(editingVariableKey == nil ? "New Variable" : "Edit Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddVariableSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedKey = newVarKey.trimmingCharacters(in: .whitespaces).uppercased()
                        guard !trimmedKey.isEmpty else {
                            variableKeyError = "Variable name cannot be empty."
                            return
                        }
                        // If adding new, check for duplicate
                        if editingVariableKey == nil && chatVariables[trimmedKey] != nil {
                            variableKeyError = "A variable with this name already exists."
                            return
                        }
                        if let old = editingVariableKey, old != trimmedKey {
                            chatVariables.removeValue(forKey: old)
                        }
                        chatVariables[trimmedKey] = newVarValue
                        showAddVariableSheet = false
                        editingVariableKey = nil
                        Task { await saveVariables() }
                    }
                    .fontWeight(.semibold)
                    .disabled(newVarKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("SECURITY")

            VStack(spacing: 0) {
                // Expand/collapse row
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        showPasswordSection.toggle()
                        if !showPasswordSection {
                            currentPassword = ""
                            newPassword = ""
                            confirmPassword = ""
                            passwordChangeError = nil
                            passwordChangeSuccess = false
                        }
                    }
                } label: {
                    HStack {
                        Text("Change Password")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .rotationEffect(.degrees(showPasswordSection ? 90 : 0))
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 14)
                }

                AnimatedPresence(visible: showPasswordSection) {
                    VStack(spacing: 0) {
                        Divider().padding(.leading, Spacing.md)

                        VStack(spacing: Spacing.md) {
                            SecureField("Current Password", text: $currentPassword)
                                .textContentType(.password)
                                .padding(Spacing.md)
                                .background(theme.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

                            SecureField("New Password", text: $newPassword)
                                .textContentType(.newPassword)
                                .padding(Spacing.md)
                                .background(theme.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

                            SecureField("Confirm New Password", text: $confirmPassword)
                                .textContentType(.newPassword)
                                .padding(Spacing.md)
                                .background(theme.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

                            if let error = passwordChangeError {
                                Text(error)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.error)
                            }

                            if passwordChangeSuccess {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(theme.success)
                                    Text("Password changed successfully")
                                        .scaledFont(size: 12, weight: .medium)
                                        .foregroundStyle(theme.success)
                                }
                            }

                            Button {
                                Task { await changePassword() }
                            } label: {
                                HStack {
                                    if isChangingPassword {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text("Update Password")
                                        .scaledFont(size: 15, weight: .semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.sm)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.brandPrimary)
                            .disabled(
                                currentPassword.isEmpty ||
                                newPassword.count < 8 ||
                                newPassword != confirmPassword ||
                                isChangingPassword
                            )
                        }
                        .padding(Spacing.md)
                    }
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        }
    }

    // MARK: - Save Button

    private var saveButton: some View {
        VStack(spacing: Spacing.sm) {
            if let error = saveError {
                Text(error)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.error)
                    .multilineTextAlignment(.center)
            }

            if saveSuccess {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                    Text("Profile saved")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.success)
                }
            }

            Button {
                Task { await saveProfile() }
            } label: {
                HStack(spacing: Spacing.sm) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text("Save")
                        .scaledFont(size: 17, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(theme.brandPrimary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            }
            .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            .opacity(editName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 12, weight: .medium)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, Spacing.md)
    }

    private func inlineEditRow<Content: View>(
        label: String,
        showDivider: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: Spacing.md)

                content()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 13)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    // MARK: - Profile Image

    @ViewBuilder
    private var profileImage: some View {
        if let data = profileImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if case .initials = profileImageAction {
            initialsAvatar
        } else if case .remove = profileImageAction {
            initialsAvatar
        } else {
            UserAvatar(
                size: 80,
                imageURL: profileImageURL,
                name: user?.displayName,
                authToken: dependencies.apiClient?.network.authToken
            )
        }
    }

    private var initialsAvatar: some View {
        ZStack {
            Circle()
                .fill(theme.brandPrimary.opacity(0.2))
            Text(initialsText)
                .scaledFont(size: 28, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
        }
    }

    private var initialsText: String {
        let name = editName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "?" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    // MARK: - Helpers

    private var user: User? { viewModel.currentUser }

    private var profileImageURL: URL? {
        guard let userId = user?.id,
              let baseURL = dependencies.apiClient?.baseURL,
              !userId.isEmpty, !baseURL.isEmpty else { return nil }
        let v = viewModel.profileImageVersion
        return URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image?v=\(v)")
    }

    // MARK: - Data Loading

    private func loadCurrentValues() {
        Task {
            guard let api = dependencies.apiClient else { return }
            isLoadingSettings = true
            defer { isLoadingSettings = false }

            // 1. Fetch fresh user data from server
            // IMPORTANT: capture freshUser locally so we populate the form from the
            // live network response — not from viewModel.currentUser which may still
            // hold the old cached value at the point the guard runs.
            var userToLoad: User?
            do {
                let freshUser = try await api.getCurrentUser()
                await MainActor.run { viewModel.currentUser = freshUser }
                viewModel.cacheCurrentUser()
                userToLoad = freshUser
            } catch {
                // Fall back to cached user if server fetch fails
                userToLoad = viewModel.currentUser
            }

            guard let user = userToLoad else { return }

            await MainActor.run {
                // 2. Populate form fields from (fresh) user
                editName = user.displayName
                editBio = user.bio ?? ""

                if let gender = user.gender, !gender.isEmpty {
                    editGender = genderOptions.contains(gender) ? gender : "Custom"
                } else {
                    editGender = "Prefer not to say"
                }

                print("[DOB] user.dateOfBirth from server = '\(user.dateOfBirth ?? "nil")'")
                if let dob = user.dateOfBirth, !dob.isEmpty {
                    let parsed = ProfileView.parseDOB(dob)
                    print("[DOB] editBirthDate set to: \(parsed?.description ?? "nil")")
                    editBirthDate = parsed
                } else {
                    print("[DOB] dateOfBirth is nil or empty — setting editBirthDate = nil")
                    editBirthDate = nil
                }

                // 3. Snapshot originals for change detection
                originalName = editName
                originalBio = editBio
                originalGender = editGender
                originalBirthDate = editBirthDate
            }

            // 4. Snapshot avatar as base64 so `.keep` in saveProfile() can preserve it
            // without relying on profileImageURL in the server response (which is empty
            // for server-hosted avatars and would clear the photo on bio/name edits).
            if let url = profileImageURL {
                if let cachedImage = await ImageCacheService.shared.loadImage(from: url, authToken: api.network.authToken),
                   let jpegData = cachedImage.jpegData(compressionQuality: 0.9) {
                    let b64 = "data:image/jpeg;base64," + jpegData.base64EncodedString()
                    await MainActor.run { originalAvatarBase64 = b64 }
                }
            }

            // 5. Load webhook URL from user settings
            do {
                let settings = try await api.getUserSettings()
                if let ui = settings["ui"] as? [String: Any],
                   let notifications = ui["notifications"] as? [String: Any],
                   let webhookUrl = notifications["webhook_url"] as? String {
                    await MainActor.run {
                        editWebhookURL = webhookUrl
                        originalWebhookURL = webhookUrl
                    }
                } else {
                    await MainActor.run {
                        editWebhookURL = ""
                        originalWebhookURL = ""
                    }
                }
            } catch {
                // Silently fail — webhook is optional
            }

            // 6. Load chat variables
            do {
                let vars = try await api.getUserVariables()
                await MainActor.run {
                    chatVariables = vars.variables
                }
            } catch {
                // Silently fail — variables are optional
            }
        }
    }

    // MARK: - Photo Handling

    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                await MainActor.run {
                    profileImageData = data
                    profileImageAction = .newImage(data)
                }
            }
        } catch {
            // Silently fail
        }
    }

    // MARK: - Save Profile

    private func saveProfile() async {
        guard let api = dependencies.apiClient else { return }
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        saveError = nil
        saveSuccess = false

        // ── Capture the image URL BEFORE any mutations to avoid exclusive-access conflicts ──
        let avatarURL = profileImageURL
        let currentAction = profileImageAction

        do {
            // ── Step 1: Build the profile image payload ──
            let profileImageUrlString: String
            switch currentAction {
            case .keep:
                // Use the base64 snapshot captured when the view loaded.
                // This is the only reliable way to preserve a server-hosted avatar —
                // viewModel.currentUser?.profileImageURL is empty for server-hosted images,
                // so reading it would send "" and clear the avatar.
                profileImageUrlString = originalAvatarBase64
            case .remove, .initials:
                profileImageUrlString = ""
            case .newImage(let data):
                let base64 = data.base64EncodedString()
                let prefix: String
                if data.count >= 8 {
                    let header = [UInt8](data.prefix(8))
                    if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                        prefix = "data:image/png;base64,"
                    } else if header.starts(with: [0xFF, 0xD8]) {
                        prefix = "data:image/jpeg;base64,"
                    } else {
                        prefix = "data:image/png;base64,"
                    }
                } else {
                    prefix = "data:image/png;base64,"
                }
                profileImageUrlString = prefix + base64
            }

            // ── Step 2: Build remaining fields ──
            let genderValue: String?
            if editGender != originalGender {
                genderValue = editGender == "Prefer not to say" ? nil : editGender
            } else {
                genderValue = viewModel.currentUser?.gender
            }

            let dobValue: String?
            if editBirthDate != originalBirthDate {
                dobValue = editBirthDate.map { ProfileView.dobAPIFormatter.string(from: $0) }
            } else {
                dobValue = viewModel.currentUser?.dateOfBirth
            }

            // ── Step 3: Send update to server ──
            try await api.updateProfile(
                name: trimmedName,
                profileImageUrl: profileImageUrlString,
                bio: editBio,
                gender: genderValue,
                dateOfBirth: dobValue
            )

            // ── Step 4: Re-fetch the canonical user from server (single atomic assignment) ──
            let freshUser = try await api.getCurrentUser()
            viewModel.currentUser = freshUser
            viewModel.cacheCurrentUser()

            // Snapshot new originals for change detection
            originalName = trimmedName
            originalBio = editBio
            originalGender = editGender
            originalBirthDate = editBirthDate

            // ── Step 5: Update image cache ──
            if let url = avatarURL {
                switch currentAction {
                case .newImage(let imgData):
                    await ImageCacheService.shared.evict(for: url)
                    if let newImage = UIImage(data: imgData) {
                        await ImageCacheService.shared.store(newImage, for: url)
                    }
                    profileImageData = nil
                    profileImageAction = .keep
                case .remove, .initials:
                    await ImageCacheService.shared.evict(for: url)
                case .keep:
                    break
                }
            } else if case .newImage = currentAction {
                profileImageData = nil
                profileImageAction = .keep
            }

            // Bump version so all avatar views app-wide re-fetch the new image
            if case .keep = currentAction {
                // No image change — skip version bump
            } else {
                viewModel.profileImageVersion += 1
            }

            // ── Step 6: Update webhook if changed ──
            if editWebhookURL != originalWebhookURL {
                try await api.mergeUserUISettings([
                    "notifications": ["webhook_url": editWebhookURL]
                ])
                originalWebhookURL = editWebhookURL
            }

            // Done — show success
            isSaving = false
            saveSuccess = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveSuccess = false
        } catch {
            saveError = APIError.from(error).errorDescription ?? "Failed to update profile."
            isSaving = false
        }
    }

    // MARK: - Save Variables

    private func saveVariables() async {
        guard let api = dependencies.apiClient else { return }
        do {
            _ = try await api.updateUserVariables(chatVariables)
        } catch {
            // Silently fail — variables save is non-critical
        }
    }

    // MARK: - Change Password

    private func changePassword() async {
        guard let api = dependencies.apiClient else { return }
        guard newPassword == confirmPassword else {
            passwordChangeError = "Passwords do not match."
            return
        }
        guard newPassword.count >= 8 else {
            passwordChangeError = "Password must be at least 8 characters."
            return
        }

        isChangingPassword = true
        passwordChangeError = nil
        passwordChangeSuccess = false

        do {
            try await api.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            passwordChangeSuccess = true
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
        } catch {
            let apiError = APIError.from(error)
            if case .httpError(let code, let msg, _) = apiError, code == 400 || code == 401 {
                passwordChangeError = msg ?? "Current password is incorrect."
            } else {
                passwordChangeError = apiError.errorDescription ?? "Failed to change password."
            }
        }

        isChangingPassword = false
    }
}
