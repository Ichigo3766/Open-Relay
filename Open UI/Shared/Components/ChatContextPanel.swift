import SwiftUI

/// A unified "Controls" sheet that mirrors Open WebUI's Controls panel.
/// Shows attached Files/Knowledge/Chats (with per-item removal), System Prompt, and Advanced Params.
struct ChatContextPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @Bindable var viewModel: ChatViewModel
    @Binding var params: ChatAdvancedParams

    // Local working copy of params — committed on Save
    @State private var draft: ChatAdvancedParams
    @State private var isFilesExpanded: Bool = true
    @State private var isAdvancedExpanded: Bool = false

    init(viewModel: ChatViewModel, params: Binding<ChatAdvancedParams>) {
        self.viewModel = viewModel
        self._params = params
        self._draft = State(initialValue: params.wrappedValue)
    }

    // MARK: - Computed context items

    private var hasAnyContext: Bool {
        !viewModel.chatFiles.isEmpty || !viewModel.selectedKnowledgeItems.isEmpty || !viewModel.selectedReferenceChats.isEmpty
    }

    /// All tools + functions that have user-configurable valves.
    /// Matches OWUI: shows ALL active tools/functions with user valves,
    /// not just the currently selected ones.
    private var valveToolItems: [(id: String, name: String, kind: UserValvesKind)] {
        var items: [(id: String, name: String, kind: UserValvesKind)] = []
        // Tools: all with hasUserValves, exclude server: prefix (matches OWUI filter)
        for tool in viewModel.availableTools
            where tool.hasUserValves && !tool.id.hasPrefix("server:") {
            items.append((id: tool.id, name: tool.name, kind: .tool(tool.id)))
        }
        // Functions: all active functions with user valves
        for fn in viewModel.availableFunctions {
            // Avoid duplicates if a function-tool was already added via availableTools
            if !items.contains(where: { $0.id == fn.id }) {
                items.append((id: fn.id, name: fn.name, kind: .function(fn.id)))
            }
        }
        return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                filesSection
                valvesSection
                systemPromptSection
                advancedSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Load tools + functions so the Valves section can show them.
                // loadTools() is cheap if already loaded (returns after populating availableTools).
                if viewModel.availableTools.isEmpty {
                    await viewModel.loadTools()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        params = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        draft = ChatAdvancedParams()
                    } label: {
                        Label("Reset All", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Files Section

    private var filesSection: some View {
        Section {
            // Disclosure header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFilesExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Files")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isFilesExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isFilesExpanded {
                if !hasAnyContext {
                    Text("No files or knowledge attached")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    // Persistent chat files (from chat.files on server)
                    ForEach(viewModel.chatFiles, id: \.url) { file in
                        let isImage = file.contentType?.hasPrefix("image/") ?? false
                        contextItemRow(
                            icon: isImage ? "photo.fill" : "doc.fill",
                            iconColor: isImage ? .teal : .gray,
                            name: file.name ?? file.url ?? "File",
                            badge: "File"
                        ) {
                            viewModel.removeFile(file)
                        }
                    }
                    // Knowledge items (collections / files)
                    ForEach(viewModel.selectedKnowledgeItems) { item in
                        let isFolder = item.type == .folder
                        let icon: String = isFolder ? "folder.fill" : "books.vertical.fill"
                        let iconColor: Color = isFolder ? .orange : .blue
                        let badge: String = isFolder ? "Folder" : "Collection"
                        contextItemRow(
                            icon: icon,
                            iconColor: iconColor,
                            name: item.name,
                            badge: badge
                        ) {
                            viewModel.removeKnowledgeItem(item)
                        }
                    }
                    // Reference chats
                    ForEach(viewModel.selectedReferenceChats) { chat in
                        contextItemRow(
                            icon: "bubble.left.and.bubble.right.fill",
                            iconColor: .purple,
                            name: chat.title,
                            badge: "Chat"
                        ) {
                            viewModel.removeReferenceChat(chat)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Valves Section
    // Matches OWUI: picker (type + name) → inline form with debounce-save
    // Collapsed by default (matches `getOpen('valves', false)` in OWUI)

    @State private var valveTab: ValveTab = .tools
    @State private var valveSelectedId: String = ""

    enum ValveTab: String, CaseIterable {
        case tools = "Tools"
        case functions = "Functions"
    }

    /// All active tools (excluding server: prefix), matching OWUI which shows every tool in the picker.
    private var valveToolsList: [(id: String, name: String)] {
        viewModel.availableTools
            .filter { !$0.id.hasPrefix("server:") }
            .map { (id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// All active functions, matching OWUI which shows every function in the picker.
    private var valveFunctionsList: [(id: String, name: String)] {
        viewModel.availableFunctions
            .map { (id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Show the Valves section whenever any tools or functions are loaded — mirrors OWUI exactly.
    private var hasAnyValves: Bool {
        !viewModel.availableTools.filter { !$0.id.hasPrefix("server:") }.isEmpty
            || !viewModel.availableFunctions.isEmpty
    }

    @ViewBuilder
    private var valvesSection: some View {
        // Always show Valves section — show spinner while tools are loading (mirrors OWUI)
        Section {
            if viewModel.isLoadingTools {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else if hasAnyValves {
                // Two styled select boxes side-by-side — mirrors OWUI's two <select> layout
                HStack(spacing: 8) {
                    // Type picker (Tools / Functions)
                    Menu {
                        ForEach(ValveTab.allCases, id: \.self) { tab in
                            Button {
                                if valveTab != tab {
                                    valveTab = tab
                                    valveSelectedId = ""
                                }
                            } label: {
                                HStack {
                                    Text(tab.rawValue)
                                    if valveTab == tab { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(valveTab.rawValue)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                        )
                    }
                    .menuOrder(.fixed)
                    .frame(minWidth: 100, maxWidth: 130)

                    // Name picker
                    let currentList = valveTab == .tools ? valveToolsList : valveFunctionsList
                    Menu {
                        Button {
                            valveSelectedId = ""
                        } label: {
                            HStack {
                                Text(valveTab == .tools ? "Select a tool" : "Select a function")
                                    .foregroundStyle(.secondary)
                                if valveSelectedId.isEmpty { Image(systemName: "checkmark") }
                            }
                        }
                        ForEach(currentList, id: \.id) { item in
                            Button {
                                valveSelectedId = item.id
                            } label: {
                                HStack {
                                    Text(item.name)
                                    if valveSelectedId == item.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentList.first(where: { $0.id == valveSelectedId })?.name
                                 ?? (valveTab == .tools ? "Select a tool" : "Select a function"))
                                .font(.subheadline)
                                .foregroundStyle(valveSelectedId.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                        )
                    }
                    .menuOrder(.fixed)
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 2)

                // Inline valves form — shown when an item is selected
                if !valveSelectedId.isEmpty {
                    let kind: UserValvesKind = valveTab == .tools
                        ? .tool(valveSelectedId)
                        : .function(valveSelectedId)
                    InlineValvesForm(kind: kind)
                        .id(valveSelectedId) // re-create on selection change
                }
            } else {
                Text("No tools or functions available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        } header: {
            Text("Valves")
        }
    }

    @ViewBuilder
    private func contextItemRow(
        icon: String,
        iconColor: Color,
        name: String,
        badge: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Haptics.play(.light)
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if draft.systemPrompt?.isEmpty ?? true {
                    Text("Override system prompt for this chat…")
                        .foregroundStyle(.secondary)
                        .font(.body)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { draft.systemPrompt ?? "" },
                    set: { draft.systemPrompt = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 80)
            }
        } header: {
            Text("System Prompt")
        } footer: {
            Text("Overrides the model's default system prompt for this chat only.")
        }
    }

    // MARK: - Advanced Params Section (collapsed by default)

    @ViewBuilder
    private var advancedSection: some View {
        // Disclosure toggle row in its own section
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAdvancedExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced Params")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isAdvancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        if isAdvancedExpanded {
            basicSection
            samplingSection
            mirostatSection
            repeatSection
            ollamaSection
            reasoningSection
            streamFunctionSection
        }
    }

    // MARK: - Advanced Param sections (copied from ChatAdvancedParamsSheet)

    private var basicSection: some View {
        Section("Basic") {
            paramDoubleRow(label: "Temperature", value: $draft.temperature,
                           range: 0...2, step: 0.05, defaultHint: "0.8")
            paramIntRow(label: "Max Tokens", value: $draft.maxTokens,
                        range: -1...131072, step: 1, defaultHint: "-1")
            paramOptionalIntRow(label: "Seed", value: $draft.seed,
                                range: 0...9_999_999, step: 1, defaultHint: "Random")
        }
    }

    private var samplingSection: some View {
        Section("Sampling") {
            paramIntRow(label: "top_k", value: $draft.topK,
                        range: 0...1000, step: 1, defaultHint: "40")
            paramDoubleRow(label: "top_p", value: $draft.topP,
                           range: 0...1, step: 0.05, defaultHint: "0.9")
            paramDoubleRow(label: "min_p", value: $draft.minP,
                           range: 0...1, step: 0.05, defaultHint: "0.0")
            paramDoubleRow(label: "frequency_penalty", value: $draft.frequencyPenalty,
                           range: -2...2, step: 0.05, defaultHint: "1.1")
            paramDoubleRow(label: "presence_penalty", value: $draft.presencePenalty,
                           range: -2...2, step: 0.05, defaultHint: "0.0")
        }
    }

    private var mirostatSection: some View {
        Section("Mirostat") {
            paramIntRow(label: "mirostat", value: $draft.mirostat,
                        range: 0...2, step: 1, defaultHint: "0")
            paramDoubleRow(label: "mirostat_eta", value: $draft.mirostatEta,
                           range: 0...1, step: 0.01, defaultHint: "0.1")
            paramDoubleRow(label: "mirostat_tau", value: $draft.mirostatTau,
                           range: 0...10, step: 0.1, defaultHint: "5.0")
        }
    }

    private var repeatSection: some View {
        Section("Repeat / Tail-Free") {
            paramIntRow(label: "repeat_last_n", value: $draft.repeatLastN,
                        range: -1...128, step: 1, defaultHint: "64")
            paramDoubleRow(label: "tfs_z", value: $draft.tfsZ,
                           range: 0...2, step: 0.05, defaultHint: "1.0")
            paramDoubleRow(label: "repeat_penalty", value: $draft.repeatPenalty,
                           range: -2...2, step: 0.05, defaultHint: "1.1")
        }
    }

    private var ollamaSection: some View {
        Section("Ollama") {
            paramIntRow(label: "num_keep", value: $draft.numKeep,
                        range: -1...10_240_000, step: 1, defaultHint: "24")
            paramIntRow(label: "num_ctx", value: $draft.numCtx,
                        range: -1...10_240_000, step: 1, defaultHint: "2048")
            paramIntRow(label: "num_batch", value: $draft.numBatch,
                        range: 256...8192, step: 256, defaultHint: "512")
            thinkRow
            paramTextRow(label: "format", value: $draft.format, placeholder: "e.g. json")
        }
    }

    private var reasoningSection: some View {
        Section("Reasoning") {
            reasoningEffortRow
        }
    }

    private var streamFunctionSection: some View {
        Section("Streaming & Function Calling") {
            streamResponseRow
            functionCallingRow
        }
    }

    // MARK: - Cycling Pill Rows

    @ViewBuilder
    private func cyclingPillRow(
        label: String,
        value: Binding<String?>,
        states: [(label: String, value: String?)],
        activeColor: Color = .accentColor
    ) -> some View {
        let current = value.wrappedValue
        let currentLabel: String = states.first(where: { $0.value == current })?.label ?? "Default"
        let allStates: [(label: String, value: String?)] = [("Default", nil)] + states
        let currentIdx = allStates.firstIndex(where: { $0.value == current }) ?? 0

        HStack {
            Text(label).font(.body)
            Spacer()
            Button {
                let nextIdx = (currentIdx + 1) % allStates.count
                value.wrappedValue = allStates[nextIdx].value
                Haptics.play(.light)
            } label: {
                Text(currentLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(activeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(activeColor.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(activeColor.opacity(0.35), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func cyclingBoolPillRow(
        label: String,
        value: Binding<Bool?>,
        onLabel: String = "Enabled",
        offLabel: String = "Disabled",
        activeColor: Color = .accentColor
    ) -> some View {
        let current = value.wrappedValue
        let currentLabel: String = {
            switch current {
            case .some(true): return onLabel
            case .some(false): return offLabel
            case .none: return "Default"
            }
        }()

        HStack {
            Text(label).font(.body)
            Spacer()
            Button {
                switch current {
                case .none:        value.wrappedValue = true
                case .some(true):  value.wrappedValue = false
                case .some(false): value.wrappedValue = nil
                }
                Haptics.play(.light)
            } label: {
                Text(currentLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(activeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(activeColor.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(activeColor.opacity(0.35), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Special rows

    @ViewBuilder
    private var reasoningEffortRow: some View {
        let presets: [String] = ["low", "medium", "high", "xhigh"]
        let current = draft.reasoningEffort
        let isCustom = current != nil && !presets.contains(current!)

        let currentLabel: String = {
            if current == nil { return "Default" }
            if presets.contains(current!) { return current! }
            return "Custom"
        }()

        HStack {
            Text("reasoning_effort").font(.body)
            Spacer()
            Button {
                let next: String?
                if current == nil { next = "low" }
                else if current == "low" { next = "medium" }
                else if current == "medium" { next = "high" }
                else if current == "high" { next = "xhigh" }
                else if current == "xhigh" { next = "" }
                else { next = nil }
                draft.reasoningEffort = next
                Haptics.play(.light)
            } label: {
                Text(currentLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }

        if isCustom || current == "" {
            HStack {
                Text("Custom value").font(.body).foregroundStyle(.secondary)
                Spacer()
                TextField("e.g. auto, xhigh…", text: Binding(
                    get: { draft.reasoningEffort ?? "" },
                    set: { draft.reasoningEffort = $0 }
                ))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 200)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var thinkRow: some View {
        let current = draft.thinkMode
        let isCustom: Bool = {
            if case .custom = current { return true }
            return false
        }()

        let currentLabel: String = {
            switch current {
            case .default:       return "Default"
            case .on:            return "On"
            case .off:           return "Off"
            case .custom(let s): return s.isEmpty ? "Custom" : s
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("think (Ollama)").font(.body)
                Spacer()
                Button {
                    switch draft.thinkMode {
                    case .default: draft.thinkMode = .on
                    case .on:      draft.thinkMode = .off
                    case .off:     draft.thinkMode = .custom(draft.thinkCustom ?? "")
                    case .custom:  draft.thinkMode = .default
                    }
                    Haptics.play(.light)
                } label: {
                    Text(currentLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
            if isCustom {
                TextField("budget string, e.g. medium", text: Binding(
                    get: { draft.thinkCustom ?? "" },
                    set: {
                        draft.thinkCustom = $0
                        draft.thinkMode = .custom($0)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var streamResponseRow: some View {
        cyclingBoolPillRow(label: "Stream Response", value: $draft.streamResponse,
                           onLabel: "Enabled", offLabel: "Disabled")
    }

    @ViewBuilder
    private var functionCallingRow: some View {
        cyclingPillRow(
            label: "Function Calling",
            value: $draft.functionCalling,
            states: [("Native", "native")]
        )
    }

    // MARK: - Generic param rows

    @ViewBuilder
    private func paramDoubleRow(label: String, value: Binding<Double?>,
                                 range: ClosedRange<Double>, step: Double,
                                 defaultHint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.body)
                Spacer()
                if let v = value.wrappedValue {
                    Text(String(format: step < 0.01 ? "%.3f" : "%.2f", v))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { value.wrappedValue = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                } else {
                    Text("Default (\(defaultHint))").font(.caption).foregroundStyle(.secondary)
                    Button { value.wrappedValue = Double(defaultHint) ?? range.lowerBound } label: {
                        Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                    }.buttonStyle(.plain)
                }
            }
            if let v = value.wrappedValue {
                Slider(
                    value: Binding(get: { v }, set: { value.wrappedValue = ($0 / step).rounded() * step }),
                    in: range, step: step
                ).tint(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func paramIntRow(label: String, value: Binding<Int?>,
                              range: ClosedRange<Double>, step: Double,
                              defaultHint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.body)
                Spacer()
                if let v = value.wrappedValue {
                    Text("\(v)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { value.wrappedValue = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                } else {
                    Text("Default (\(defaultHint))").font(.caption).foregroundStyle(.secondary)
                    Button { value.wrappedValue = Int(Double(defaultHint) ?? range.lowerBound) } label: {
                        Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                    }.buttonStyle(.plain)
                }
            }
            if let v = value.wrappedValue {
                Slider(
                    value: Binding(
                        get: { Double(v) },
                        set: { value.wrappedValue = Int(($0 / step).rounded() * step) }
                    ),
                    in: range, step: step
                ).tint(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func paramOptionalIntRow(label: String, value: Binding<Int?>,
                                      range: ClosedRange<Double>, step: Double,
                                      defaultHint: String) -> some View {
        paramIntRow(label: label, value: value, range: range, step: step, defaultHint: defaultHint)
    }

    @ViewBuilder
    private func paramTextRow(label: String, value: Binding<String?>, placeholder: String) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            TextField(placeholder, text: Binding(
                get: { value.wrappedValue ?? "" },
                set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
            ))
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 160)
        }
    }
}
