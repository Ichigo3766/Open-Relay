import SwiftUI
import UIKit

// MARK: - Keyboard Tracker

@Observable
final class KeyboardTracker {

    // MARK: - Public State

    private(set) var height: CGFloat = 0
    private(set) var isVisible: Bool = false
    private(set) var animationDuration: Double = 0.25
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

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut

        guard let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) else { return }

        // Measure against the app's own window, not the whole screen: on iPad the
        // window can be smaller than the screen (Stage Manager, Split View, Slide
        // Over), and the keyboard frame is reported in screen coordinates.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        let screenHeight = scene?.screen.bounds.height ?? UIScreen.main.bounds.height

        let windowBottom: CGFloat
        let keyboardTop: CGFloat
        if let window, let screen = scene?.screen {
            let kbInWindow = window.convert(endFrame, from: screen.coordinateSpace)
            windowBottom = window.bounds.maxY
            keyboardTop = kbInWindow.minY
        } else {
            windowBottom = screenHeight
            keyboardTop = endFrame.minY
        }
        let newHeight = max(0, windowBottom - keyboardTop)

        let newVisible: Bool
        if let visible {
            newVisible = visible
        } else {
            newVisible = newHeight > 0
        }

        let safeBottom = window?.safeAreaInsets.bottom ?? 0

        // Floating/undocked keyboard: a docked keyboard always reaches the bottom
        // of the screen; a floating one doesn't — don't push content up for it.
        let isDocked = endFrame.maxY >= screenHeight - 1
        let adjustedHeight = (newVisible && isDocked) ? max(0, newHeight - safeBottom) : 0

        animationDuration = duration
        animationCurve = curve

        // During an interactive scroll-to-dismiss gesture, iOS fires rapid
        // keyboardWillChangeFrame events with near-zero durations. Animating
        // each of these creates competing SwiftUI transactions that cause the
        // input bar to jitter as the keyboard slides away. Instead, track the
        // frame directly (no animation) so the bar moves in perfect sync with
        // the user's finger. Only intentional show/hide events (visible != nil)
        // or deliberate frame changes with a real duration get a SwiftUI animation.
        let isInteractiveTracking = visible == nil && duration < 0.05
        if isInteractiveTracking {
            height = adjustedHeight
            isVisible = newVisible
        } else {
            withAnimation(swiftUIAnimation(duration: duration, curve: curve)) {
                height = adjustedHeight
                isVisible = newVisible
            }
        }
    }

    // MARK: - Helpers

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
            return .interactiveSpring(response: duration, dampingFraction: 1.0, blendDuration: 0)
        }
    }

    var matchedAnimation: Animation {
        swiftUIAnimation(duration: animationDuration, curve: animationCurve)
    }
}
