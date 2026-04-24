import SwiftUI

// MARK: - Automations List (Sheet root)

struct AutomationsListView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: AutomationsViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                AutomationsContentView(vm: vm, onDismiss: { dismiss() })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if viewModel == nil, let api = dependencies.apiClient {
                viewModel = AutomationsViewModel(apiClient: api)
                await viewModel?.loadAutomations()
            }
        }
    }
}

// MARK: - Main Content

private struct AutomationsContentView: View {
    @Bindable var vm: AutomationsViewModel
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedForDetail: Automation?

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(theme.textTertiary)
                        TextField("Search Automations", text: $vm.searchText)
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // Filter picker
                    HStack {
                        Picker("Filter", selection: $vm.filterState) {
                            ForEach(AutomationsViewModel.FilterState.allCases, id: \.self) { state in
                                Text(state.rawValue).tag(state)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.leading, 12)
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    Divider().opacity(0.3)

                    if vm.isLoading {
                        Spacer()
                        ProgressView("Loading…")
                        Spacer()
                    } else if vm.filteredAutomations.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }

                // Toast overlay
                if let msg = vm.toastMessage {
                    VStack {
                        Spacer()
                        Text(msg)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.75))
                            .clipShape(Capsule())
                            .padding(.bottom, 32)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.3), value: vm.toastMessage)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            vm.toastMessage = nil
                        }
                    }
                }
            }
            .navigationTitle("Automations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(Color.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .systemGray5).opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $vm.showCreateSheet) {
                CreateAutomationSheet(vm: vm)
            }
            .sheet(item: $selectedForDetail) { automation in
                NavigationStack {
                    AutomationDetailView(automation: automation, listVM: vm)
                }
            }
            .alert("Error", isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .confirmationDialog("Delete Automation", isPresented: $vm.showDeleteConfirmation, titleVisibility: .visible) {
                if let a = vm.deletingAutomation {
                    Button("Delete \"\(a.name)\"", role: .destructive) {
                        Task { await vm.deleteAutomation(a) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the automation and all its run history.")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(vm.filteredAutomations) { automation in
                AutomationRow(
                    automation: automation,
                    onToggle: { Task { await vm.toggle(automation) } },
                    onEdit: { selectedForDetail = automation },
                    onRunNow: { Task { await vm.runNow(automation) } },
                    onDelete: {
                        vm.deletingAutomation = automation
                        vm.showDeleteConfirmation = true
                    }
                )
                .listRowBackground(theme.surfaceContainer)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .contentShape(Rectangle())
                .onTapGesture { selectedForDetail = automation }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            // Use a detached task to prevent SwiftUI's refresh action from cancelling the request
            await withCheckedContinuation { continuation in
                Task.detached { [vm] in
                    await vm.loadAutomations()
                    continuation.resume()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(theme.textTertiary)
            Text("No Automations")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Schedule prompts to run automatically at recurring times.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                vm.showCreateSheet = true
            } label: {
                Label("New Automation", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(theme.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }
}

// MARK: - Row

private struct AutomationRow: View {
    let automation: Automation
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onRunNow: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(automation.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(automation.scheduleDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            // 3-dot context menu
            Menu {
                Button { onEdit() } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button { onRunNow() } label: {
                    Label("Run Now", systemImage: "play")
                }
                Divider()
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }

            // Toggle
            Toggle("", isOn: Binding(
                get: { automation.isActive },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .tint(theme.accentColor)
        }
        .padding(.vertical, 12)
    }
}
