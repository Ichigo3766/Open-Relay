import UIKit

/// Centralized haptic feedback service with pre-prepared generators.
///
/// Creating a new `UIImpactFeedbackGenerator` on every tap adds ~16-50ms
/// latency. This service pre-creates and prepares generators so feedback
/// is instant when triggered.
///
/// Usage:
/// ```swift
/// Haptics.play(.light)
/// ```
@MainActor
enum Haptics {
    // MARK: - Pre-prepared Generators

    private static let lightGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        return g
    }()

    private static let mediumGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        return g
    }()

    private static let softGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare()
        return g
    }()

    private static let notificationGenerator: UINotificationFeedbackGenerator = {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        return g
    }()

    private static let selectionGenerator: UISelectionFeedbackGenerator = {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        return g
    }()

    // MARK: - Impact Styles

    enum Style {
        case light
        case medium
        case soft
    }

    // MARK: - Public API

    /// Plays an impact haptic with the given style. Generators are
    /// pre-prepared so there is zero warm-up latency.
    static func play(_ style: Style) {
        switch style {
        case .light:
            lightGenerator.impactOccurred()
            lightGenerator.prepare()
        case .medium:
            mediumGenerator.impactOccurred()
            mediumGenerator.prepare()
        case .soft:
            softGenerator.impactOccurred()
            softGenerator.prepare()
        }
    }

    /// Plays a notification haptic (success, warning, error).
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }

    /// Plays a selection change haptic (very subtle tick).
    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// Plays a streaming token haptic — throttled internally to ~3 Hz.
    ///
    /// Called from `StreamingContentStore.applySnapshot()` so it fires in sync
    /// with characters actually appearing on screen (drain clock), not with raw
    /// server token arrival. This ensures haptics are felt throughout the full
    /// typewriter effect on fast models where token batches arrive faster than
    /// the drain reveals them.
    ///
    /// Reads the user preference directly from UserDefaults on every call
    /// (safe at 3 Hz). Also enforces the throttle internally — callers do not
    /// need their own rate-limiting.
    static func streamingTick() {
        guard UserDefaults.standard.object(forKey: "streamingHaptics") as? Bool ?? true else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - _lastStreamingTime >= 0.33 else { return }
        _lastStreamingTime = now
        softGenerator.impactOccurred(intensity: 0.4)
        softGenerator.prepare()
    }

    // Private throttle state for streaming haptic.
    // @MainActor isolation on the enum ensures thread-safe access.
    private static var _lastStreamingTime: CFAbsoluteTime = 0
}
