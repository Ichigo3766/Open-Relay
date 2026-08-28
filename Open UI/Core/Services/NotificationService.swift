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

    /// Category for channel message notifications.
    static let channelMessageCategory = "CHANNEL_MESSAGE"

    /// Category for streaming interrupted notifications.
    static let streamingInterruptedCategory = "STREAMING_INTERRUPTED"

    /// Action to open the chat from a notification.
    static let openChatAction = "OPEN_CHAT"

    /// Action to end a voice call from a notification.
    static let endCallAction = "END_CALL"

    /// Action to open a channel from a notification.
    static let openChannelAction = "OPEN_CHANNEL"

    // MARK: - State

    /// Whether the user has granted notification permission.
    private(set) var isAuthorized = false

    /// The conversation ID the user is currently viewing.
    /// Set by ChatDetailView on appear/disappear. When a generation
    /// notification arrives for this conversation, it is suppressed
    /// since the user is already looking at it.
    /// nonisolated(unsafe) allows the willPresent delegate (nonisolated) to read
    /// these values without hopping to the main actor, which would defer the
    /// UNUserNotificationCenter completionHandler callback. These are only ever
    /// written on the main thread; the worst-case torn read is a suppression
    /// decision error, not a crash.
    nonisolated(unsafe) var activeConversationId: String?

    /// The channel ID the user is currently viewing.
    /// Set by ChannelDetailView on appear/disappear. When a channel
    /// notification arrives for this channel, it is suppressed in foreground
    /// since the user is already looking at it.
    nonisolated(unsafe) var activeChannelId: String?

    /// When true, the next generation-complete notification bypasses the
    /// activeConversationId suppression check. Used by recoverFromBackgroundStreaming
    /// so the user always gets a banner when they return to the app after a
    /// response completed while they were away — even if they are currently
    /// looking at that chat.
    nonisolated(unsafe) var bypassActiveConversationSuppression: Bool = false

    /// Callback when user taps a notification action.
    var onOpenChat: ((String) -> Void)?
    var onEndCall: (() -> Void)?
    var onOpenChannel: ((String) -> Void)?

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

        let openChannelAction = UNNotificationAction(
            identifier: Self.openChannelAction,
            title: "Open Channel",
            options: [.foreground]
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

        let channelCategory = UNNotificationCategory(
            identifier: Self.channelMessageCategory,
            actions: [openChannelAction],
            intentIdentifiers: [],
            options: []
        )

        let interruptedCategory = UNNotificationCategory(
            identifier: Self.streamingInterruptedCategory,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([
            generationCategory,
            voiceCallCategory,
            channelCategory,
            interruptedCategory
        ])

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
    /// Uses a stable per-conversation identifier (`"generation-<conversationId>"`) so that if
    /// the background polling loop and the foreground recovery path both fire for the same
    /// conversation, the second delivery **replaces** the first banner rather than creating a
    /// duplicate. This is the correct UNUserNotificationCenter behaviour: posting to the same
    /// identifier atomically replaces any pending or delivered notification with that ID.
    ///
    /// - Parameters:
    ///   - conversationId: The ID of the conversation that completed.
    ///   - title: The conversation title.
    ///   - preview: A short preview of the generated response.
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

        // Truncate to ~120 chars for the preview snippet
        let showPreview = UserDefaults.standard.bool(forKey: "notificationShowResponsePreview")
        let bodyText: String
        if showPreview {
            let cleaned = Self.stripThinkingAndToolBlocks(from: preview)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = cleaned.prefix(120)
            bodyText = snippet.isEmpty
                ? "Response is ready"
                : (snippet.count < cleaned.count ? "\(snippet)…" : String(snippet))
        } else {
            bodyText = "Response is ready"
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = bodyText
        content.sound = .default
        content.categoryIdentifier = Self.generationCompleteCategory
        content.userInfo = ["conversationId": conversationId]
        content.threadIdentifier = conversationId

        // Increment the app badge count for each new generation notification.
        // Uses our own UserDefaults counter because badgeCount() requires iOS 17+.
        content.badge = Self.incrementBadgeCount() as NSNumber

        // Use trigger: nil (immediate delivery).
        // The 2-second delay was intended to let the user background the app
        // first, but it was the PRIMARY cause of missed notifications:
        // when iOS suspends the process after endBackgroundTask(), any pending
        // time-interval triggers are cancelled. With trigger: nil the notification
        // is delivered to the system immediately and survives process suspension.
        // The willPresent delegate already handles foreground suppression — if
        // the user is still viewing the chat, it returns [] (no banner), so
        // there is no visual noise when the notification fires while in-app.
        //
        // STABLE IDENTIFIER: "generation-<conversationId>" (no timestamp).
        // This ensures a second delivery for the same conversation replaces the
        // first rather than stacking up as a duplicate banner. The previous
        // approach used a unique ID per delivery ("generation-<id>-<timestamp>"),
        // which meant background polling + foreground recovery could each fire a
        // separate notification for the same completed response.
        let request = UNNotificationRequest(
            identifier: "generation-\(conversationId)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            logger.info("Generation notification delivered for \(conversationId)")
        } catch {
            logger.error("Failed to deliver generation notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Streaming Interrupted

    /// Fires when the iOS background task budget expires while an AI response is still
    /// in progress. Informs the user that their response was cut off and invites them
    /// back into the app to retry or view the partial result.
    ///
    /// Unlike `notifyGenerationComplete`, this notification uses a DIFFERENT identifier
    /// so it doesn't replace a successful completion notification if both fire (unlikely,
    /// but possible in a race between expiration and normal completion).
    func notifyStreamingInterrupted(conversationId: String, title: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Response was interrupted — tap to continue"
        content.sound = .default
        content.categoryIdentifier = Self.streamingInterruptedCategory
        content.userInfo = ["conversationId": conversationId]
        content.threadIdentifier = conversationId
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "interrupted-\(conversationId)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            logger.info("Streaming interrupted notification delivered for \(conversationId)")
        } catch {
            logger.error("Failed to deliver interrupted notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Preview Cleaning

    /// Removes thinking/reasoning blocks and tool-call `<details>` blocks from
    /// raw AI content so only the main response text appears in notifications.
    ///
    /// Handles:
    /// - Raw model tags: `<think>`, `<thinking>`, `<reasoning>`, `<reason>`,
    ///   `<thought>`, `<|begin_of_thought|>`, `◁think▷` (and closing variants)
    /// - Server-normalised: `<details type="reasoning">…</details>`
    /// - Tool-call blocks: `<details>…</details>` (any remaining)
    private static func stripThinkingAndToolBlocks(from content: String) -> String {
        var result = content

        // 1. <details …>…</details> blocks (reasoning + tool calls)
        if let detailsRegex = try? NSRegularExpression(
            pattern: #"<details[^>]*>[\s\S]*?</details>"#,
            options: [.caseInsensitive]
        ) {
            result = detailsRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // 2. Raw model reasoning tags
        let rawTagPairs: [(String, String)] = [
            ("<|begin_of_thought|>", "<|end_of_thought|>"),
            ("◁think▷", "◁/think▷"),
            ("<thinking>", "</thinking>"),
            ("<reasoning>", "</reasoning>"),
            ("<thought>", "</thought>"),
            ("<reason>", "</reason>"),
            ("<think>", "</think>"),
        ]
        for (open, close) in rawTagPairs {
            guard result.contains(open) else { continue }
            let escapedOpen = NSRegularExpression.escapedPattern(for: open)
            let escapedClose = NSRegularExpression.escapedPattern(for: close)
            // Complete pairs
            if let regex = try? NSRegularExpression(
                pattern: "\(escapedOpen)[\\s\\S]*?\(escapedClose)",
                options: [.caseInsensitive]
            ) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
            // Unclosed opening tag (still streaming) — strip from tag to end
            if result.range(of: open, options: .caseInsensitive) != nil {
                if let escapedOpenRegex = try? NSRegularExpression(
                    pattern: "\(escapedOpen)[\\s\\S]*$",
                    options: [.caseInsensitive]
                ) {
                    result = escapedOpenRegex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: ""
                    )
                }
            }
        }

        return result
    }

    // MARK: - Channel Messages

    /// Sends a local notification for a new channel message received while the
    /// user is not actively viewing that channel.
    ///
    /// - Parameters:
    ///   - channelId: The ID of the channel that received the message.
    ///   - channelName: The display name of the channel (e.g. "#general" or "Alice").
    ///   - senderName: The display name of the message sender.
    ///   - preview: A short preview of the message content.
    func notifyChannelMessage(
        channelId: String,
        channelName: String,
        senderName: String,
        preview: String
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = channelName
        content.body = preview.isEmpty ? senderName : "\(senderName): \(preview)"
        content.sound = .default
        content.categoryIdentifier = Self.channelMessageCategory
        content.userInfo = ["channelId": channelId]
        content.threadIdentifier = "channel-\(channelId)"

        // Increment app badge for each channel message too
        content.badge = Self.incrementBadgeCount() as NSNumber

        // Use a stable identifier keyed by channel + sender so rapid messages
        // from the same person replace rather than stack up as a pile of banners.
        // Using just "channel-<channelId>-<senderName>" means each sender in a
        // channel gets their own slot — multiple senders each show one banner.
        let stableSenderId = senderName
            .lowercased()
            .components(separatedBy: .whitespaces)
            .joined(separator: "_")
        let request = UNNotificationRequest(
            identifier: "channel-\(channelId)-\(stableSenderId)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            logger.info("Channel notification delivered for \(channelId)")
        } catch {
            logger.error("Failed to deliver channel notification: \(error.localizedDescription)")
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

    // MARK: - Badge Management

    /// Local badge counter — incremented per notification delivery and cleared on tap or foreground.
    /// We track this ourselves because `UNUserNotificationCenter.badgeCount()` requires iOS 17+
    /// and `UIApplication.applicationIconBadgeNumber` requires the main thread.
    nonisolated private static let badgeCountKey = "notificationBadgeCount"

    /// Returns the current tracked badge count.
    nonisolated private static func currentBadgeCount() -> Int {
        UserDefaults.standard.integer(forKey: badgeCountKey)
    }

    /// Increments the tracked badge count by 1 and returns the new value.
    nonisolated private static func incrementBadgeCount() -> Int {
        let newCount = currentBadgeCount() + 1
        UserDefaults.standard.set(newCount, forKey: badgeCountKey)
        return newCount
    }

    /// Resets the tracked badge count to 0 and clears the iOS icon badge.
    func clearBadge() {
        UserDefaults.standard.set(0, forKey: Self.badgeCountKey)
        UNUserNotificationCenter.current().setBadgeCount(0) { [weak self] error in
            if let error {
                self?.logger.error("Failed to clear badge: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Utility

    /// Clears all delivered notifications and resets the badge.
    func clearAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        clearBadge()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {

    /// Handle notification when app is in foreground.
    ///
    /// This delegate method is called synchronously on a background thread — we must
    /// call `completionHandler` as quickly as possible. We read the cached @MainActor
    /// state via a synchronous check to avoid the latency penalty of dispatching back to
    /// the main actor (which would defer the completion handler until the next run loop
    /// cycle, making the notification appear stale or delayed).
    ///
    /// Because NotificationService is @MainActor and declared @unchecked Sendable, reading
    /// `activeConversationId`, `activeChannelId`, and `bypassActiveConversationSuppression`
    /// from a nonisolated context is technically a data race under strict concurrency.
    /// We accept this with `nonisolated(unsafe)` backing storage (inherited from @Observable)
    /// because:
    ///   1. These are only ever mutated on the main thread.
    ///   2. The worst outcome of a torn read is an occasional incorrect suppression decision —
    ///      a minor cosmetic issue, not a crash or data corruption.
    ///   3. The alternative (Task { @MainActor }) reliably calls completionHandler after the
    ///      run loop, which Apple's documentation flags as undesirable for willPresent.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        let conversationId = notification.request.content.userInfo["conversationId"] as? String
        let channelId = notification.request.content.userInfo["channelId"] as? String

        // Read the cached main-actor state synchronously. This is safe because:
        // - These properties are only written on the main thread.
        // - The read here is a single memory load per property (no compound operation).
        // - We never write these properties from this method.
        let currentConversationId = activeConversationId
        let currentChannelId = activeChannelId
        let bypass = bypassActiveConversationSuppression

        switch category {
        case Self.generationCompleteCategory:
            if bypass {
                // One-shot bypass: clear the flag on the main actor then show the banner
                Task { @MainActor [weak self] in
                    self?.bypassActiveConversationSuppression = false
                }
                completionHandler([.banner, .sound])
            } else if let conversationId, conversationId == currentConversationId {
                // User is already looking at this chat — suppress banner but update badge
                completionHandler([.badge])
            } else {
                completionHandler([.banner, .sound, .badge])
            }

        case Self.channelMessageCategory:
            if let channelId, channelId == currentChannelId {
                // User is already viewing this channel — suppress
                completionHandler([])
            } else {
                completionHandler([.banner, .sound, .badge])
            }

        case Self.streamingInterruptedCategory:
            // Always show interrupted notifications — even if user is on that chat screen,
            // they should know the response didn't complete. No badge — it's not new content.
            completionHandler([.banner, .sound])

        default:
            // Suppress other notification types (e.g. voice call ongoing) in foreground
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
        let channelId = response.notification.request.content.userInfo["channelId"] as? String
        let category = response.notification.request.content.categoryIdentifier

        Task { @MainActor in
            // Clear badge when user taps a notification — they're now looking at the app
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }

            if actionId == Self.openChatAction
                || (actionId == UNNotificationDefaultActionIdentifier
                    && (category == Self.generationCompleteCategory
                        || category == Self.streamingInterruptedCategory)) {
                if let conversationId {
                    onOpenChat?(conversationId)
                }
            } else if actionId == Self.openChannelAction
                || (actionId == UNNotificationDefaultActionIdentifier
                    && category == Self.channelMessageCategory) {
                if let channelId {
                    onOpenChannel?(channelId)
                }
            } else if actionId == Self.endCallAction {
                onEndCall?()
            }
        }

        completionHandler()
    }
}
