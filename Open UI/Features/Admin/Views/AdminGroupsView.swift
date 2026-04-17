import SwiftUI

// MARK: - Admin Groups View

/// The "Groups" sub-tab inside the Admin → Users section.
/// Shows a list of groups, a search bar, and a "Default permissions" row.
struct AdminGroupsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminGroupsViewModel()
    @State private var showGroupSheet = false
    @State private var showDefaultPermissionsSheet = false

    var body: some View {
        List {
            // Search bar
            Section {
                searchBar
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // Error banner
            if let error = viewModel.errorMessage {
                Section {
                    errorBanner(error)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Count header
            if !viewModel.isLoading && !viewModel.groups.isEmpty {
                Section {
                    HStack {
                        Text("Groups \(viewModel.groups.count)")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.screenPadding)
                }
                .listRowInsets(EdgeInsets(top: Spacing.sm, leading: 0, bottom: Spacing.xs, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Groups list / loading / empty
            if viewModel.isLoading && viewModel.groups.isEmpty {
                Section {
                    loadingState
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if viewModel.groups.isEmpty && !viewModel.isLoading {
                Section {
                    emptyState
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(viewModel.filteredGroups) { group in
                        GroupRow(
                            group: group,
                            onEdit: {
                                viewModel.prepareEdit(group)
                                showGroupSheet = true
                            },
                            onDelete: {
                                viewModel.groupToDelete = group
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(theme.cardBackground)
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                        .padding(.horizontal, Spacing.screenPadding)
                )
            }

            // Default permissions row
            Section {
                defaultPermissionsRow
            }
            .listRowInsets(EdgeInsets(top: Spacing.lg, leading: 0, bottom: Spacing.xl, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.prepareCreate()
                    showGroupSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .scaledFont(size: 13, weight: .semibold)
                        Text("New Group")
                            .scaledFont(size: 14, weight: .medium)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.cardBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
                }
            }
        }
        .refreshable {
            await viewModel.loadGroups()
        }
        .sheet(isPresented: $showGroupSheet) {
            GroupEditSheet(
                viewModel: viewModel,
                serverBaseURL: dependencies.apiClient?.baseURL ?? ""
            ) {
                showGroupSheet = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
        .sheet(isPresented: $showDefaultPermissionsSheet) {
            DefaultPermissionsSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .confirmationDialog(
            "Delete \"\(viewModel.groupToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { viewModel.groupToDelete != nil },
                set: { if !$0 { viewModel.groupToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let group = viewModel.groupToDelete else { return }
                Task { await viewModel.deleteGroup(group) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.groupToDelete = nil
            }
        } message: {
            Text("This group will be permanently deleted and cannot be undone.")
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.loadGroups()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textTertiary)

            TextField("Search Groups", text: $viewModel.searchQuery)
                .scaledFont(size: 16)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
    }

    // MARK: - Group List

    private var groupList: some View {
        VStack(spacing: 0) {
            let groups = viewModel.filteredGroups
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    GroupRow(
                        group: group,
                        onEdit: {
                            viewModel.prepareEdit(group)
                            showGroupSheet = true
                        },
                        onDelete: {
                            viewModel.groupToDelete = group
                        }
                    )
                    if group.id != groups.last?.id {
                        Divider()
                            .padding(.horizontal, Spacing.screenPadding)
                    }
                }
            }
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.xs)
        }
    }

    // MARK: - Default Permissions Row

    private var defaultPermissionsRow: some View {
        Button {
            Task { await viewModel.loadDefaultPermissions() }
            showDefaultPermissionsSheet = true
        } label: {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(theme.textTertiary.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: "person.2.fill")
                        .scaledFont(size: 18, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Default permissions")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                    Text("applies to all users with the \"user\" role")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading groups…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "person.2.slash")
                .scaledFont(size: 40)
                .foregroundStyle(theme.textTertiary)
            Text(viewModel.searchQuery.isEmpty ? "No groups yet." : "No results for \"\(viewModel.searchQuery)\"")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 14)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
            Spacer()
            Button("Retry") {
                Task { await viewModel.loadGroups() }
            }
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .padding(Spacing.md)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
    }
}

// MARK: - Group Row

private struct GroupRow: View {
    let group: GroupDetail
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let count = group.memberCount {
                        Text("\(count) \(count == 1 ? "member" : "members")")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    if !group.description.isEmpty {
                        Text(group.description)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button(action: {
                Haptics.play(.light)
                onEdit()
            }) {
                Image(systemName: "pencil")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Haptics.play(.medium)
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Default Permissions Sheet

struct DefaultPermissionsSheet: View {
    @Bindable var viewModel: AdminGroupsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.sectionGap) {
                    if viewModel.isLoadingDefaults {
                        VStack(spacing: Spacing.md) {
                            ProgressView().controlSize(.large)
                            Text("Loading permissions…")
                                .scaledFont(size: 15)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        GroupPermissionsEditor(permissions: $viewModel.defaultPermissions)
                            .padding(.top, Spacing.sm)

                        if let err = viewModel.defaultsSaveError {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(theme.error)
                                Text(err)
                                    .scaledFont(size: 13)
                                    .foregroundStyle(theme.error)
                                Spacer()
                            }
                            .padding(Spacing.md)
                            .background(theme.error.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                            .padding(.horizontal, Spacing.screenPadding)
                        }
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle("Default Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.textPrimary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSavingDefaults {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.saveDefaultPermissions()
                                if viewModel.defaultsSaveSuccess {
                                    dismiss()
                                }
                            }
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
            }
        }
    }
}
