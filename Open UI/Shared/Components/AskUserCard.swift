import SwiftUI

// MARK: - Ask User Data Models

struct AskUserOption: Sendable {
    let label: String
    let description: String
}

struct AskUserQuestion: Sendable {
    let id: String
    let header: String
    let question: String
    let options: [AskUserOption]
    let allowOther: Bool
}

/// A single answer — predefined option or free-text.
enum AskUserAnswerDraft: Sendable {
    case option(index: Int, label: String, description: String)
    case other(text: String)

    /// Converts to the server-expected dict format for the resolve endpoint.
    func toServerPayload() -> [String: Any] {
        switch self {
        case .option(let idx, let label, let desc):
            return ["type": "option", "option_index": idx, "label": label, "description": desc]
        case .other(let text):
            return ["type": "other", "text": text]
        }
    }
}

/// Parsed pending ask_user prompt, ready for the card UI.
struct PendingAskUserPrompt {
    let messageId: String
    let callId: String
    let questions: [AskUserQuestion]
    let allowOther: Bool
    let timeoutMs: Int?

    static func fromInfo(_ info: MessageHistory.PendingAskUserInfo) -> PendingAskUserPrompt? {
        guard let questionsArr = info.arguments["questions"] as? [[String: Any]],
              !questionsArr.isEmpty else { return nil }
        let globalAllowOther = info.arguments["allow_other"] as? Bool ?? true
        let timeoutMs = info.arguments["timeout_ms"] as? Int
        let parsed: [AskUserQuestion] = questionsArr.compactMap { qDict -> AskUserQuestion? in
            guard let id = qDict["id"] as? String, !id.isEmpty,
                  let qText = qDict["question"] as? String, !qText.isEmpty,
                  let optionsArr = qDict["options"] as? [[String: Any]] else { return nil }
            let options: [AskUserOption] = optionsArr.compactMap { o -> AskUserOption? in
                guard let lbl = o["label"] as? String, !lbl.isEmpty,
                      let desc = o["description"] as? String else { return nil }
                return AskUserOption(label: lbl, description: desc)
            }
            guard !options.isEmpty else { return nil }
            return AskUserQuestion(
                id: id,
                header: qDict["header"] as? String ?? "",
                question: qText,
                options: options,
                allowOther: qDict["allow_other"] as? Bool ?? globalAllowOther
            )
        }
        guard !parsed.isEmpty else { return nil }
        return PendingAskUserPrompt(
            messageId: info.messageId, callId: info.callId,
            questions: parsed, allowOther: globalAllowOther, timeoutMs: timeoutMs
        )
    }
}

// MARK: - AskUserCard View

struct AskUserCard: View {
    let questions: [AskUserQuestion]
    var allowOther: Bool = true
    var timeoutMs: Int?
    var onSubmit: ([String: AskUserAnswerDraft]) -> Void
    var onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var answers: [String: AskUserAnswerDraft] = [:]
    @State private var questionIndex: Int = 0
    @State private var timeRemaining: Int? = nil
    @State private var timerTask: Task<Void, Never>? = nil

    private var question: AskUserQuestion? {
        guard questionIndex < questions.count else { return nil }
        return questions[questionIndex]
    }

    private var isComplete: Bool {
        questions.allSatisfy { q in
            guard let a = answers[q.id] else { return false }
            if case .other(let t) = a { return !t.trimmingCharacters(in: .whitespaces).isEmpty }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.inputBorder).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                if let q = question {
                    Text(q.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(q.id)
                    optionsSection(for: q)
                }
                navigationRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.inputBackground)
        }
        .onAppear { startTimer() }
        .onDisappear { timerTask?.cancel() }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }

    // MARK: - Header

    @ViewBuilder private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if questions.count > 1 {
                Text("\(questionIndex + 1) / \(questions.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(theme.surfaceContainer))
            }
            if let hdr = question?.header, !hdr.isEmpty {
                Text(hdr).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textPrimary)
            }
            Spacer()
            if let rem = timeRemaining {
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text("\(rem)s").font(.system(size: 11, weight: .medium))
                }.foregroundStyle(rem <= 10 ? theme.error : theme.textTertiary)
            }
            Button(action: { timerTask?.cancel(); onCancel() }) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.surfaceContainer))
            }.buttonStyle(.plain).accessibilityLabel("Cancel")
        }
    }


    // MARK: - Options section

    @ViewBuilder private func optionsSection(for q: AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { idx, opt in
                optionRow(for: q, option: opt, index: idx)
            }
            if q.allowOther || allowOther { otherRow(for: q) }
        }
    }

    @ViewBuilder private func optionRow(for q: AskUserQuestion, option: AskUserOption, index: Int) -> some View {
        let isSelected: Bool = {
            if case .option(let i,_,_) = answers[q.id] { return i == index }
            return false
        }()
        Button(action: { selectOption(q: q, option: option, index: index) }) {
            HStack(spacing: 8) {
                Text(String(UnicodeScalar(65 + index)!))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? theme.buttonPrimaryText : theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isSelected ? theme.buttonPrimary : theme.surfaceContainer))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineLimit(2)
                    }
                }
                Spacer()
                if index == 0 {
                    Text("Recommended").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(theme.surfaceContainer))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.accentColor.opacity(0.08) : theme.surfaceContainer.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? theme.accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isSelected)
    }

    @ViewBuilder private func otherRow(for q: AskUserQuestion) -> some View {
        let curText: String = { if case .other(let t) = answers[q.id] { return t }; return "" }()
        let isOther: Bool = { if case .other = answers[q.id] { return true }; return false }()
        HStack(spacing: 8) {
            Text("Other").font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOther ? theme.textPrimary : theme.textSecondary)
                .frame(minWidth: 42, alignment: .leading)
            TextField("Type your answer", text: Binding(
                get: { curText },
                set: { answers[q.id] = .other(text: $0) }
            )).font(.system(size: 12)).foregroundStyle(theme.textPrimary).onSubmit { advance() }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isOther ? theme.accentColor.opacity(0.06) : theme.surfaceContainer.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isOther ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1))
        .onTapGesture { if case .other = answers[q.id] {} else { answers[q.id] = .other(text: "") } }
    }


    // MARK: - Navigation row

    @ViewBuilder private var navigationRow: some View {
        HStack(spacing: 8) {
            Button(action: { timerTask?.cancel(); onCancel() }) {
                Text("Cancel").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            }.buttonStyle(.plain)
            if questionIndex > 0 {
                Button(action: { questionIndex -= 1 }) {
                    Text("Previous").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                }.buttonStyle(.plain)
            }
            Spacer()
            if questionIndex < questions.count - 1 {
                Button(action: { questionIndex += 1 }) {
                    Text("Next").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.buttonPrimaryText)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.buttonPrimary))
                }.buttonStyle(.plain)
            } else {
                Button(action: submitAnswers) {
                    Text("Submit answers").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isComplete ? theme.buttonPrimaryText : theme.textDisabled)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(isComplete ? theme.buttonPrimary : theme.buttonSecondary))
                }.buttonStyle(.plain).disabled(!isComplete)
            }
        }
    }

    // MARK: - Logic

    private func selectOption(q: AskUserQuestion, option: AskUserOption, index: Int) {
        answers[q.id] = .option(index: index, label: option.label, description: option.description)
        advance()
    }

    private func advance() {
        if questionIndex < questions.count - 1 {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { questionIndex += 1 }
        } else if isComplete { submitAnswers() }
    }

    private func submitAnswers() {
        guard isComplete else { return }
        timerTask?.cancel()
        onSubmit(answers)
    }

    private func startTimer() {
        guard let ms = timeoutMs, ms > 0 else { timeRemaining = nil; return }
        timeRemaining = ms / 1000
        timerTask?.cancel()
        timerTask = Task {
            var rem = ms / 1000
            while rem > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                rem -= 1
                await MainActor.run { timeRemaining = rem }
            }
            if !Task.isCancelled { await MainActor.run { onCancel() } }
        }
    }
}  // end AskUserCard

