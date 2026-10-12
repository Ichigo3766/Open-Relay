import SwiftUI

private struct CachedDetailsLoaderKey: EnvironmentKey {
    static let defaultValue: (@MainActor () async throws -> Void)? = nil
}

extension EnvironmentValues {
    var loadCachedDetails: (@MainActor () async throws -> Void)? {
        get { self[CachedDetailsLoaderKey.self] }
        set { self[CachedDetailsLoaderKey.self] = newValue }
    }
}

/// An evicted body is unavailable offline; never display the small identity anchor as its content.
struct CachedDetailsLoader: View {
    @Environment(\.loadCachedDetails) private var load
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading) {
            if loading || error == nil { ProgressView("Loading details…") }
            else if let error {
                Text(error).font(.caption)
                Button("Retry") { Task { await restore() } }
            }
        }
        .task { await restore() }
    }

    private func restore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            guard let load else { throw URLError(.notConnectedToInternet) }
            try await load()
        } catch is CancellationError { }
        catch { self.error = "Connect to load these details. " + error.localizedDescription }
    }
}
