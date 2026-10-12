import SwiftUI

/// Read-only file tree for a multi-file skill: SKILL.md plus scripts,
/// references and templates. Tap a text file to view it.
struct SkillFilesSection: View {
    let skillId: String

    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var files: [APIClient.SkillFileSummary] = []
    @State private var versionId: String?
    @State private var viewing: APIClient.SkillFileSummary?

    var body: some View {
        Group {
            // Only worth showing when the skill has more than its SKILL.md.
            if files.count > 1 {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Files")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(files) { file in
                            Button { viewing = file } label: {
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: file.isBinary ? "doc.zipper" : icon(for: file.path))
                                        .foregroundStyle(theme.brandPrimary)
                                        .frame(width: 20)
                                    Text(file.path)
                                        .scaledFont(size: 14, design: .monospaced)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(file.isBinary)
                            if file.id != files.last?.id { Divider().padding(.leading, Spacing.md) }
                        }
                    }
                    .background(theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
                    Text("Supporting files can be edited in Open WebUI on the web.")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .task { await load() }
        .sheet(item: $viewing) { file in
            SkillFileViewer(skillId: skillId, file: file, versionId: versionId ?? "")
        }
    }

    private func icon(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "txt": return "doc.text"
        case "py", "js", "ts", "sh", "rb", "go": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        default: return "doc"
        }
    }

    private func load() async {
        guard let api = dependencies.apiClient,
              let result = try? await api.getSkillFiles(skillId: skillId) else { return }
        versionId = result.versionId
        files = result.files.sorted { a, b in
            a.path == "SKILL.md" ? true : b.path == "SKILL.md" ? false : a.path < b.path
        }
    }
}

private struct SkillFileViewer: View {
    let skillId: String
    let file: APIClient.SkillFileSummary
    let versionId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                if let text {
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                } else if let error {
                    Text(error).foregroundStyle(.red).padding()
                } else {
                    ProgressView().padding()
                }
            }
            .navigationTitle(file.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                if let text {
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: text) }
                }
            }
            .task {
                do {
                    let data = try await dependencies.apiClient?.getSkillFileContent(skillId: skillId, path: file.path, versionId: versionId) ?? Data()
                    text = String(data: data, encoding: .utf8) ?? String(localized: "This file can't be shown as text.")
                } catch {
                    self.error = APIError.from(error).errorDescription
                }
            }
        }
    }
}
