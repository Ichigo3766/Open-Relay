import SwiftUI

struct PromptVersionDiff: Decodable {
    struct Snapshot: Decodable {
        let name: String?
        let command: String?
    }
    let contentDiff: [String]
    let fromSnapshot: Snapshot
    let toSnapshot: Snapshot
    let lineEndingsOnly: Bool?
    enum CodingKeys: String, CodingKey {
        case contentDiff = "content_diff"
        case fromSnapshot = "from_snapshot"
        case toSnapshot = "to_snapshot"
        case lineEndingsOnly = "line_endings_only"
    }
}

struct PromptVersionDiffView: View {
    @Environment(\.dismiss) private var dismiss
    let promptId: String
    let versions: [PromptVersion]
    let manager: PromptManager
    @State private var from: String
    @State private var to: String
    @State private var diff: PromptVersionDiff?
    @State private var error: String?
    @State private var isLoading = false
    @State private var attempt = 0

    init(promptId: String, versions: [PromptVersion], manager: PromptManager) {
        self.promptId = promptId
        self.versions = versions
        self.manager = manager
        _from = State(initialValue: versions.dropFirst().first?.id ?? "")
        _to = State(initialValue: versions.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Picker("From", selection: $from) { versionOptions }
                Picker("To", selection: $to) { versionOptions }
                if isLoading {
                    ProgressView("Loading changes…")
                } else if let error {
                    Text(error)
                    Button("Retry") { attempt += 1 }
                } else if let diff {
                    if diff.fromSnapshot.name != diff.toSnapshot.name {
                        Text("Name: \(diff.fromSnapshot.name ?? "") → \(diff.toSnapshot.name ?? "")")
                    }
                    if diff.fromSnapshot.command != diff.toSnapshot.command {
                        Text("Command: /\(diff.fromSnapshot.command ?? "") → /\(diff.toSnapshot.command ?? "")")
                    }
                    if diff.contentDiff.isEmpty {
                        Text(diff.lineEndingsOnly == true ? "Only line endings changed." : "No content changes.")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(diff.contentDiff.enumerated()), id: \.offset) { _, line in
                                    Text(line.isEmpty ? " " : line)
                                        .foregroundStyle(color(for: line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.md)
            .navigationTitle("Compare Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .task(id: "\(from):\(to):\(attempt)") {
                isLoading = true
                diff = nil
                error = nil
                do {
                    let result = try await manager.getDiff(promptId: promptId, from: from, to: to)
                    try Task.checkCancellation()
                    diff = result
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
                if !Task.isCancelled { isLoading = false }
            }
        }
    }

    private var versionOptions: some View {
        ForEach(versions) { version in
            Text(version.commitMessage ?? version.displayHash ?? String(version.id.prefix(8))).tag(version.id)
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        return .primary
    }
}
