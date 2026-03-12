import SwiftUI
import UIKit

// MARK: - Keyboard Tracker

/// Tracks the keyboard height and exposes the exact iOS animation parameters
/// so the chat input field can slide in perfect sync with the keyboard —
/// no lag, no jitter, pixel-perfect native feel.
///
/// ## Usage
/// ```swift
/// @State private var keyboard = KeyboardTracker()
///
/// view
///     .safeAreaInset(edge: .bottom, spacing: 0) {
///         ChatInputField(...)
///             .padding(.bottom, keyboard.isVisible ? 0 : 0)
///     }
///     .onAppear { keyboard.start() }
///     .onDisappear { keyboard.stop() }
/// ```
@Observable
final class KeyboardTracker {

    // MARK: - Public State

    /// Current keyboard height above the safe area bottom (0 when hidden).
    private(set) var height: CGFloat = 0

    /// Whether the keyboard is currently visible.
    private(set) var isVisible: Bool = false

    /// Animation duration published by iOS — use this for perfectly synced animations.
    private(set) var animationDuration: Double = 0.25

    /// The UIView animation curve from iOS keyboard notification.
    private(set) var animationCurve: UIView.AnimationCurve = .easeInOut

    // MARK: - Private

    private var showObserver: NSObjectProtocol?
    private var hideObserver: NSObjectProtocol?
    private var changeObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func start() {
        guard showObserver == nil else { return }

        showObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardNotification(notification, visible: true)
        }

        hideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardNotification(notification, visible: false)
        }

        changeObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardNotification(notification, visible: nil)
        }
    }

    func stop() {
        if let obs = showObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = hideObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = changeObserver { NotificationCenter.default.removeObserver(obs) }
        showObserver = nil
        hideObserver = nil
        changeObserver = nil
    }

    deinit { stop() }

    // MARK: - Notification Handling

    private func handleKeyboardNotification(_ notification: Notification, visible: Bool?) {
        guard let userInfo = notification.userInfo else { return }

        // Extract animation parameters from UIKit — these match the system keyboard exactly
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut

        // Get the keyboard end frame in screen coordinates
        guard let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) else { return }

        // Use window scene screen bounds instead of deprecated UIScreen.main
        let screenHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? UIScreen.main.bounds.height
        let keyboardTop = endFrame.minY
        let newHeight = max(0, screenHeight - keyboardTop)

        // Determine visibility from the end frame
        let newVisible: Bool
        if let visible {
            newVisible = visible
        } else {
            newVisible = newHeight > 0
        }

        // Subtract the safe area bottom so we only pad above the home indicator
        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0

        let adjustedHeight = newVisible ? max(0, newHeight - safeBottom) : 0

        animationDuration = duration
        animationCurve = curve

        withAnimation(swiftUIAnimation(duration: duration, curve: curve)) {
            height = adjustedHeight
            isVisible = newVisible
        }
    }

    // MARK: - Helpers

    /// Converts UIKit animation curve + duration to a SwiftUI Animation.
    private func swiftUIAnimation(duration: Double, curve: UIView.AnimationCurve) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        @unknown default:
            // iOS keyboard uses a custom spring curve (curveRaw == 7).
            // The closest SwiftUI equivalent is an interactive spring.
            return .interactiveSpring(response: duration, dampingFraction: 1.0, blendDuration: 0)
        }
    }

    /// SwiftUI Animation that precisely matches the keyboard animation.
    /// Use this when you need the animation object rather than driving it in handleKeyboardNotification.
    var matchedAnimation: Animation {
        swiftUIAnimation(duration: animationDuration, curve: animationCurve)
    }
}
