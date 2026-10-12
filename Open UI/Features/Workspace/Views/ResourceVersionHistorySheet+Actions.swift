import SwiftUI

extension ResourceVersionHistorySheet {
    func load() async {
        guard let api = dependencies.apiClient else { return }
        isLoading = true
        error = nil
        if liveId == nil { liveId = liveVersionId }
        do {
            versions = try await api.getResourceHistory(resource)
            // Older resources may have no live pointer; the newest version is live then.
            if liveId == nil { liveId = versions.first?.id }
        } catch {
            self.error = APIError.from(error).errorDescription
        }
        isLoading = false
    }

    func makeLive(_ version: ResourceVersion) async {
        guard let api = dependencies.apiClient else { return }
        busyId = version.id
        error = nil
        do {
            try await api.setResourceVersion(resource, versionId: version.id, expectedVersionId: liveId)
            liveId = version.id
            Haptics.notify(.success)
            onRestored()
            await load()
        } catch {
            self.error = APIError.from(error).errorDescription
        }
        busyId = nil
    }

    func delete(_ version: ResourceVersion) async {
        guard let api = dependencies.apiClient else { return }
        do {
            try await api.deleteResourceVersion(resource, versionId: version.id)
            versions.removeAll { $0.id == version.id }
        } catch {
            self.error = APIError.from(error).errorDescription
        }
        deleteCandidate = nil
    }
}
