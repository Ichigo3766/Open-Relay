import SwiftUI

extension SkillFileImportView {
    func load(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = String(localized: "Couldn't read that file.")
            return
        }
        fileData = data
        fileName = url.lastPathComponent
        isLoading = true
        error = nil
        do {
            let previews = try await apiClient.previewSkillImport(fileData: data, fileName: fileName)
            items = previews.map(SkillImportItem.init(preview:))
            if items.isEmpty { error = String(localized: "No skills were found in this file.") }
        } catch {
            self.error = APIError.from(error).errorDescription
        }
        isLoading = false
    }

    func runImport() async {
        guard let fileData else { return }
        isImporting = true
        let decisions = items.sorted { $0.index < $1.index }.map(\.decision)
        do {
            let results = try await apiClient.importSkills(fileData: fileData, fileName: fileName, decisions: decisions)
            for (i, result) in results.enumerated() where i < items.count {
                let status = result["status"] as? String ?? ""
                items[i].status = status == "error" ? (result["error"] as? String ?? status) : status
            }
            await onImport()
            if results.allSatisfy({ ($0["status"] as? String) != "error" }) {
                Haptics.notify(.success)
                dismiss()
            }
        } catch {
            self.error = APIError.from(error).errorDescription
        }
        isImporting = false
    }
}
