import SwiftUI
import QuickLook

/// Created only after a file result is tapped. The original stays on temporary disk,
/// scoped to this presentation; search rows never fetch file contents or thumbnails.
struct SearchFilePreview: View {
    let file: LibrarySearchResult
    let api: APIClient
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var error: String?
    @State private var attempt = 0
    @State private var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    FileQuickLook(url: url)
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn’t open file", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { attempt += 1 }
                    }
                } else {
                    ProgressView("Loading file…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
                if let url {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) { Label("Save or share file", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        .task(id: attempt) {
            error = nil
            do {
                let temporary = try await api.network.downloadFile(path: "/api/v1/files/\(file.resourceID)/content")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = (file.title as NSString).lastPathComponent
                let destination = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "file" : name)
                try FileManager.default.moveItem(at: temporary, to: destination)
                url = destination
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onDisappear { try? FileManager.default.removeItem(at: directory) }
    }
}

private struct FileQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
