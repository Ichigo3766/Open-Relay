import SwiftUI

/// Displays and manages the user's AI memories.
///
/// Memories are persistent context that the AI uses across conversations.
/// Users can view, search, add (with type + path), edit, and delete memories.
/// Matches the WebUI's Settings → Personalization → Memory section.
struct MemoriesView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var memories: [[String: Any]] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isAddingMemory = false
    @State private var editingMemoryId: String?
    @State private var editText = ""
    @State private var editType = "user"
    @State private var editPath = ""
    @State private var newMemoryText = ""
    @State private var newMemoryType = "user"
    @State private var newMemoryPath = ""
    @State private var showClearAllConfirmation = false
    @State private var isClearingAll = false
    @State private var memoryEnabled = false
    @State private var isLoadingMemoryToggle = false
    @State private var searchQuery = ""
    @State private var showResetEmbeddingsConfirmation = false
    @State private var isResettingEmbeddings = false

    // MARK: - Computed

    private var sortedFilteredMemories: [[String: Any]] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [[String: Any]] = q.isEmpty ? memories : memories.filter { memory in
            let content = (memory["content"] as? String ?? "").lowercased()
            let path = (memory["path"] as? String ?? "").lowercased()
            let type = (memory["type"] as? String ?? "").lowercased()
            return content.contains(q) || path.contains(q) || type.contains(q)
        }
        // Sort by updated_at descending (most recent first), matching WebUI
        return filtered.sorted {
            let a = $0["updated_at"] as? Double ?? 0
            let b = $1["updated_at"] as? Double ?? 0
            return a > b
        }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: Spacing.lg) {
                    ProgressView()
                    Text("Loading memories…")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                memoryList
            }
        }
        .background(theme.background)
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { isAddingMemory = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await loadMemories()
            await loadMemoryToggle()
        }
        .destructiveConfirmation(
            isPresented: $showClearAllConfirmation,
            title: "Clear All Memories",
            message: "This will permanently delete all your memories. The AI will no longer have this context.",
            destructiveTitle: "Clear All"
        ) {
            Task { await clearAllMemories() }
        }
        .destructiveConfirmation(
            isPresented: $showResetEmbeddingsConfirmation,
            title: "Rebuild Search Index",
            message: "This will re-generate the vector embeddings for all memories. Use this if semantic search seems broken.",
            destructiveTitle: "Rebuild"
        ) {
            Task { await resetEmbeddings() }
        }
    }

    // MARK: - Memory List

    private var memoryList: some View {
        List {
            // Memory enabled toggle
            Section {
                Toggle(isOn: $memoryEnabled) {
                    Label("Enable Memory", systemImage: "brain")
                }
                .tint(theme.brandPrimary)
                .disabled(isLoadingMemoryToggle)
                .onChange(of: memoryEnabled) { _, newValue in
                    Task { await updateMemoryToggle(newValue) }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("When enabled, the AI remembers context about you across conversations. Works with all models.")
            }

            // Add new memory section
            if isAddingMemory {
                Section {
                    addMemoryForm
                } header: {
                    Text("New Memory")
                }
            }

            // Error
            if let error = errorMessage {
                Section {
                    Text(error)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.error)
                }
            }

            // Search bar + memory count
            if !memories.isEmpty {
                Section {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                        TextField("Search memories…", text: $searchQuery)
                            .scaledFont(size: 15)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !searchQuery.isEmpty {
                            Button { searchQuery = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Existing memories or empty state
            Section {
                if memories.isEmpty && !isAddingMemory {
                    emptyStateInline
                } else if !sortedFilteredMemories.isEmpty {
                    ForEach(sortedFilteredMemories, id: \.memoryId) { memory in
                        memoryRow(memory: memory)
                    }
                } else if !searchQuery.isEmpty {
                    Text("No memories match \"\(searchQuery)\"")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Spacing.md)
                        .listRowBackground(Color.clear)
                }
            } header: {
                if !memories.isEmpty {
                    HStack {
                        let count = sortedFilteredMemories.count
                        let total = memories.count
                        if searchQuery.isEmpty {
                            Text("\(total) memor\(total == 1 ? "y" : "ies")")
                        } else {
                            Text("\(count) of \(total) memor\(total == 1 ? "y" : "ies")")
                        }
                        Spacer()
                    }
                }
            }

            // Danger zone
            if !memories.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text(isClearingAll ? "Clearing…" : "Clear All Memories")
                        }
                    }
                    .disabled(isClearingAll)

                    Button {
                        showResetEmbeddingsConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(theme.textSecondary)
                            Text(isResettingEmbeddings ? "Rebuilding…" : "Rebuild Search Index")
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                    .disabled(isResettingEmbeddings)
                } footer: {
                    Text("Rebuild Search Index re-generates vector embeddings for all memories. Use this if the AI stops recalling memories correctly.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Add Memory Form

    private var addMemoryForm: some View {
        VStack(spacing: Spacing.sm) {
            // Content
            TextField("What should the AI remember?", text: $newMemoryText, axis: .vertical)
                .lineLimit(3...6)
                .scaledFont(size: 16)

            Divider()

            // Type toggle
            HStack {
                Text("Type")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    newMemoryType = newMemoryType == "user" ? "context" : "user"
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: newMemoryType == "user" ? "person.fill" : "bubble.left.and.bubble.right")
                            .scaledFont(size: 11, weight: .medium)
                        Text(newMemoryType == "user" ? "User" : "Context")
                            .scaledFont(size: 13, weight: .semibold)
                    }
                    .foregroundStyle(newMemoryType == "user" ? theme.brandPrimary : theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        (newMemoryType == "user" ? theme.brandPrimary : theme.textSecondary).opacity(0.12),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }

            // Path (optional)
            HStack {
                Text("Path")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Text("(optional)")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
            TextField("e.g. work/projects", text: $newMemoryPath)
                .scaledFont(size: 14)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(theme.textPrimary)

            // Buttons
            HStack {
                Button("Cancel") {
                    withAnimation {
                        isAddingMemory = false
                        newMemoryText = ""
                        newMemoryType = "user"
                        newMemoryPath = ""
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task { await addMemory() }
                } label: {
                    Text("Save").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.brandPrimary)
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Memory Row

    @ViewBuilder
    private func memoryRow(memory: [String: Any]) -> some View {
        let memId = memory["id"] as? String ?? ""
        let content = memory["content"] as? String ?? ""
        let type = memory["type"] as? String ?? "context"
        let path = memory["path"] as? String
        let updatedAt = memory["updated_at"] as? Double

        if editingMemoryId == memId {
            // Edit mode
            VStack(spacing: Spacing.sm) {
                TextField("Memory content", text: $editText, axis: .vertical)
                    .lineLimit(3...6)
                    .scaledFont(size: 16)

                Divider()

                // Type toggle
                HStack {
                    Text("Type")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Button {
                        editType = editType == "user" ? "context" : "user"
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: editType == "user" ? "person.fill" : "bubble.left.and.bubble.right")
                                .scaledFont(size: 11, weight: .medium)
                            Text(editType == "user" ? "User" : "Context")
                                .scaledFont(size: 13, weight: .semibold)
                        }
                        .foregroundStyle(editType == "user" ? theme.brandPrimary : theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            (editType == "user" ? theme.brandPrimary : theme.textSecondary).opacity(0.12),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Path
                HStack {
                    Text("Path")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    Text("(optional)")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                TextField("e.g. work/projects", text: $editPath)
                    .scaledFont(size: 14)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                HStack {
                    Button("Cancel") {
                        withAnimation { editingMemoryId = nil }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        Task { await updateMemory(id: memId) }
                    } label: {
                        Text("Save").fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.brandPrimary)
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, Spacing.xs)
        } else {
            // Display mode
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Path label (if present)
                if let path, !path.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .scaledFont(size: 10, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                        Text(path)
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                // Content
                Text(content)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // Footer: type badge + timestamp
                HStack(spacing: Spacing.sm) {
                    // Type badge
                    HStack(spacing: 3) {
                        Image(systemName: type == "user" ? "person.fill" : "bubble.left.and.bubble.right")
                            .scaledFont(size: 9, weight: .medium)
                        Text(type == "user" ? "User" : "Context")
                            .scaledFont(size: 10, weight: .semibold)
                    }
                    .foregroundStyle(type == "user" ? theme.brandPrimary : theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        (type == "user" ? theme.brandPrimary : theme.textTertiary).opacity(0.1),
                        in: Capsule()
                    )

                    if let updatedAt {
                        Text(Date(timeIntervalSince1970: updatedAt).formatted(.relative(presentation: .named)))
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer()
                }
            }
            .padding(.vertical, Spacing.xxs)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    editText = content
                    editType = type
                    editPath = path ?? ""
                    withAnimation { editingMemoryId = memId }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    Task { await deleteMemory(id: memId) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Task { await deleteMemory(id: memId) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    editText = content
                    editType = type
                    editPath = path ?? ""
                    withAnimation { editingMemoryId = memId }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(theme.brandPrimary)
            }
        }
    }

    // MARK: - Empty State (inline)

    private var emptyStateInline: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "brain")
                .scaledFont(size: 48)
                .foregroundStyle(theme.textTertiary.opacity(0.5))
                .padding(.top, Spacing.lg)

            Text("No Memories")
                .scaledFont(size: 20, weight: .semibold)
                .foregroundStyle(theme.textPrimary)

            Text("Memories help the AI remember important context about you across conversations.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.lg)

            Button {
                withAnimation { isAddingMemory = true }
            } label: {
                Text("Add Memory")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.brandPrimary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Actions

    private func loadMemories() async {
        guard let api = dependencies.apiClient else { isLoading = false; return }
        isLoading = true
        errorMessage = nil
        do {
            memories = try await api.getMemories()
        } catch {
            errorMessage = "Failed to load memories."
        }
        isLoading = false
    }

    private func addMemory() async {
        guard let api = dependencies.apiClient else { return }
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let path = newMemoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let newMemory = try await api.addMemory(
                content: text,
                type: newMemoryType,
                path: path.isEmpty ? nil : path
            )
            withAnimation {
                memories.insert(newMemory, at: 0)
                newMemoryText = ""
                newMemoryType = "user"
                newMemoryPath = ""
                isAddingMemory = false
            }
        } catch {
            errorMessage = "Failed to add memory."
        }
    }

    private func updateMemory(id: String) async {
        guard let api = dependencies.apiClient else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let path = editPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await api.updateMemory(
                id: id,
                content: text,
                type: editType,
                path: path.isEmpty ? "" : path
            )
            if let idx = memories.firstIndex(where: { ($0["id"] as? String) == id }) {
                memories[idx] = updated
            }
            withAnimation { editingMemoryId = nil }
        } catch {
            errorMessage = "Failed to update memory."
        }
    }

    private func deleteMemory(id: String) async {
        guard let api = dependencies.apiClient else { return }
        do {
            try await api.deleteMemory(id: id)
            withAnimation { memories.removeAll { ($0["id"] as? String) == id } }
        } catch {
            errorMessage = "Failed to delete memory."
        }
    }

    private func clearAllMemories() async {
        guard let api = dependencies.apiClient else { return }
        isClearingAll = true
        do {
            try await api.resetMemories()
            withAnimation { memories.removeAll() }
        } catch {
            errorMessage = "Failed to clear memories."
        }
        isClearingAll = false
    }

    private func resetEmbeddings() async {
        guard let api = dependencies.apiClient else { return }
        isResettingEmbeddings = true
        do {
            _ = try await api.resetMemoryEmbeddings()
        } catch {
            errorMessage = "Failed to rebuild index."
        }
        isResettingEmbeddings = false
    }

    private func loadMemoryToggle() async {
        guard let api = dependencies.apiClient else { return }
        isLoadingMemoryToggle = true
        if let settings = try? await api.getUserSettings(),
           let ui = settings["ui"] as? [String: Any],
           let enabled = ui["memory"] as? Bool {
            memoryEnabled = enabled
        }
        isLoadingMemoryToggle = false
    }

    private func updateMemoryToggle(_ enabled: Bool) async {
        guard let api = dependencies.apiClient else { return }
        isLoadingMemoryToggle = true
        // Use merge helper so we ONLY update `memory` without overwriting
        // `models`, `pinnedModels`, or any other ui keys.
        try? await api.mergeUserUISettings(["memory": enabled])
        isLoadingMemoryToggle = false
        // Notify all active ChatViewModels so they update immediately
        // without waiting for the next server fetch on model switch/reload.
        NotificationCenter.default.post(name: .memorySettingChanged, object: enabled)
    }
}

// MARK: - Helper

private extension Dictionary where Key == String, Value == Any {
    var memoryId: String {
        (self["id"] as? String) ?? UUID().uuidString
    }
}
