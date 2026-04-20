import CoreLocation
import Foundation
import os.log
import UIKit

/// Manages device GPS location for Open Relay.
///
/// Location sharing is entirely opt-in — the manager only starts updates after
/// the user explicitly enables "Share Location" in Privacy & Security settings.
/// Once enabled, a "When In Use" authorization request is shown.
///
/// Tracking strategy:
/// - Uses `startUpdatingLocation` (continuous) while the app is foregrounded so the
///   fix is always fresh.
/// - Stops when the app backgrounds to save battery.
/// - On foreground resume, calls `requestLocation()` first for a fast single fix,
///   then switches to continuous updates.
/// - `currentLocationString` is a synchronous computed property — it returns
///   whatever is cached if fresh enough (≤120 s), or nil otherwise.
///   No async waiting, no blocking message sends.
@MainActor @Observable
final class LocationManager: NSObject {

    // MARK: - Singleton

    static let shared = LocationManager()

    // MARK: - Observable State

    /// Whether the user has enabled location sharing in Settings.
    /// Backed by UserDefaults so it persists across launches.
    var isLocationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "locationSharingEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "locationSharingEnabled")
            if newValue {
                startIfAuthorized()
            } else {
                stop()
                cachedLocation = nil
                cachedPlaceName = nil
                UserDefaults.standard.removeObject(forKey: "cachedPlaceName")
            }
        }
    }

    /// Current iOS authorisation status.
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Most recently cached location (nil until first fix after enabling).
    private(set) var cachedLocation: CLLocation?

    /// Human-readable place name from reverse geocoding (e.g. "San Francisco, CA, United States").
    /// Persisted to UserDefaults so it survives app restarts.
    private(set) var cachedPlaceName: String? {
        didSet {
            if let name = cachedPlaceName {
                UserDefaults.standard.set(name, forKey: "cachedPlaceName")
            } else {
                UserDefaults.standard.removeObject(forKey: "cachedPlaceName")
            }
        }
    }

    /// Human-readable description for the current location.
    /// Format: "City, State, Country (Latitude: XX.XXXXXX, Longitude: YY.YYYYYY)"
    /// Falls back to coords-only if geocoding hasn't completed yet.
    var locationString: String? {
        guard let loc = cachedLocation else { return nil }
        let lat = String(format: "%.6f", loc.coordinate.latitude)
        let lon = String(format: "%.6f", loc.coordinate.longitude)
        let coords = "Latitude: \(lat), Longitude: \(lon)"
        if let place = cachedPlaceName {
            return "\(place) (\(coords))"
        }
        return coords
    }

    /// Returns the location string if a sufficiently fresh fix is available (≤120 s old),
    /// otherwise returns `nil`. This is synchronous — it never blocks the caller.
    ///
    /// Call this just before sending a message. If location services are running and the
    /// device has recently delivered a fix, this will return the current location.
    /// If the cache is stale or unavailable, returns `nil` so the AI request still proceeds.
    var currentLocationString: String? {
        guard isLocationEnabled else { return nil }
        guard authorizationStatus == .authorizedWhenInUse
                || authorizationStatus == .authorizedAlways else { return nil }
        guard let fix = cachedLocation else { return nil }
        // Only use the fix if it's within the staleness window.
        guard -fix.timestamp.timeIntervalSinceNow <= staleThreshold else { return nil }
        return locationString
    }

    /// Returns `true` if location is enabled AND authorised AND a fresh fix is available.
    var isLocationAvailable: Bool {
        currentLocationString != nil
    }

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.openui", category: "LocationManager")

    /// How old (seconds) a cached fix can be before we consider it stale.
    /// 120 s is conservative — iOS delivers updates much more frequently during driving,
    /// and the app requests a single fix immediately on foreground resume.
    private let staleThreshold: TimeInterval = 120

    /// Minimum distance (degrees lat/lon ≈ 500 m) before re-geocoding.
    private let geocodeBucketSize: CLLocationDegrees = 0.005

    /// The coordinate we last ran reverse geocoding for.
    private var lastGeocodedCoordinate: CLLocationCoordinate2D?

    // MARK: - Init

    override private init() {
        // Restore persisted place name immediately so it's available before first fix.
        let savedName = UserDefaults.standard.string(forKey: "cachedPlaceName")
        super.init()
        cachedPlaceName = savedName

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50 // metres — wake on meaningful movement

        // Restore auth status synchronously so the UI is correct on first render
        authorizationStatus = locationManager.authorizationStatus

        // If the user had location enabled from a previous session and is already
        // authorized, resume continuous tracking so `{{USER_LOCATION}}` works immediately.
        if isLocationEnabled {
            startIfAuthorized()
        }

        // Pause tracking when backgrounded; resume when foregrounded.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    // MARK: - Public API

    /// Requests iOS "When In Use" permission and starts location updates.
    /// Call this when the user first enables the toggle.
    func requestPermissionAndStart() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdating()
        case .denied, .restricted:
            logger.warning("Location permission denied — cannot start updates")
        @unknown default:
            break
        }
    }

    // MARK: - Private Helpers

    private func startIfAuthorized() {
        let status = locationManager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdating()
        }
    }

    private func startUpdating() {
        locationManager.startUpdatingLocation()
        logger.info("Location updates started (continuous)")
    }

    private func stop() {
        locationManager.stopUpdatingLocation()
        logger.info("Location updates stopped")
    }

    @objc private func appDidEnterBackground() {
        guard isLocationEnabled else { return }
        locationManager.stopUpdatingLocation()
        logger.info("Location updates paused (background)")
    }

    @objc private func appWillEnterForeground() {
        guard isLocationEnabled else { return }
        guard authorizationStatus == .authorizedWhenInUse
                || authorizationStatus == .authorizedAlways else { return }

        // Request a single immediate fix first — this fires `didUpdateLocations`
        // quickly and refreshes the cache before the user sends a message.
        // Then switch to continuous updates for ongoing freshness.
        locationManager.requestLocation()
        locationManager.startUpdatingLocation()
        logger.info("Location updates resumed (foreground) — immediate fix requested")
    }

    /// Reverse-geocodes `location` only when we've moved significantly since the last call.
    private func reverseGeocodeIfNeeded(_ location: CLLocation) {
        let coord = location.coordinate

        // Skip geocode if we haven't moved more than the bucket size
        if let last = lastGeocodedCoordinate {
            let dLat = abs(coord.latitude - last.latitude)
            let dLon = abs(coord.longitude - last.longitude)
            if dLat < geocodeBucketSize && dLon < geocodeBucketSize {
                return // Still in the same city bucket — reuse existing place name
            }
        }

        lastGeocodedCoordinate = coord
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self else { return }
            if let error {
                self.logger.warning("Reverse geocode failed: \(error.localizedDescription)")
                return
            }
            guard let placemark = placemarks?.first else { return }

            // Build "City, State, Country" — skip nil components
            let parts = [placemark.locality,
                         placemark.administrativeArea,
                         placemark.country]
                .compactMap { $0 }
            let name = parts.joined(separator: ", ")

            Task { @MainActor in
                self.cachedPlaceName = name.isEmpty ? nil : name
                self.logger.info("Reverse geocoded: \(name)")
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.cachedLocation = latest
            self.logger.info("Location updated: \(latest.coordinate.latitude), \(latest.coordinate.longitude)")
            self.reverseGeocodeIfNeeded(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.logger.warning("Location error: \(error.localizedDescription)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            self.logger.info("Location auth changed: \(String(describing: status))")
            if (status == .authorizedWhenInUse || status == .authorizedAlways) && self.isLocationEnabled {
                self.startUpdating()
            }
        }
    }
}
