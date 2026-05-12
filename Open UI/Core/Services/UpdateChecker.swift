import Foundation
import SwiftUI

// MARK: - Update Info Model

struct AppUpdateInfo: Identifiable, Sendable {
    /// Stable identity is the version string — each release is unique.
    var id: String { version }

    let version: String          // e.g. "4.0"
    let releaseNotes: String     // Plain-text release notes from the App Store
    let releaseURL: URL          // App Store product page URL
}

// MARK: - iTunes Lookup Response Models

private struct ITunesLookupResponse: Decodable {
    let resultCount: Int
    let results: [ITunesAppResult]
}

private struct ITunesAppResult: Decodable {
    let version: String
    let releaseNotes: String?
    let trackViewUrl: String
}

// MARK: - Update Checker

/// Checks the Apple iTunes Lookup API for newer App Store versions of Open Relay
/// and surfaces an update notice to the user when one is found.
///
/// - Checks on every app launch and on-demand from Settings → About.
/// - Auto-shows the sheet only the FIRST time a new version is detected.
///   Once the user dismisses the sheet ("Later"), that version is marked as
///   "seen" in UserDefaults — subsequent launches keep the update icon visible
///   but will NOT auto-show the popup again.
/// - Fails silently on any network or parsing error.
@Observable
@MainActor
final class UpdateChecker {

    // MARK: - Published State

    /// Non-nil when there is a newer version available that the user hasn't dismissed.
    /// Setting this to `nil` closes the sheet; the update icon uses `pendingUpdate`.
    var availableUpdate: AppUpdateInfo? = nil

    /// Persists across sheet dismissal so the update icon stays visible.
    /// Only cleared when the next version check finds no newer release.
    var pendingUpdate: AppUpdateInfo? = nil

    /// `true` while an on-demand check is in progress (used by the Settings row).
    var isChecking: Bool = false

    // MARK: - Private Constants

    private static let appID = "6759630325"
    private static let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(appID)&country=us")!

    /// UserDefaults key storing the last app-update version the user has already seen/dismissed.
    private static let seenVersionKey = "openui.appUpdate.seenVersion"

    // MARK: - Public API

    /// Checks for updates unconditionally. Safe to call on every app launch.
    /// Auto-shows the sheet only if this version hasn't been seen/dismissed before.
    /// Clears `pendingUpdate` (and thus the icon) when the app is up-to-date.
    func checkForUpdates() async {
        do {
            guard let result = try await fetchAppStoreResult() else { return }

            let remoteVersion = result.version
            let localVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            guard isNewer(remote: remoteVersion, than: localVersion) else {
                // Up to date — clear any lingering update state
                availableUpdate = nil
                pendingUpdate = nil
                return
            }

            let releaseURL = URL(string: result.trackViewUrl) ?? URL(string: "https://apps.apple.com/app/id\(Self.appID)")!
            let info = AppUpdateInfo(
                version: remoteVersion,
                releaseNotes: result.releaseNotes ?? "",
                releaseURL: releaseURL
            )
            pendingUpdate = info
            // Only auto-popup if the user hasn't already seen/dismissed this version
            let seenVersion = UserDefaults.standard.string(forKey: Self.seenVersionKey)
            if seenVersion != remoteVersion {
                availableUpdate = info
            }
        } catch {
            // Fail silently — update check is non-critical
        }
    }

    /// On-demand check triggered from Settings → About.
    /// Shows a spinner while checking; if up-to-date, the caller can show
    /// a "You're up to date" message by observing `isChecking` going false
    /// with `availableUpdate == nil`.
    func checkForUpdatesManually() async {
        isChecking = true
        defer { isChecking = false }
        do {
            guard let result = try await fetchAppStoreResult() else { return }
            let remoteVersion = result.version
            let localVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            guard isNewer(remote: remoteVersion, than: localVersion) else {
                availableUpdate = nil
                pendingUpdate = nil
                return
            }
            let releaseURL = URL(string: result.trackViewUrl) ?? URL(string: "https://apps.apple.com/app/id\(Self.appID)")!
            let info = AppUpdateInfo(
                version: remoteVersion,
                releaseNotes: result.releaseNotes ?? "",
                releaseURL: releaseURL
            )
            pendingUpdate = info
            availableUpdate = info
        } catch { }
    }

    /// Called when the user taps "Later" — hides the sheet, marks this version
    /// as seen so the popup won't reappear on future launches, but keeps
    /// `pendingUpdate` so the update icon remains visible.
    func dismissUpdate() {
        if let version = pendingUpdate?.version {
            UserDefaults.standard.set(version, forKey: Self.seenVersionKey)
        }
        availableUpdate = nil
    }

    /// Called by the update icon — re-presents the sheet for the pending update.
    func reopenUpdate() {
        availableUpdate = pendingUpdate
    }

    // MARK: - Private Helpers

    private func fetchAppStoreResult() async throws -> ITunesAppResult? {
        var request = URLRequest(url: Self.lookupURL, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(ITunesLookupResponse.self, from: data)
        guard decoded.resultCount > 0 else { return nil }
        return decoded.results.first
    }

    /// Returns `true` if `remote` is strictly newer than `local`
    /// using standard semantic versioning (major.minor.patch).
    private func isNewer(remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator:  ".").compactMap { Int($0) }
        let maxLen = max(r.count, l.count)
        for i in 0..<maxLen {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
