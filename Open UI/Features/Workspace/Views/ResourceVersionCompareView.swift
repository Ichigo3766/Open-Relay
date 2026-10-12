import SwiftUI

/// Compares two saved versions of a model, tool, function or skill.
struct ResourceVersionCompareView: View {
    let resource: VersionedResource
    let versions: [ResourceVersion]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) var theme
    @Environment(AppDependencyContainer.self) var dependencies

    @State var from: String
    @State var to: String
    @State var diff: ResourceVersionDiff?
    @State var error: String?
    @State var isLoading = false
    @State var selectedFile: String?
    @State var fileLines: [String] = []

    init(resource: VersionedResource, versions: [ResourceVersion]) {
        self.resource = resource
        self.versions = versions
        // Default: previous version → newest.
        _from = State(initialValue: versions.dropFirst().first?.id ?? versions.first?.id ?? "")
        _to = State(initialValue: versions.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Picker("From", selection: $from) { options }
                    Picker("To", selection: $to) { options }
                    content
                }
                .padding(Spacing.md)
            }
            .navigationTitle("Compare Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .task(id: "\(from):\(to)") { await loadDiff() }
            .task(id: selectedFile) { await loadFile() }
        }
    }

    private var options: some View {
        ForEach(versions) { v in Text(v.title).tag(v.id) }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading changes…").frame(maxWidth: .infinity)
        } else if let error {
            Text(error).foregroundStyle(theme.error)
        } else if let diff {
            if from == to {
                Text("Pick two different versions.").foregroundStyle(theme.textTertiary)
            }
            ForEach(diff.metadata, id: \.self) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.key.capitalized).scaledFont(size: 12, weight: .semibold).foregroundStyle(theme.textTertiary)
                    Text(change.before).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red).lineLimit(8)
                    Text(change.after).font(.system(size: 12, design: .monospaced)).foregroundStyle(.green).lineLimit(8)
                }
            }
            if resource.isSkill {
                skillFiles(diff)
            } else if diff.contentDiff.isEmpty {
                Text(diff.lineEndingsOnly ? "Only line endings changed." : "No code changes.")
                    .foregroundStyle(theme.textTertiary)
            } else {
                diffLines(diff.contentDiff)
            }
        }
    }

    @ViewBuilder
    private func skillFiles(_ diff: ResourceVersionDiff) -> some View {
        if diff.files.isEmpty {
            Text("No file changes.").foregroundStyle(theme.textTertiary)
        } else {
            ForEach(diff.files, id: \.self) { file in
                Button {
                    selectedFile = selectedFile == file.path ? nil : file.path
                } label: {
                    HStack {
                        Image(systemName: file.status == "added" ? "plus.circle" : file.status == "deleted" ? "minus.circle" : "pencil.circle")
                            .foregroundStyle(file.status == "added" ? .green : file.status == "deleted" ? .red : theme.brandPrimary)
                        Text(file.path).font(.system(size: 13, design: .monospaced)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        if file.binary { Text("Binary").scaledFont(size: 11).foregroundStyle(theme.textTertiary) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(file.binary)
                if selectedFile == file.path && !file.binary {
                    diffLines(fileLines)
                }
            }
        }
    }
}
