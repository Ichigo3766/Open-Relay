import AppIntents
import Foundation
import UIKit

// MARK: - New Chat Intent

/// Siri shortcut / Shortcuts app: start a new chat with keyboard focus.
/// Mirrors the widget "Ask Open Relay" bar and the home-screen quick action.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Start a new chat conversation with the AI assistant.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
        }
        return .result()
    }
}

// MARK: - Voice Call Intent

/// Siri shortcut / Shortcuts app: start a voice call with the AI assistant.
/// Mirrors the widget mic button and the home-screen "Voice Call" quick action.
struct VoiceCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Voice Call"
    static var description = IntentDescription("Start a voice call with the AI assistant.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
        }
        return .result()
    }
}

// MARK: - Camera Chat Intent

/// Siri shortcut / Shortcuts app: open a new chat and immediately launch the camera.
/// Mirrors the widget camera button and the home-screen "Camera Chat" quick action.
struct CameraChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Camera Chat"
    static var description = IntentDescription("Start a new chat and open the camera to attach a photo.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUICameraChat, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - Photos Chat Intent

/// Siri shortcut / Shortcuts app: open a new chat and immediately launch the photo picker.
/// Mirrors the widget photos button.
struct PhotosChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Photos Chat"
    static var description = IntentDescription("Start a new chat and open Photos to attach an image.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIPhotosChat, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - File Chat Intent

/// Siri shortcut / Shortcuts app: open a new chat and immediately launch the file picker.
/// Mirrors the widget file/paperclip button.
struct FileChatIntent: AppIntent {
    static var title: LocalizedStringResource = "File Chat"
    static var description = IntentDescription("Start a new chat and open Files to attach a document.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIFileChat, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - Ask Intent

/// Siri shortcut / Shortcuts app: open a new chat with a pre-filled prompt,
/// optional model selection, and optional auto-send.
///
/// Enables power-user workflows like:
/// - Raycast: `open "openui://new-chat?prompt=\(query)&send=true"`
/// - Apple Shortcuts: "Ask Open Relay to [prompt]"
/// - Siri: "Ask Open Relay to summarise my notes"
struct AskIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Open Relay"
    static var description = IntentDescription(
        "Open a new chat with a pre-filled prompt. Optionally specify a model and whether to send immediately."
    )
    static var openAppWhenRun: Bool = true

    /// The prompt text to pre-fill in the chat input.
    @Parameter(title: "Prompt", description: "The message to send to the AI assistant.")
    var prompt: String

    /// Optional model ID to select (e.g. "gpt-4o", "claude-3-5-sonnet"). Leave blank to use the default.
    @Parameter(title: "Model ID", description: "The model to use (optional). Leave blank to use your default model.", default: "")
    var modelId: String

    /// When true, the message is sent automatically without requiring the user to tap Send.
    @Parameter(title: "Auto-send", description: "If enabled, the prompt is sent immediately when the app opens.", default: false)
    var autoSend: Bool

    func perform() async throws -> some IntentResult {
        // Build a URL that routes through the existing handleDeepLink() infrastructure.
        // This ensures all timing, validation, and notification-posting logic is shared
        // with the URL scheme path — no duplicate logic here.
        var components = URLComponents()
        components.scheme = "openui"
        components.host = "new-chat"
        var items: [URLQueryItem] = []
        let trimmedPrompt = String(prompt.prefix(4000))
        if !trimmedPrompt.isEmpty {
            items.append(URLQueryItem(name: "prompt", value: trimmedPrompt))
        }
        let trimmedModel = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            items.append(URLQueryItem(name: "model", value: trimmedModel))
        }
        if autoSend && !trimmedPrompt.isEmpty {
            items.append(URLQueryItem(name: "send", value: "true"))
        }
        components.queryItems = items.isEmpty ? nil : items

        // If we can build a valid URL, open it so the app processes it through
        // the standard handleDeepLink() path. Fallback: post the notification directly.
        if let url = components.url {
            await MainActor.run {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        } else {
            await MainActor.run {
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - New Channel Intent

/// Siri shortcut / Shortcuts app: open the create-channel sheet.
/// Mirrors the widget channel button and the home-screen "New Channel" quick action.
struct NewChannelIntent: AppIntent {
    static var title: LocalizedStringResource = "New Channel"
    static var description = IntentDescription("Open the create-channel sheet in Open Relay.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    // Widget deep links — trigger attachment pickers directly on new chat open
    static let openUICameraChat  = Notification.Name("com.openui.widget.cameraChat")
    static let openUIPhotosChat  = Notification.Name("com.openui.widget.photosChat")
    static let openUIFileChat    = Notification.Name("com.openui.widget.fileChat")
    // Photo picker confirmed at window level — userInfo["assets"] = [PHAsset]
    static let openUIPhotoPickerConfirm = Notification.Name("com.openui.photoPicker.confirm")
    // Widget deep link — open create-channel sheet
    static let openUINewChannel  = Notification.Name("com.openui.widget.newChannel")
    // Widget deep link — start a new chat AND auto-focus the input field (show keyboard)
    static let openUINewChatWithFocus    = Notification.Name("com.openui.widget.newChatWithFocus")
    // Widget deep link — start a voice call from widget mic button
    static let openUIWidgetVoiceCall     = Notification.Name("com.openui.widget.voiceCall")
    // Internal relay: MainChatView → ChatInputField to request keyboard focus
    static let chatInputFieldRequestFocus = Notification.Name("com.openui.input.requestFocus")
    /// Fired from the folder workspace chat list when the user taps a recent chat row.
    /// Object: the conversation ID (String).
    static let folderWorkspaceChatSelected = Notification.Name("com.openui.folder.chatSelected")
    // Broadcast: dismiss all presented overlays (camera, file picker, voice call, sheets)
    // before starting a new quick action to prevent stacking.
    static let openUIDismissOverlays = Notification.Name("com.openui.dismissOverlays")
    // Posted after a successful account switch so MainChatView/iPadMainChatView
    // immediately reload conversations, folders, and channels for the new account.
    static let openUIAccountSwitched = Notification.Name("com.openui.accountSwitched")
    // Deep link: open a specific existing conversation by ID.
    // `object` is the conversation ID string.
    // Used by openui://chat/<id> so external sources (Home Assistant, Shortcuts, etc.)
    // can land the user directly in a specific chat.
    static let openUINavigateToChat = Notification.Name("com.openui.navigateToChat")
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

    /// Donates the "Camera Chat" shortcut when the user uses the camera.
    static func donateCameraChat() {
        let intent = CameraChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "Photos Chat" shortcut when the user attaches photos.
    static func donatePhotosChat() {
        let intent = PhotosChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "File Chat" shortcut when the user attaches files.
    static func donateFileChat() {
        let intent = FileChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "New Channel" shortcut when the user creates a channel.
    static func donateNewChannel() {
        let intent = NewChannelIntent()
        Task {
            try? await intent.donate()
        }
    }
}
