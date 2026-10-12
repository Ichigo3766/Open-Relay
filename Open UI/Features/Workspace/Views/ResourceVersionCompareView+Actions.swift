import SwiftUI

extension ResourceVersionCompareView {
    func diffLines(_ lines: [String]) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
        .padding(Spacing.sm)
        .background(theme.surfaceContainer.opacity(0.5), in: RoundedRectangle(cornerRadius: CornerRadius.md))
    }

    func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return theme.brandPrimary }
        return theme.textPrimary
    }

    func loadDiff() async {
        guard let api = dependencies.apiClient, !from.isEmpty, !to.isEmpty else { return }
        isLoading = true
        error = nil
        selectedFile = nil
        do {
            diff = try await api.getResourceDiff(resource, from: from, to: to)
        } catch {
            if !Task.isCancelled { self.error = APIError.from(error).errorDescription }
        }
        if !Task.isCancelled { isLoading = false }
    }

    func loadFile() async {
        guard let selectedFile, case .skill(let id) = resource, let api = dependencies.apiClient else {
            fileLines = []
            return
        }
        fileLines = (try? await api.getSkillFileDiff(skillId: id, from: from, to: to, path: selectedFile))?.lines ?? []
    }
}
