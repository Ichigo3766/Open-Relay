//
//  ControlCenterIntents.swift
//
//  Shared between the app and the OpenUIWidgets extension (target membership
//  is added via a pbxproj exception, same as VoiceCallActivityAttributes.swift).
//
//  WHY THIS FILE IS SHARED
//  An `openAppWhenRun` intent used by a Control Center button must be compiled
//  into BOTH the app and the widget extension. Only then can iOS launch the app
//  and run `perform()` inside the app process. When the intent lived only in
//  the extension (returning `OpenURLIntent(openui://…)`), tapping the control
//  did nothing.
//
//  HOW THE ACTION REACHES THE UI
//  `perform()` records the action in App Group UserDefaults and posts
//  `ControlCenterAction.didRequest`. `Open_UIApp` consumes the pending action
//  either from that notification (app already running) or on the next
//  `scenePhase == .active` (cold launch, before the UI is mounted). Consuming
//  removes the key, so the action is handled exactly once.
//

import AppIntents
import Foundation

// MARK: - Shared Action Hand-off

nonisolated enum ControlCenterAction {
    /// App Group suite shared by the app and the widget extension.
    static let appGroupId = "group.com.openui.openui"
    /// UserDefaults key holding the pending action string (e.g. "new-chat").
    static let pendingKey = "pendingControlCenterAction"
    /// Posted in-process after a pending action has been recorded.
    static let didRequest = Notification.Name("com.openui.controlCenter.didRequest")

    static let newChat = "new-chat"

    /// Records `action` and pings the app so it can handle it right away.
    static func request(_ action: String) {
        UserDefaults(suiteName: appGroupId)?.set(action, forKey: pendingKey)
        NotificationCenter.default.post(name: didRequest, object: nil)
    }

    /// Returns and clears the pending action, if any.
    static func consume() -> String? {
        let defaults = UserDefaults(suiteName: appGroupId)
        guard let action = defaults?.string(forKey: pendingKey) else { return nil }
        defaults?.removeObject(forKey: pendingKey)
        return action
    }
}

// MARK: - New Chat Control Intent

/// Runs when the "New Chat" Control Center button is tapped. Opens the app
/// and starts a new chat with the keyboard ready.
nonisolated struct OpenNewChatControlIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Open a new chat in Open Relay.")
    static var openAppWhenRun: Bool = true
    // Control Center-only; the app's NewChatIntent is the canonical shortcut.
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            ControlCenterAction.request(ControlCenterAction.newChat)
        }
        return .result()
    }
}
