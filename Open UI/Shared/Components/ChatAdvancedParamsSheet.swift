import SwiftUI

/// A sheet that lets the user set per-chat advanced params and system prompt override.
/// Changes are applied immediately to the bound `ChatAdvancedParams` and saved
/// to the conversation by the caller.
struct ChatAdvancedParamsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @Binding var params: ChatAdvancedParams

    // Local working copy — committed on Save
    @State private var draft: ChatAdvancedParams

    init(params: Binding<ChatAdvancedParams>) {
        self._params = params
        self._draft = State(initialValue: params.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            List {
                systemPromptSection
                basicSection
                samplingSection
                mirostatSection
                repeatSection
                ollamaSection
                reasoningSection
                streamFunctionSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chat Controls")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Sections

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

    /// Generic cycling pill row for a String? that cycles through known values.
    /// nil = Default, values cycle: nil → v1 → v2 → … → nil
    @ViewBuilder
    private func cyclingPillRow(
        label: String,
        value: Binding<String?>,
        states: [(label: String, value: String?)],
        activeColor: Color = .accentColor
    ) -> some View {
        let current = value.wrappedValue
        let currentLabel: String = states.first(where: { $0.value == current })?.label ?? "Default"

        // All states including Default as first entry
        let allStates: [(label: String, value: String?)] = [("Default", nil)] + states
        let currentIdx = allStates.firstIndex(where: { $0.value == current }) ?? 0

        HStack {
            Text(label)
                .font(.body)
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

    /// Generic cycling pill row for a Bool?.
    /// Single pill cycles: Default → Enabled → Disabled → Default
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
            Text(label)
                .font(.body)
            Spacer()
            Button {
                // Cycle: nil (Default) → true (Enabled) → false (Disabled) → nil
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

    /// reasoning_effort row: Default → low → medium → high → cycling
    @ViewBuilder
    private var reasoningEffortRow: some View {
        let states: [(label: String, value: String?)] = [
            ("low",    "low"),
            ("medium", "medium"),
            ("high",   "high"),
        ]
        cyclingPillRow(
            label: "reasoning_effort",
            value: $draft.reasoningEffort,
            states: states
        )
    }

    /// think (Ollama) row: single pill cycling Default → On → Off → Custom → Default
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
                Text("think (Ollama)")
                    .font(.body)
                Spacer()
                // Single pill cycles: Default → On → Off → Custom → Default
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
        cyclingBoolPillRow(
            label: "Stream Response",
            value: $draft.streamResponse,
            onLabel: "Enabled",
            offLabel: "Disabled"
        )
    }

    @ViewBuilder
    private var functionCallingRow: some View {
        let states: [(label: String, value: String?)] = [
            ("Native", "native"),
        ]
        cyclingPillRow(
            label: "Function Calling",
            value: $draft.functionCalling,
            states: states
        )
    }

    // MARK: - Generic param rows

    @ViewBuilder
    private func paramDoubleRow(label: String, value: Binding<Double?>,
                                 range: ClosedRange<Double>, step: Double,
                                 defaultHint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.body)
                Spacer()
                if let v = value.wrappedValue {
                    Text(String(format: step < 0.01 ? "%.3f" : "%.2f", v))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        value.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Default (\(defaultHint))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        value.wrappedValue = Double(defaultHint) ?? range.lowerBound
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let v = value.wrappedValue {
                Slider(
                    value: Binding(get: { v }, set: { value.wrappedValue = ($0 / step).rounded() * step }),
                    in: range,
                    step: step
                )
                .tint(Color.accentColor)
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
                Text(label)
                    .font(.body)
                Spacer()
                if let v = value.wrappedValue {
                    Text("\(v)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        value.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Default (\(defaultHint))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        value.wrappedValue = Int(Double(defaultHint) ?? range.lowerBound)
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let v = value.wrappedValue {
                Slider(
                    value: Binding(
                        get: { Double(v) },
                        set: { value.wrappedValue = Int(($0 / step).rounded() * step) }
                    ),
                    in: range,
                    step: step
                )
                .tint(Color.accentColor)
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
            Text(label)
                .font(.body)
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
