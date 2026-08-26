import Foundation
import SwiftUI

// MARK: - Models

/// Passed to the sheet when a newer server version is detected.
struct ServerUpdateInfo: Identifiable, Sendable {
    var id: String { version }
    let version: String
    let serverName: String
    /// The full base URL of the server (e.g. "https://chat.abhiinnovate.com").
    /// Used to construct the favicon URL in the update sheet.
    let serverURL: String
    /// The full GitHub release changelog markdown for the new version.
    /// Fetched from https://api.github.com/repos/open-webui/open-webui/releases/tags/v{version}
    /// Commit/PR link references are stripped for a clean mobile display.
    let changelogMarkdown: String?
}

// MARK: - Raw Decodable Wrappers

private struct VersionUpdatesResponse: Decodable {
    let current: String
    let latest: String
}

private struct GitHubRelease: Decodable {
    let body: String?
}

// MARK: - ServerUpdateChecker

/// Checks the connected Open WebUI server for a newer version using
/// `/api/version/updates`, then fetches the release changelog from the
/// GitHub Releases API for that exact version.
///
/// - Runs on every app launch (when authenticated).
/// - Auto-shows the sheet only the FIRST time a new version is detected.
///   Once the user dismisses the sheet, that version is marked as "seen" in
///   UserDefaults — subsequent launches keep the update icon but skip the popup.
/// - Fails silently — the server check is non-critical.
@Observable
@MainActor
final class ServerUpdateChecker {

    // MARK: Published State

    /// Non-nil when a newer server version is available and the sheet should show.
    var availableUpdate: ServerUpdateInfo? = nil

    /// Persists after the sheet is dismissed — used to keep the update icon visible.
    var pendingUpdate: ServerUpdateInfo? = nil

    /// `true` while an on-demand check is in progress.
    var isChecking: Bool = false

    /// UserDefaults key storing the last server-update version the user has already seen/dismissed.
    /// Scoped per server URL so different servers don't share seen state.
    private static let seenVersionKeyPrefix = "openui.serverUpdate.seenVersion."

    // MARK: Public API

    /// Checks for a server update using the provided authenticated `APIClient`.
    /// Safe to call on every app launch. Auto-shows popup only for unseen versions.
    func checkForUpdates(using apiClient: APIClient?) async {
        guard let apiClient else { return }
        do {
            guard let info = try await fetchUpdateInfo(from: apiClient) else { return }
            pendingUpdate = info
            // Only auto-popup if the user hasn't already dismissed this version
            let key = Self.seenVersionKeyPrefix + apiClient.baseURL
            let seenVersion = UserDefaults.standard.string(forKey: key)
            if seenVersion != info.version {
                availableUpdate = info
            }
        } catch {
            // Fail silently
        }
    }

    /// On-demand check triggered from Settings → About (Server section).
    func checkForUpdatesManually(using apiClient: APIClient?) async {
        isChecking = true
        defer { isChecking = false }
        guard let apiClient else { return }
        do {
            guard let info = try await fetchUpdateInfo(from: apiClient) else {
                // Up to date
                availableUpdate = nil
                pendingUpdate = nil
                return
            }
            pendingUpdate = info
            availableUpdate = info
        } catch {
            // Fail silently
        }
    }

    /// Hides the sheet, marks this version as seen so the popup won't reappear
    /// on future launches, but keeps `pendingUpdate` so the update icon stays visible.
    func dismissUpdate() {
        if let info = pendingUpdate {
            let key = Self.seenVersionKeyPrefix + info.serverURL
            UserDefaults.standard.set(info.version, forKey: key)
        }
        availableUpdate = nil
    }

    /// Re-presents the sheet for the pending update (called from the update icon).
    func reopenUpdate() {
        availableUpdate = pendingUpdate
    }

    /// Clears all update state (called on server switch / logout).
    /// Does NOT clear the seen-version record — that persists intentionally.
    func reset() {
        availableUpdate = nil
        pendingUpdate = nil
        isChecking = false
    }

    // MARK: Private Helpers

    private func fetchUpdateInfo(from apiClient: APIClient) async throws -> ServerUpdateInfo? {
        // 1. Check if an update is available
        let request = try apiClient.network.buildRequest(
            path: "/api/version/updates",
            authenticated: true,
            timeout: 10
        )
        let (data, response) = try await apiClient.network.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        let versionResponse = try JSONDecoder().decode(VersionUpdatesResponse.self, from: data)
        let latestVersion = versionResponse.latest
        let currentVersion = versionResponse.current

        guard isNewer(remote: latestVersion, than: currentVersion) else {
            // Server is up to date — clear any lingering state
            availableUpdate = nil
            pendingUpdate = nil
            return nil
        }

        // 2. Fetch the changelog for this exact release from GitHub
        let changelogMarkdown = await fetchGitHubChangelog(for: latestVersion)

        // Derive a friendly server name from the base URL
        let serverName = URL(string: apiClient.baseURL)?.host ?? apiClient.baseURL

        return ServerUpdateInfo(
            version: latestVersion,
            serverName: serverName,
            serverURL: apiClient.baseURL,
            changelogMarkdown: changelogMarkdown
        )
    }

    /// Fetches the release body markdown from GitHub for the given version tag.
    /// Returns `nil` if the request fails or the release has no body.
    private func fetchGitHubChangelog(for version: String) async -> String? {
        // Normalize: GitHub tags are "v0.11.1", version strings may or may not have the "v" prefix
        let tag = version.hasPrefix("v") ? version : "v\(version)"
        let urlString = "https://api.github.com/repos/open-webui/open-webui/releases/tags/\(tag)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let body = release.body, !body.isEmpty else { return nil }
            return cleanedChangelog(body)
        } catch {
            return nil
        }
    }

    /// Strips GitHub commit/PR link references from the changelog body so it reads
    /// cleanly on mobile. For example:
    ///   "...added feature. [Commit](https://...), [#123](https://...)"
    ///   → "...added feature."
    private func cleanedChangelog(_ markdown: String) -> String {
        // Pattern: ", [Commit](url)" or ", [#1234](url)" or ", [#1234](url)" at end of bullet items
        // Also handles "[Commit](url)" or "[#1234](url)" without leading comma
        var result = markdown

        // Remove ", [Commit](...)" patterns
        result = result.replacingOccurrences(
            of: #",?\s*\[Commit\]\(https?://[^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        // Remove ", [#1234](...)" or ", [PR-title](...)" patterns pointing to github.com
        result = result.replacingOccurrences(
            of: #",?\s*\[#\d+\]\(https?://github\.com/[^)]+\)"#,
            with: "",
            options: .regularExpression
        )

        // Clean up any trailing whitespace left on lines after stripping
        let lines = result.components(separatedBy: "\n")
        let cleaned = lines.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        return cleaned.joined(separator: "\n")
    }

    /// Returns `true` if `remote` is strictly newer than `local` (semver comparison).
    private func isNewer(remote: String, than local: String) -> Bool {
        // Strip leading "v" if present
        let r = remote.trimmingCharacters(in: .init(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
        let l = local.trimmingCharacters(in: .init(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
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
