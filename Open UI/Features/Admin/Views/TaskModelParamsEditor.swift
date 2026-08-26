import SwiftUI

// MARK: - Task Model Params Editor
//
// Replicates open-webui's AdvancedParams.svelte for Task Model Parameters in Admin → Interface.
// Each parameter row shows "Default" when absent from dict and cycles to a custom value on tap.
// Only active keys are included in the dict — matches web `configuredParams()` stripping nulls.

struct TaskModelParamsEditor: View {

    @Binding var params: [String: Any]
    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    // MARK: Dict helpers

    private func has(_ k: String) -> Bool { params[k] != nil }
    private func remove(_ k: String) { params.removeValue(forKey: k) }
    private func setD(_ k: String, _ v: Double) { params[k] = v }
    private func setI(_ k: String, _ v: Int)    { params[k] = v }
    private func setS(_ k: String, _ v: String) { params[k] = v }
    private func setB(_ k: String, _ v: Bool)   { params[k] = v }
    private func getD(_ k: String, _ d: Double) -> Double {
        if let v = params[k] as? Double { return v }
        if let v = params[k] as? Int    { return Double(v) }
        return d
    }
    private func getI(_ k: String, _ d: Int) -> Int {
        if let v = params[k] as? Int    { return v }
        if let v = params[k] as? Double { return Int(v) }
        return d
    }
    private func getS(_ k: String, _ d: String) -> String { params[k] as? String ?? d }
    private func getB(_ k: String, _ d: Bool) -> Bool     { params[k] as? Bool ?? d }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Collapsible header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text("Task Model Parameters")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Text(isExpanded ? "Close" : "Configure")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.chatBubblePadding)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Group {
                    sep; streamResponseRow
                    sep; streamDeltaChunkSizeRow
                    sep; compactTokenThresholdRow
                    sep; functionCallingRow
                    sep; reasoningTagsRow
                    sep; seedRow
                    sep; stopSequenceRow
                    sep; temperatureRow
                    sep; reasoningEffortRow
                    sep; logitBiasRow
                    sep; maxTokensRow
                    sep; topKRow
                }
                Group {
                    sep; topPRow
                    sep; minPRow
                    sep; frequencyPenaltyRow
                    sep; presencePenaltyRow
                    sep; mirostatRow
                    sep; mirostatEtaRow
                    sep; mirostatTauRow
                    sep; repeatLastNRow
                    sep; tfszRow
                    sep; repeatPenaltyRow
                    sep; numKeepRow
                    sep; numCtxRow
                    sep; numBatchRow
                }
                Group {
                    sep; useMmapRow
                    sep; useMlockRow
                    sep; thinkRow
                    sep; formatRow
                    sep; numThreadRow
                    sep; numGpuRow
                    sep; keepAliveRow
                }
            }
        }
    }

    private var sep: some View {
        Divider().padding(.leading, Spacing.md)
    }


    // MARK: - Row builder

    @ViewBuilder
    private func paramRow<C: View>(
        label: String, valueLabel: String, isActive: Bool,
        onTap: @escaping () -> Void, @ViewBuilder content: () -> C
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button(action: onTap) {
                    Text(valueLabel)
                        .scaledFont(size: 13)
                        .foregroundStyle(isActive ? theme.accentColor : theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if isActive {
                content()
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.chatBubblePadding)
            }
        }
    }

    // MARK: - Input controls

    @ViewBuilder
    private func sliderRow(key: String, min: Double, max: Double, step: Double) -> some View {
        HStack(spacing: 10) {
            Slider(value: Binding(
                get: { getD(key, (min + max) / 2) },
                set: { setD(key, $0) }
            ), in: min...max, step: step)
            .tint(theme.accentColor)
            TextField("", value: Binding(
                get: { getD(key, (min + max) / 2) },
                set: { setD(key, Swift.max(min, Swift.min(max, $0))) }
            ), format: .number)
            .scaledFont(size: 13).multilineTextAlignment(.center).keyboardType(.decimalPad)
            .frame(width: 56)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(theme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.inputBorder, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func intSliderRow(key: String, min: Int, max: Int) -> some View {
        HStack(spacing: 10) {
            Slider(value: Binding(
                get: { Double(getI(key, (min + max) / 2)) },
                set: { setI(key, Int($0)) }
            ), in: Double(min)...Double(max), step: 1)
            .tint(theme.accentColor)
            TextField("", value: Binding(
                get: { getI(key, (min + max) / 2) },
                set: { setI(key, Swift.max(min, Swift.min(max, $0))) }
            ), format: .number)
            .scaledFont(size: 13).multilineTextAlignment(.center).keyboardType(.numberPad)
            .frame(width: 56)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(theme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.inputBorder, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func textInput(key: String, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: Binding(get: { getS(key, "") }, set: { setS(key, $0) }))
            .scaledFont(size: 13).foregroundStyle(theme.textPrimary)
            .keyboardType(keyboard).autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(theme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.inputBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private func intInput(key: String, placeholder: String) -> some View {
        TextField(placeholder, value: Binding(get: { getI(key, 0) }, set: { setI(key, $0) }), format: .number)
            .scaledFont(size: 13).foregroundStyle(theme.textPrimary).keyboardType(.numberPad)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(theme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.inputBorder, lineWidth: 0.5))
    }


    // MARK: - Param rows (Part 1: stream, function, reasoning)

    private var streamResponseRow: some View {
        let raw = params["stream_response"] as? Bool
        let lbl = raw == nil ? "Default" : (raw == true ? "On" : "Off")
        return paramRow(label: "Stream Chat Response", valueLabel: lbl, isActive: raw != nil, onTap: {
            if raw == nil { params["stream_response"] = true }
            else if raw == true { params["stream_response"] = false }
            else { params.removeValue(forKey: "stream_response") }
        }, content: { EmptyView() })
    }

    private var streamDeltaChunkSizeRow: some View {
        paramRow(label: "Stream Delta Chunk Size", valueLabel: has("stream_delta_chunk_size") ? "Custom" : "Default",
            isActive: has("stream_delta_chunk_size"),
            onTap: { has("stream_delta_chunk_size") ? remove("stream_delta_chunk_size") : setI("stream_delta_chunk_size",1) },
            content: { intSliderRow(key: "stream_delta_chunk_size", min: 1, max: 128) })
    }

    private var compactTokenThresholdRow: some View {
        paramRow(label: "Context Compaction Threshold", valueLabel: has("compact_token_threshold") ? "Custom" : "Default",
            isActive: has("compact_token_threshold"),
            onTap: { has("compact_token_threshold") ? remove("compact_token_threshold") : setI("compact_token_threshold",80000) },
            content: { intInput(key: "compact_token_threshold", placeholder: "Token threshold") })
    }

    private var functionCallingRow: some View {
        let v = params["function_calling"] as? String
        let lbl = v == "native" ? "Native" : (v == "legacy" ? "Legacy" : "Default")
        return paramRow(label: "Function Calling", valueLabel: lbl, isActive: v != nil, onTap: {
            if v == nil { params["function_calling"] = "native" }
            else if v == "native" { params["function_calling"] = "legacy" }
            else { params.removeValue(forKey: "function_calling") }
        }, content: { EmptyView() })
    }

    private var reasoningTagsRow: some View {
        let raw = params["reasoning_tags"]
        let isBT = raw as? Bool == true
        let iBF  = raw as? Bool == false
        let isArr = raw is [String]
        let lbl = raw == nil ? "Default" : (isBT ? "Enabled" : (iBF ? "Disabled" : "Custom"))
        return paramRow(label: "Reasoning Tags", valueLabel: lbl, isActive: raw != nil, onTap: {
            if raw == nil { params["reasoning_tags"] = ["",""] }
            else if isArr { params["reasoning_tags"] = true }
            else if isBT  { params["reasoning_tags"] = false }
            else          { params.removeValue(forKey: "reasoning_tags") }
        }, content: {
            if let arr = raw as? [String] {
                HStack(spacing: 8) {
                    TextField("Start Tag", text: Binding(
                        get: { arr.count > 0 ? arr[0] : "" },
                        set: { v in var a = (params["reasoning_tags"] as? [String]) ?? ["",""]; while a.count < 2 { a.append("") }; a[0]=v; params["reasoning_tags"]=a }
                    )).scaledFont(size: 13).padding(.horizontal, 8).padding(.vertical, 6)
                    .background(theme.inputBackground).clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.inputBorder, lineWidth: 0.5))

                    TextField("End Tag", text: Binding(
                        get: { arr.count > 1 ? arr[1] : "" },
                        set: { v in var a = (params["reasoning_tags"] as? [String]) ?? ["",""]; while a.count < 2 { a.append("") }; a[1]=v; params["reasoning_tags"]=a }
                    )).scaledFont(size: 13).padding(.horizontal, 8).padding(.vertical, 6)
                    .background(theme.inputBackground).clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.inputBorder, lineWidth: 0.5))
                }
            } else { EmptyView() }
        })
    }


    // MARK: - Param rows (Part 2: seed through top_k)

    private var seedRow: some View {
        paramRow(label: "Seed", valueLabel: has("seed") ? "Custom" : "Default", isActive: has("seed"),
            onTap: { has("seed") ? remove("seed") : setI("seed",0) },
            content: { intInput(key: "seed", placeholder: "Enter seed") })
    }
    private var stopSequenceRow: some View {
        paramRow(label: "Stop Sequence", valueLabel: has("stop") ? "Custom" : "Default", isActive: has("stop"),
            onTap: { has("stop") ? remove("stop") : setS("stop","") },
            content: { textInput(key: "stop", placeholder: "Enter stop sequence") })
    }
    private var temperatureRow: some View {
        paramRow(label: "Temperature", valueLabel: has("temperature") ? "Custom" : "Default", isActive: has("temperature"),
            onTap: { has("temperature") ? remove("temperature") : setD("temperature",0.8) },
            content: { sliderRow(key: "temperature", min: 0, max: 2, step: 0.05) })
    }
    private var reasoningEffortRow: some View {
        paramRow(label: "Reasoning Effort", valueLabel: has("reasoning_effort") ? "Custom" : "Default", isActive: has("reasoning_effort"),
            onTap: { has("reasoning_effort") ? remove("reasoning_effort") : setS("reasoning_effort","medium") },
            content: { textInput(key: "reasoning_effort", placeholder: "e.g. low, medium, high") })
    }
    private var logitBiasRow: some View {
        paramRow(label: "logit_bias", valueLabel: has("logit_bias") ? "Custom" : "Default", isActive: has("logit_bias"),
            onTap: { has("logit_bias") ? remove("logit_bias") : setS("logit_bias","") },
            content: { textInput(key: "logit_bias", placeholder: "e.g. 5432:100, 413:-100") })
    }
    private var maxTokensRow: some View {
        paramRow(label: "max_tokens", valueLabel: has("max_tokens") ? "Custom" : "Default", isActive: has("max_tokens"),
            onTap: { has("max_tokens") ? remove("max_tokens") : setI("max_tokens",128) },
            content: { intSliderRow(key: "max_tokens", min: 1, max: 131072) })
    }
    private var topKRow: some View {
        paramRow(label: "top_k", valueLabel: has("top_k") ? "Custom" : "Default", isActive: has("top_k"),
            onTap: { has("top_k") ? remove("top_k") : setI("top_k",40) },
            content: { intSliderRow(key: "top_k", min: 0, max: 1000) })
    }
    private var topPRow: some View {
        paramRow(label: "top_p", valueLabel: has("top_p") ? "Custom" : "Default", isActive: has("top_p"),
            onTap: { has("top_p") ? remove("top_p") : setD("top_p",0.9) },
            content: { sliderRow(key: "top_p", min: 0, max: 1, step: 0.05) })
    }
    private var minPRow: some View {
        paramRow(label: "min_p", valueLabel: has("min_p") ? "Custom" : "Default", isActive: has("min_p"),
            onTap: { has("min_p") ? remove("min_p") : setD("min_p",0.0) },
            content: { sliderRow(key: "min_p", min: 0, max: 1, step: 0.05) })
    }
    private var frequencyPenaltyRow: some View {
        paramRow(label: "frequency_penalty", valueLabel: has("frequency_penalty") ? "Custom" : "Default", isActive: has("frequency_penalty"),
            onTap: { has("frequency_penalty") ? remove("frequency_penalty") : setD("frequency_penalty",1.1) },
            content: { sliderRow(key: "frequency_penalty", min: -2, max: 2, step: 0.05) })
    }
    private var presencePenaltyRow: some View {
        paramRow(label: "presence_penalty", valueLabel: has("presence_penalty") ? "Custom" : "Default", isActive: has("presence_penalty"),
            onTap: { has("presence_penalty") ? remove("presence_penalty") : setD("presence_penalty",0.0) },
            content: { sliderRow(key: "presence_penalty", min: -2, max: 2, step: 0.05) })
    }
    private var mirostatRow: some View {
        paramRow(label: "mirostat", valueLabel: has("mirostat") ? "Custom" : "Default", isActive: has("mirostat"),
            onTap: { has("mirostat") ? remove("mirostat") : setI("mirostat",0) },
            content: { intSliderRow(key: "mirostat", min: 0, max: 2) })
    }
    private var mirostatEtaRow: some View {
        paramRow(label: "mirostat_eta", valueLabel: has("mirostat_eta") ? "Custom" : "Default", isActive: has("mirostat_eta"),
            onTap: { has("mirostat_eta") ? remove("mirostat_eta") : setD("mirostat_eta",0.1) },
            content: { sliderRow(key: "mirostat_eta", min: 0, max: 1, step: 0.05) })
    }
    private var mirostatTauRow: some View {
        paramRow(label: "mirostat_tau", valueLabel: has("mirostat_tau") ? "Custom" : "Default", isActive: has("mirostat_tau"),
            onTap: { has("mirostat_tau") ? remove("mirostat_tau") : setD("mirostat_tau",5.0) },
            content: { sliderRow(key: "mirostat_tau", min: 0, max: 10, step: 0.1) })
    }
    private var repeatLastNRow: some View {
        paramRow(label: "repeat_last_n", valueLabel: has("repeat_last_n") ? "Custom" : "Default", isActive: has("repeat_last_n"),
            onTap: { has("repeat_last_n") ? remove("repeat_last_n") : setI("repeat_last_n",64) },
            content: { intSliderRow(key: "repeat_last_n", min: 0, max: 256) })
    }
    private var tfszRow: some View {
        paramRow(label: "tfs_z", valueLabel: has("tfs_z") ? "Custom" : "Default", isActive: has("tfs_z"),
            onTap: { has("tfs_z") ? remove("tfs_z") : setD("tfs_z",1.0) },
            content: { sliderRow(key: "tfs_z", min: 0, max: 1, step: 0.05) })
    }
    private var repeatPenaltyRow: some View {
        paramRow(label: "repeat_penalty", valueLabel: has("repeat_penalty") ? "Custom" : "Default", isActive: has("repeat_penalty"),
            onTap: { has("repeat_penalty") ? remove("repeat_penalty") : setD("repeat_penalty",1.1) },
            content: { sliderRow(key: "repeat_penalty", min: 0, max: 2, step: 0.05) })
    }


    // MARK: - Param rows (Part 3: Ollama params + closing brace)

    private var numKeepRow: some View {
        paramRow(label: "num_keep (Ollama)", valueLabel: has("num_keep") ? "Custom" : "Default", isActive: has("num_keep"),
            onTap: { has("num_keep") ? remove("num_keep") : setI("num_keep",24) },
            content: { intInput(key: "num_keep", placeholder: "e.g. 24") })
    }
    private var numCtxRow: some View {
        paramRow(label: "num_ctx (Ollama)", valueLabel: has("num_ctx") ? "Custom" : "Default", isActive: has("num_ctx"),
            onTap: { has("num_ctx") ? remove("num_ctx") : setI("num_ctx",2048) },
            content: { intInput(key: "num_ctx", placeholder: "e.g. 2048, 4096") })
    }
    private var numBatchRow: some View {
        paramRow(label: "num_batch (Ollama)", valueLabel: has("num_batch") ? "Custom" : "Default", isActive: has("num_batch"),
            onTap: { has("num_batch") ? remove("num_batch") : setI("num_batch",512) },
            content: { intInput(key: "num_batch", placeholder: "e.g. 512") })
    }
    private var useMmapRow: some View {
        paramRow(label: "use_mmap (Ollama)", valueLabel: has("use_mmap") ? "Custom" : "Default", isActive: has("use_mmap"),
            onTap: { has("use_mmap") ? remove("use_mmap") : setB("use_mmap",true) },
            content: {
                HStack {
                    Text(getB("use_mmap",false) ? "Enabled" : "Disabled").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { getB("use_mmap",false) }, set: { setB("use_mmap",$0) })).labelsHidden().tint(theme.accentColor)
                }
            })
    }
    private var useMlockRow: some View {
        paramRow(label: "use_mlock (Ollama)", valueLabel: has("use_mlock") ? "Custom" : "Default", isActive: has("use_mlock"),
            onTap: { has("use_mlock") ? remove("use_mlock") : setB("use_mlock",true) },
            content: {
                HStack {
                    Text(getB("use_mlock",false) ? "Enabled" : "Disabled").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { getB("use_mlock",false) }, set: { setB("use_mlock",$0) })).labelsHidden().tint(theme.accentColor)
                }
            })
    }
    // think: null → true → "medium" string → false → null
    private var thinkRow: some View {
        let raw = params["think"]
        let isBT = raw as? Bool == true
        let isStr = raw is String
        let lbl = raw == nil ? "Default" : (isBT ? "On" : ((raw as? Bool == false) ? "Off" : "Custom"))
        return paramRow(label: "think (Ollama)", valueLabel: lbl, isActive: raw != nil, onTap: {
            if raw == nil { params["think"] = true }
            else if isBT  { params["think"] = "medium" }
            else if isStr { params["think"] = false }
            else          { params.removeValue(forKey: "think") }
        }, content: {
            if isStr { textInput(key: "think", placeholder: "e.g. low, medium, high") } else { EmptyView() }
        })
    }
    private var formatRow: some View {
        paramRow(label: "format (Ollama)", valueLabel: has("format") ? "JSON" : "Default", isActive: has("format"),
            onTap: { has("format") ? remove("format") : setS("format","json") },
            content: { textInput(key: "format", placeholder: "\"json\" or a JSON schema") })
    }
    private var numThreadRow: some View {
        paramRow(label: "num_thread (Ollama)", valueLabel: has("num_thread") ? "Custom" : "Default", isActive: has("num_thread"),
            onTap: { has("num_thread") ? remove("num_thread") : setI("num_thread",2) },
            content: { intSliderRow(key: "num_thread", min: 1, max: 256) })
    }
    private var numGpuRow: some View {
        paramRow(label: "num_gpu (Ollama)", valueLabel: has("num_gpu") ? "Custom" : "Default", isActive: has("num_gpu"),
            onTap: { has("num_gpu") ? remove("num_gpu") : setI("num_gpu",0) },
            content: { intSliderRow(key: "num_gpu", min: 0, max: 256) })
    }
    private var keepAliveRow: some View {
        paramRow(label: "keep_alive (Ollama)", valueLabel: has("keep_alive") ? "Custom" : "Default", isActive: has("keep_alive"),
            onTap: { has("keep_alive") ? remove("keep_alive") : setS("keep_alive","5m") },
            content: { textInput(key: "keep_alive", placeholder: "e.g. 30s, 10m, 1h") })
    }
}

