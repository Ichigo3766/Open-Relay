import AppIntents
import Foundation

// MARK: - New Chat Intent

/// Siri shortcut to start a new chat conversation.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Start a new chat conversation with the AI assistant.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Post notification for app to handle
        await MainActor.run {
            NotificationCenter.default.post(
                name: .openUINewChat,
                object: nil
            )
        }
        return .result()
    }
}

// MARK: - Voice Call Intent

/// Siri shortcut to start a voice call with the AI assistant.
struct VoiceCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Voice Call"
    static var description = IntentDescription("Start a voice call with the AI assistant.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .openUIVoiceCall,
                object: nil
            )
        }
        return .result()
    }
}

// MARK: - Continue Last Conversation Intent

/// Siri shortcut to continue the last active conversation.
struct ContinueConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Last Conversation"
    static var description = IntentDescription("Continue your most recent chat conversation.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        let lastId = await SharedDataService.shared.lastActiveConversationId
        await MainActor.run {
            NotificationCenter.default.post(
                name: .openUIContinueConversation,
                object: lastId
            )
        }
        return .result()
    }
}

// MARK: - Create Note Intent

/// Siri shortcut to create a new note.
struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Note"
    static var description = IntentDescription("Create a new note in Open UI.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Title")
    var noteTitle: String?

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .openUICreateNote,
                object: noteTitle
            )
        }
        return .result()
    }
}

// MARK: - App Shortcuts Provider

/// Provides the app's shortcuts to the Shortcuts app and Siri.
struct OpenUIShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "Start a new chat in \(.applicationName)",
                "New conversation in \(.applicationName)",
                "Chat with \(.applicationName)"
            ],
            shortTitle: "New Chat",
            systemImageName: "bubble.left.and.text.bubble.right"
        )

        AppShortcut(
            intent: VoiceCallIntent(),
            phrases: [
                "Call \(.applicationName)",
                "Voice call with \(.applicationName)",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Voice Call",
            systemImageName: "phone.fill"
        )

        AppShortcut(
            intent: ContinueConversationIntent(),
            phrases: [
                "Continue my chat in \(.applicationName)",
                "Resume conversation in \(.applicationName)",
                "Go back to \(.applicationName)"
            ],
            shortTitle: "Continue Chat",
            systemImageName: "arrow.uturn.forward"
        )

        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New note in \(.applicationName)",
                "Take a note with \(.applicationName)"
            ],
            shortTitle: "New Note",
            systemImageName: "note.text"
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openUINewChat = Notification.Name("com.openui.intent.newChat")
    static let openUIVoiceCall = Notification.Name("com.openui.intent.voiceCall")
    static let openUIContinueConversation = Notification.Name("com.openui.intent.continueConversation")
    static let openUICreateNote = Notification.Name("com.openui.intent.createNote")
}

// MARK: - Shortcut Donation Helper

/// Donates app intents to Siri to improve suggestion relevance.
enum ShortcutDonationService {

    /// Donates the "New Chat" shortcut after the user creates a chat.
    static func donateNewChat() {
        let intent = NewChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "Voice Call" shortcut after the user makes a call.
    static func donateVoiceCall() {
        let intent = VoiceCallIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "Continue Conversation" shortcut when the user chats.
    static func donateContinueConversation() {
        let intent = ContinueConversationIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "Create Note" shortcut when the user creates notes.
    static func donateCreateNote() {
        let intent = CreateNoteIntent()
        Task {
            try? await intent.donate()
        }
    }
}
