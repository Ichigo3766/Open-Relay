import Foundation
import UserNotifications
import os.log

/// Manages local notifications for chat generation completion and voice calls.
///
/// Matches the Flutter app's notification patterns:
/// - Generation complete notifications (when app is backgrounded)
/// - Voice call ongoing notifications
/// - Actionable notification categories with tap-to-open support
@MainActor
final class NotificationService: NSObject, @unchecked Sendable {

    static let shared = NotificationService()

    private let logger = Logger(subsystem: "com.openui", category: "Notifications")

    // MARK: - Notification Identifiers

    /// Category for chat generation complete notifications.
    static let generationCompleteCategory = "GENERATION_COMPLETE"

    /// Category for voice call notifications.
    static let voiceCallCategory = "VOICE_CALL"

    /// Action to open the chat from a notification.
    static let openChatAction = "OPEN_CHAT"

    /// Action to end a voice call from a notification.
    static let endCallAction = "END_CALL"

    // MARK: - State

    /// Whether the user has granted notification permission.
    private(set) var isAuthorized = false

    /// The conversation ID the user is currently viewing.
    /// Set by ChatDetailView on appear/disappear. When a generation
    /// notification arrives for this conversation, it is suppressed
    /// since the user is already looking at it.
    var activeConversationId: String?

    /// Callback when user taps a notification action.
    var onOpenChat: ((String) -> Void)?
    var onEndCall: (() -> Void)?

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Requests notification permissions and registers categories.
    /// Call this early in the app lifecycle (e.g. in AppDelegate or on first launch).
    func setup() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register notification categories
        let openAction = UNNotificationAction(
            identifier: Self.openChatAction,
            title: "Open Chat",
            options: [.foreground]
        )

        let endCallAction = UNNotificationAction(
            identifier: Self.endCallAction,
            title: "End Call",
            options: [.destructive]
        )

        let generationCategory = UNNotificationCategory(
            identifier: Self.generationCompleteCategory,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let voiceCallCategory = UNNotificationCategory(
            identifier: Self.voiceCallCategory,
            actions: [endCallAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([generationCategory, voiceCallCategory])

        // Request permission if not yet determined, otherwise sync cached state
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            // Prompt the user immediately so notifications work from the start
            let granted = await requestPermission()
            isAuthorized = granted
        case .authorized:
            isAuthorized = true
        default:
            isAuthorized = false
        }
    }

    /// Requests notification permission from the user.
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            if granted {
                logger.info("Notification permission granted")
            } else {
                logger.warning("Notification permission denied")
            }
            return granted
        } catch {
            logger.error("Failed to request notification permission: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Generation Complete

    /// Sends a local notification when a chat generation completes while the app is backgrounded.
    ///
    /// - Parameters:
    ///   - conversationId: The ID of the conversation that completed.
    ///   - title: The conversation title.
    ///   - preview: A short preview of the generated response.
    /// Sends a local notification when a chat generation completes.
    /// This is `async` so callers (especially background tasks) can `await` it
    /// and ensure the notification is delivered before iOS suspends the app.
    func notifyGenerationComplete(
        conversationId: String,
        title: String,
        preview: String
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        // If the user has never been asked, request permission now.
        // This is the contextual moment Apple HIG recommends — the user
        // just had a generation complete, so they understand the value.
        if settings.authorizationStatus == .notDetermined {
            let granted = await requestPermission()
            guard granted else { return }
        } else if settings.authorizationStatus != .authorized {
            // User previously denied — nothing we can do, don't spam.
            isAuthorized = false
            return
        }

        isAuthorized = true

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Response is ready"
        content.sound = .default
        content.categoryIdentifier = Self.generationCompleteCategory
        content.userInfo = ["conversationId": conversationId]
        content.threadIdentifier = conversationId

        let request = UNNotificationRequest(
            identifier: "generation-\(conversationId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await center.add(request)
            logger.info("Generation notification scheduled for \(conversationId)")
        } catch {
            logger.error("Failed to deliver generation notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Voice Call

    /// Shows an ongoing-style notification for an active voice call.
    ///
    /// - Parameter modelName: The name of the AI model in the call.
    func showVoiceCallNotification(modelName: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Voice Call"
        content.body = "In call with \(modelName)"
        content.sound = nil // No sound for ongoing
        content.categoryIdentifier = Self.voiceCallCategory
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: "voice-call",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [self] error in
            if let error {
                logger.error("Failed to show voice call notification: \(error.localizedDescription)")
            }
        }
    }

    /// Removes the voice call notification.
    func cancelVoiceCallNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["voice-call"]
        )
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["voice-call"]
        )
    }

    // MARK: - Utility

    /// Clears all delivered notifications.
    func clearAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Clears the badge count.
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground.
    /// Shows generation-complete notifications as banners so the user sees them
    /// even if they're on a different screen within the app. Suppresses other
    /// notification types (e.g., voice call ongoing) in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        let conversationId = notification.request.content.userInfo["conversationId"] as? String

        // Use raw string to avoid main-actor isolation issue with the static property
        if category == "GENERATION_COMPLETE" {
            // Suppress if user is already viewing this conversation
            Task { @MainActor in
                if let conversationId, conversationId == self.activeConversationId {
                    completionHandler([])
                } else {
                    completionHandler([.banner, .sound])
                }
            }
        } else {
            // Suppress other notifications when app is in foreground
            completionHandler([])
        }
    }

    /// Handle notification tap or action button.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let conversationId = response.notification.request.content.userInfo["conversationId"] as? String

        Task { @MainActor in
            if actionId == Self.openChatAction || actionId == UNNotificationDefaultActionIdentifier {
                if let conversationId {
                    onOpenChat?(conversationId)
                }
            } else if actionId == Self.endCallAction {
                onEndCall?()
            }
        }

        completionHandler()
    }
}