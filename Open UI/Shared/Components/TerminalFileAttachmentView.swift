import SwiftUI
import QuickLook

/// Only button actions create a download. No thumbnail, player, or URL is
/// prepared when this view appears, including for automatic display events.
struct TerminalFileAttachmentView: View {
    let file: TerminalFileAttachment
    let messageId: String
    let apiClient: APIClient
    @State private var action: Action?
    @State private var requestId: UUID?
    @State private var received: Int64 = 0
    @State private var expected: Int64 = -1
    @State private var error: String?
    @State private var downloaded: DownloadedTerminalFile?
    @State private var previewURL: URL?
    @State private var sharing = false
    @State private var scope: String?

    private enum Action { case preview, save }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name).font(.body).lineLimit(2)
                    Text([file.contentType, file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: file.isMedia ? "play.rectangle" : "doc") }

            if requestId != nil {
                HStack {
                    if expected > 0 { ProgressView(value: Double(received), total: Double(expected)) }
                    else { ProgressView() }
                    Text("Loading \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel", systemImage: "xmark") { requestId = nil }
                        .labelStyle(.iconOnly).accessibilityLabel("Cancel loading \(file.name)")
                }
            } else {
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(error == nil ? (file.isMedia ? "Play" : "Open") : "Retry",
                           systemImage: error == nil ? (file.isMedia ? "play.fill" : "doc.text.magnifyingglass") : "arrow.clockwise") {
                        start(error == nil ? .preview : action ?? .preview)
                    }
                    .accessibilityLabel("\(error == nil ? (file.isMedia ? "Play" : "Open") : "Retry") \(file.name)")
                    Spacer()
                    Button("Save / Share", systemImage: "square.and.arrow.up") { start(.save) }
                        .accessibilityLabel("Save or share \(file.name)")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { if scope == nil { scope = apiClient.network.conversationCacheScope } }
        .task(id: requestId) {
            guard let id = requestId, let action else { return }
            do {
                guard let scope else { throw TerminalFileError.changedAccount }
                let result = try await apiClient.downloadTerminalAttachment(file, messageId: messageId, scope: scope) { bytes, total in
                    Task { @MainActor in
                        guard requestId == id else { return }
                        received = bytes
                        expected = total
                    }
                }
                try Task.checkCancellation()
                guard requestId == id else { return }
                downloaded = result
                if action == .preview { previewURL = result.url } else { sharing = true }
            } catch {
                guard requestId == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if requestId == id { requestId = nil }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, url in if url == nil { downloaded = nil } }
        .sheet(isPresented: $sharing, onDismiss: { downloaded = nil }) {
            if let downloaded { ShareSheetView(activityItems: [downloaded.url]) }
        }
        .onDisappear { requestId = nil }
    }

    private func start(_ action: Action) {
        guard requestId == nil else { return }
        self.action = action
        error = nil
        received = 0
        expected = -1
        requestId = UUID()
    }
}
