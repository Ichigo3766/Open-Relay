import Foundation
import CoreLocation

// MARK: - Server-side {{USER_LOCATION}} (web InterfaceSettings "Allow User Location")
//
// The web stores the position in the user's profile (`POST /users/user/info/update
// {location}`, a shallow merge into `user.info`) and the server fills `{{USER_LOCATION}}`
// from it in system prompts, tools and background tasks (utils/task.py). It also keeps
// `settings.ui.userLocation` so every client shows the same switch.

extension APIClient {
    /// POST /api/v1/users/user/info/update — merges only `location` into `user.info`.
    func updateUserLocationInfo(_ location: Any) async throws {
        _ = try await network.requestRaw(
            path: "/api/v1/users/user/info/update", method: .post,
            body: try JSONSerialization.data(withJSONObject: ["location": location]))
    }
}

/// Keeps the server's copy of the device location fresh, without spamming it.
@MainActor
final class ServerLocationSync {
    static let shared = ServerLocationSync()

    weak var apiClient: APIClient?
    private var lastSent: CLLocation?
    private var lastSentAt: Date?
    private var lastPlace: String?
    private var inFlight = false

    /// Min. interval and distance between uploads (the web refreshes on every message).
    private let minInterval: TimeInterval = 5 * 60
    private let minDistance: CLLocationDistance = 500

    /// Web `getUserPosition()` format, with the place name in front when we have it.
    nonisolated static func format(_ loc: CLLocationCoordinate2D, place: String?) -> String {
        let coords = String(format: "%.3f, %.3f (lat, long)", loc.latitude, loc.longitude)
        guard let place, !place.isEmpty else { return coords }
        return "\(place) — \(coords)"
    }

    /// Called on each GPS fix and before sending a message. `force` skips the throttle.
    func syncIfNeeded(location: CLLocation?, place: String?, force: Bool = false) {
        guard let api = apiClient, let location, LocationManager.shared.isLocationEnabled, !inFlight else { return }
        if !force, let lastSent, let lastSentAt {
            let moved = location.distance(from: lastSent) >= minDistance
            let stale = Date().timeIntervalSince(lastSentAt) >= minInterval
            let placeChanged = place != nil && place != lastPlace
            guard moved || stale || placeChanged else { return }
            // Even when moved, never more than once a minute.
            guard Date().timeIntervalSince(lastSentAt) >= 60 || placeChanged else { return }
        }
        inFlight = true
        let text = Self.format(location.coordinate, place: place)
        Task {
            defer { inFlight = false }
            do {
                try await api.updateUserLocationInfo(text)
                lastSent = location; lastSentAt = Date(); lastPlace = place
            } catch {
                // Retry on the next fix.
            }
        }
    }

    /// Switch turned on/off: mirror it to `settings.ui.userLocation` (web shares the switch)
    /// and clear the stored location on off, so stale coordinates aren't kept on the server.
    func setEnabled(_ enabled: Bool) {
        guard let api = apiClient else { return }
        lastSent = nil; lastSentAt = nil; lastPlace = nil
        Task {
            try? await api.mergeUserUISettings(["userLocation": enabled])
            // The server renders `str(info.location)`, so null would print "None";
            // "Unknown" matches what it shows when no location was ever saved.
            if !enabled { try? await api.updateUserLocationInfo("Unknown") }
        }
    }

    func reset() { lastSent = nil; lastSentAt = nil; lastPlace = nil }
}
