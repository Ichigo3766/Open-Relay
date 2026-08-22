import SwiftUI
import WidgetKit
import BackgroundTasks
import UIKit
import AVFoundation
import Photos

// MLX is always present when either audio framework is linked.
// Import it unconditionally so we can set Memory.cacheLimit at startup
// before the Metal GPU runtime inflates its buffer pool.
#if canImport(MLX)
import MLX
#endif

// MARK: - App Delegate + Scene Delegate (handles home screen Quick Actions)
//
// In a scene-based SwiftUI app (UIApplicationSceneManifest_Generation = YES),
// UIApplicationDelegate.performActionFor is NEVER called for shortcut items.
// iOS routes them to the UIWindowSceneDelegate instead:
//   • Cold launch  → scene(_:willConnectTo:options:)  (connectionOptions.shortcutItem)
//   • Warm launch  → windowScene(_:performActionFor:completionHandler:)

final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Pending shortcut action type string, set by the scene delegate.
    /// Consumed by the `scenePhase == .active` handler in `Open_UIApp`.
    static var pendingShortcutAction: String?

    /// Return a scene configuration that uses our custom SceneDelegate.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShortcutSceneDelegate.self
        return config
    }

    /// Called when the user explicitly force-quits the app (swipe up in the app switcher).
    /// NOT called when iOS silently kills the suspended process under memory pressure.
    ///
    /// This distinction is the key to the "restore where you left off" behaviour:
    /// - Force quit → this fires → we clear lastActiveConversationId → next launch gets new chat.
    /// - iOS background kill → this does NOT fire → lastActiveConversationId stays set → next
    ///   launch restores the user back into the chat they were in.
    func applicationWillTerminate(_ application: UIApplication) {
        SharedDataService.shared.saveLastActiveConversationId(nil)
    }
}

/// Scene delegate that intercepts shortcut items on both cold and warm launch.
final class ShortcutSceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// **Cold launch**: shortcut item arrives in connectionOptions.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem {
            AppDelegate.pendingShortcutAction = shortcutItem.type
        }
    }

    /// **Warm launch**: app already running / suspended when user taps a quick action.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        AppDelegate.pendingShortcutAction = shortcutItem.type
        completionHandler(true)
    }
}

@main
struct Open_UIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dependencies = AppDependencyContainer()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Limit the MLX Metal GPU buffer-recycling cache to 20 MB.
        //
        // By default, MLX sizes its cache to `recommendedMaxWorkingSetSize`, which
        // scales with device RAM (e.g. ~2 GB on an iPhone with 8 GB RAM). The cache
        // stays inflated even when no model is loaded, causing ~500 MB of "dirty"
        // memory at startup that iOS counts against our memory footprint. Setting a
        // small limit here means the cache is immediately trimmed on the next
        // deallocation event rather than staying large until the app backgrounds.
        //
        // 20 MB is the value from Apple's own MLX iOS guide. It's enough for smooth
        // TTS/ASR inference without the startup memory spike.
        #if canImport(MLX) && !targetEnvironment(simulator)
        Memory.cacheLimit = 20 * 1024 * 1024  // 20 MB
        #endif

        // Configure the AVAudioSession category baseline at launch so WKWebView
        // inherits the "ignore silent switch" behavior when its process is created.
        // NOTE: We do NOT call setActive(true) here — doing so at cold launch forces
        // iOS to immediately switch Bluetooth from A2DP (high-quality music) to HFP
        // (low-bitrate hands-free), which pauses or degrades music playing in the
        // background. The session activates lazily the first time TTS, voice call,
        // or WebView audio actually plays.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        )

        // Remove the default circular/pill-shaped backgrounds from navigation
        // bar toolbar buttons that iOS adds in dark mode (iOS 15+).
        let plainButtonAppearance = UIBarButtonItemAppearance(style: .plain)
        plainButtonAppearance.normal.titleTextAttributes = [:]
        plainButtonAppearance.highlighted.titleTextAttributes = [:]

        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.buttonAppearance = plainButtonAppearance
        navBarAppearance.doneButtonAppearance = plainButtonAppearance

        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
        // Force white window background in light mode so safe-area insets
        // never show the system grey instead of the app's #FFFFFF background.
        UIWindow.appearance().backgroundColor = .white
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(dependencies)
                .task {
                    // Wire the router into the dependency container so AuthViewModel
                    // can reset navigation on server switch (must be done after both
                    // objects are injected into the environment).
                    dependencies.router = router
                }
                .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        // Notify connection monitor that the app is in the foreground.
                        // This triggers an immediate health check + socket reconnect,
                        // cancelling any pending backoff timer so recovery is instant.
                        dependencies.connectionMonitor.markAppForeground()
                        dependencies.socketService?.resetBackoffAndReconnect()

                        // Re-check for app + server updates whenever the app returns
                        // to the foreground (handles the case where an update ships
                        // while the app is backgrounded). Fails silently on any error.
                        Task {
                            async let appCheck: () = dependencies.updateChecker.checkForUpdates()
                            async let serverCheck: () = dependencies.serverUpdateChecker.checkForUpdates(using: dependencies.apiClient)
                            _ = await (appCheck, serverCheck)
                        }

                        // Process pending actions after a short delay so that
                        // MainChatView / iPadMainChatView have time to mount
                        // their .onReceive handlers before we post notifications.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // 1. Quick Action from home screen long-press
                            if let action = AppDelegate.pendingShortcutAction {
                                AppDelegate.pendingShortcutAction = nil
                                handleShortcutAction(action)
                            }

                            // 2. Control Center widget action (cross-process via UserDefaults)
                            let defaults = UserDefaults(suiteName: SharedDataService.appGroupId)
                            if let ccAction = defaults?.string(forKey: "pendingControlCenterAction") {
                                defaults?.removeObject(forKey: "pendingControlCenterAction")
                                handleControlCenterAction(ccAction)
                            }

                            // 3. Pending shared content from Share Extension
                            if defaults?.data(forKey: "pending_shared_content") != nil {
                                handleSharedContent()
                            }
                        }
                    }
                    if newPhase == .inactive || newPhase == .background {
                        // Notify connection monitor + socket that we're backgrounding.
                        // Suppresses false "server down" overlays caused by the OS
                        // suspending network activity and cancels reconnect timers
                        // that would waste battery in the background.
                        dependencies.connectionMonitor.markAppBackground()
                        dependencies.socketService?.markAppBackground()
                        // Stop on-device TTS (Kokoro/Qwen3) before backgrounding to prevent
                        // Metal GPU crash (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted).
                        // .inactive fires before .background, giving us time to release GPU resources.
                        //
                        // Server TTS (AVQueuePlayer) is intentionally NOT stopped — it uses no GPU
                        // and continues playing in the background when UIBackgroundModes includes "audio".
                        let tts = dependencies.textToSpeechService
                        let session = AVAudioSession.sharedInstance()
                        print("🌙[APP] scenePhase=\(newPhase) — tts.activeEngine=\(tts.activeEngine) tts.state=\(tts.state)")
                        print("🌙[APP] AudioSession before BG — category=\(session.category.rawValue) mode=\(session.mode.rawValue) isActive=\(session.isOtherAudioPlaying)")
                        if tts.activeEngine == .kokoro || tts.activeEngine == .qwen3 {
                            print("🌙[APP] Stopping on-device TTS (Kokoro/Qwen3) before background")
                            tts.stop()
                        }
                        // Guard stopAndUnload() — it calls audioPlayer.stop() which calls
                        // AVAudioSession.setActive(false) on the shared session, killing
                        // AVQueuePlayer (server TTS) mid-playback. Skip it when server TTS
                        // is actively playing so background audio continues uninterrupted.
                        if tts.activeEngine != .server {
                            print("🌙[APP] Calling kokoroService.stopAndUnload() — engine is \(tts.activeEngine), not server")
                            tts.kokoroService.stopAndUnload()
                        } else {
                            print("🌙[APP] ✅ Skipping stopAndUnload() — server TTS is active, keeping audio session alive")
                        }
                        print("🌙[APP] AudioSession after BG handling — category=\(session.category.rawValue) mode=\(session.mode.rawValue)")

                        // ASR background safety: pause on-device transcription on iOS < 26.
                        //
                        // iOS < 26: Metal GPU access is forbidden in the background. Calling
                        // pauseForBackground() cancels the in-flight MLX task and unloads the
                        // model BEFORE iOS revokes GPU access, preventing the uncatchable
                        // std::runtime_error crash. ChatViewModel catches .backgroundInterrupted
                        // and auto-restarts transcription when the app returns to foreground.
                        //
                        // iOS 26+: BGContinuedProcessingTask + Background GPU Access entitlement
                        // keeps the GPU alive in the background, so pauseForBackground() is a
                        // no-op and transcription continues uninterrupted for minutes.
                        dependencies.asrService.pauseForBackground()

                        // STORAGE FIX: Run routine cleanup when entering background.
                        // Cleans orphaned temp files, prunes upload cache, evicts
                        // oversized image cache. Zero user intervention needed.
                        StorageManager.shared.performRoutineCleanup()
                    }
                }
                .task {
                    // STORAGE FIX: Run cleanup on app launch to handle accumulated
                    // data from previous sessions (orphaned files, stale caches, etc.)
                    StorageManager.shared.performRoutineCleanup()

                    // Initialize notification service: registers categories and
                    // requests permission if not yet determined. Also acts as a
                    // fallback safety net in notifyGenerationComplete() in case
                    // the user hasn't been prompted yet.
                    await NotificationService.shared.setup()

                    // Wire notification tap to router
                    NotificationService.shared.onOpenChat = { conversationId in
                        router.navigate(to: .chatDetail(conversationId: conversationId))
                    }

                    // Request Photos "add-only" permission at startup so that
                    // "Save to Photos" works the first time a user taps it.
                    // Uses .addOnly (not .readWrite) — we only ever write to Photos,
                    // never read the library. If already granted/denied, this is a no-op.
                    let photosStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                    if photosStatus == .notDetermined {
                        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    }
                }
                .onOpenURL { url in
                    if url.isFileURL {
                        handleIncomingFileURL(url)
                    } else {
                        handleDeepLink(url)
                    }
                }
        }
    }

    /// Handles a file URL received via "Open In" / document import from another app.
    /// Reads the file data, creates a ChatAttachment, and navigates to a new chat
    /// with the file pre-attached in the input field.
    private func handleIncomingFileURL(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"]
        let isImage = imageExts.contains(ext)

        let thumbnail: Image? = isImage ? UIImage(data: data).map { Image(uiImage: $0) } : nil
        let attachment = ChatAttachment(
            type: isImage ? .image : .file,
            name: fileName,
            thumbnail: thumbnail,
            data: data
        )

        dependencies.pendingIncomingFile = attachment
        dependencies.pendingIncomingFileVersion += 1
        dependencies.activeChatStore.remove(nil)
        router.navigate(to: .newChat)
    }

    /// Handles deep links from widgets and external sources.
    private func handleDeepLink(_ url: URL) {
        guard let host = url.host() else { return }

        switch host {
        case "new-chat":
            // Supports query parameters from external tools (Raycast, Shortcuts, Obsidian, etc.):
            //   openui://new-chat                           → new chat + keyboard focus
            //   openui://new-chat?prompt=Hello              → pre-fill input with "Hello"
            //   openui://new-chat?prompt=Hello&send=true    → pre-fill AND auto-send
            //   openui://new-chat?model=gpt-4o              → select specific model
            //   openui://new-chat?mode=voice-recording      → start voice recording
            //   openui://new-chat?prompt=X&model=Y&send=true → full combo
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []

            func queryValue(_ name: String) -> String? {
                queryItems.first(where: { $0.name == name })?.value
            }

            // --- mode=voice-recording ---
            if queryValue("mode") == "voice-recording" {
                NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
                ShortcutDonationService.donateVoiceCall()
                break
            }

            // Store values immediately (no version bumps yet — they fire after the view mounts)
            var hasPrompt = false
            if let rawPrompt = queryValue("prompt") {
                let prompt = String(rawPrompt.prefix(4000))
                if !prompt.isEmpty {
                    dependencies.pendingIncomingText = prompt
                    hasPrompt = true
                }
            }

            var hasModel = false
            if let modelId = queryValue("model"), !modelId.isEmpty {
                dependencies.pendingIncomingModelId = modelId
                hasModel = true
            }

            let shouldSend = queryValue("send") == "true" && hasPrompt
            if shouldSend { dependencies.pendingAutoSend = true }

            // Open a new chat FIRST — this mounts the new ChatDetailView
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            ShortcutDonationService.donateNewChat()

            // Defer version bumps so the new ChatDetailView has time to mount
            // and subscribe to .onChange before the values change
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if hasPrompt { dependencies.pendingIncomingTextVersion += 1 }
                if hasModel  { dependencies.pendingIncomingModelVersion += 1 }
                if shouldSend { dependencies.pendingAutoSendVersion += 1 }
            }

        case "voice-call":
            // Widget mic button → voice call. Posts a notification that
            // MainChatView/iPadMainChatView handle by creating a VoiceCallViewModel
            // and presenting it via router.presentVoiceCall(viewModel:).
            NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
            ShortcutDonationService.donateVoiceCall()

        case "new-note":
            router.navigate(to: .notesList)

        case "continue":
            if let conversationId = SharedDataService.shared.lastActiveConversationId {
                router.navigate(to: .chatDetail(conversationId: conversationId))
            }

        case "camera-chat":
            // Widget camera button → new chat + open camera immediately.
            // Posts newChatWithFocus first (MainChatView/iPadMainChatView handle
            // creating the new chat via local state), then after a delay posts
            // the camera notification which ChatDetailView handles.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUICameraChat, object: nil)
            }

        case "photos-chat":
            // Widget photos button → new chat + open photo picker immediately.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIPhotosChat, object: nil)
            }

        case "file-chat":
            // Widget files button → new chat + open file picker immediately.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIFileChat, object: nil)
            }

        case "new-channel":
            // Signal the main view to open the create-channel sheet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)
            }

        case "chat":
            // openui://chat/{conversationId}
            // FIX: Post a NotificationCenter notification so MainChatView /
            // iPadMainChatView can set their local activeConversationId state directly.
            // router.navigate(to: .chatDetail(...)) only pushes onto the NavigationStack
            // path which these views don't observe for active-conversation selection,
            // so it had no visible effect (issue #117).
            let conversationId = url.pathComponents.last ?? ""
            if !conversationId.isEmpty && conversationId != "/"
                && conversationId.count >= 8 && conversationId.count <= 128
                && conversationId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                // Persist so cold-start restore also lands in the right chat.
                SharedDataService.shared.saveLastActiveConversationId(conversationId)
                // Delay matches other deep-link notifications (camera-chat etc.) so the
                // .onReceive handlers are registered before the notification fires.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .openUINavigateToChat, object: conversationId)
                }
            }

        case "note":
            // openui://note/{noteId}
            // FIX: Validate note ID format before navigating.
            let noteId = url.pathComponents.last ?? ""
            if !noteId.isEmpty && noteId != "/"
                && noteId.count >= 8 && noteId.count <= 128
                && noteId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                router.navigate(to: .noteEditor(noteId: noteId))
            }

        case "shared-content":
            // openui://shared-content
            // Posted by the Share Extension after writing SharedContent to App Group UserDefaults.
            // Delay slightly so the main app has time to finish launching / foregrounding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                handleSharedContent()
            }

        default:
            break
        }
    }

    /// Reads SharedContent written by the Share Extension, converts it to
    /// chat attachments / input text, and opens a new chat.
    private func handleSharedContent() {
        guard let content = dependencies.processPendingSharedContent() else { return }

        var attachments: [ChatAttachment] = []
        var inputText: String = ""

        // --- Files / images ---
        for sharedFile in content.fileAttachments {
            let ext = URL(fileURLWithPath: sharedFile.name).pathExtension.lowercased()
            let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"]
            let isImage = imageExts.contains(ext)
                || sharedFile.mimeType?.hasPrefix("image/") == true
            let thumbnail: Image? = isImage
                ? UIImage(data: sharedFile.data).map { Image(uiImage: $0) }
                : nil
            attachments.append(ChatAttachment(
                type: isImage ? .image : .file,
                name: sharedFile.name,
                thumbnail: thumbnail,
                data: sharedFile.data
            ))
        }

        // --- Legacy image data (older extension builds) ---
        for imageData in content.imageData {
            let thumbnail = UIImage(data: imageData).map { Image(uiImage: $0) }
            attachments.append(ChatAttachment(
                type: .image,
                name: "image.jpg",
                thumbnail: thumbnail,
                data: imageData
            ))
        }

        // --- URLs → web-scraping pipeline (scrape + upload, not plain text) ---
        // processWebURL() is called in ChatDetailView via applyShareExtensionHandlers
        // once the new chat is open and the view model is ready.
        let urlStrings = content.urls
        if !urlStrings.isEmpty {
            dependencies.pendingIncomingWebURLs = urlStrings
            dependencies.pendingIncomingWebURLsVersion += 1
        }

        // --- Plain text ---
        if let text = content.text, !text.isEmpty {
            inputText = text
        }

        // If we have attachments, inject the first one as pendingIncomingFile and
        // store the rest in pendingIncomingExtraAttachments. Then open a new chat.
        if let first = attachments.first {
            dependencies.pendingIncomingFile = first
            // Store any additional attachments (multi-file share)
            if attachments.count > 1 {
                dependencies.pendingIncomingExtraAttachments = Array(attachments.dropFirst())
            }
            dependencies.pendingIncomingFileVersion += 1
        }

        if !inputText.isEmpty {
            dependencies.pendingIncomingText = inputText
            dependencies.pendingIncomingTextVersion += 1
        }

        dependencies.activeChatStore.remove(nil)
        router.navigate(to: .newChat)
    }

    // MARK: - Overlay Dismissal

    /// Dismisses all presented overlays (camera, file picker, voice call, sheets, etc.)
    /// before starting a new quick action so they don't stack on top of each other.
    /// Posts a broadcast notification that ChatDetailView, MainChatView, and
    /// iPadMainChatView each listen for to reset their local overlay booleans.
    private func dismissAllOverlays() {
        NotificationCenter.default.post(name: .openUIDismissOverlays, object: nil)
        router.dismissVoiceCall()
        router.dismissSheet()
    }

    // MARK: - Quick Action Handlers

    /// Maps a `UIApplicationShortcutItemType` string (from Info.plist) to the
    /// corresponding NotificationCenter post so MainChatView / iPadMainChatView
    /// can react. Called from the `scenePhase == .active` handler after a delay.
    private func handleShortcutAction(_ type: String) {
        // Dismiss any existing overlays first so new action doesn't stack
        dismissAllOverlays()

        // Short delay to let SwiftUI animate the dismissal before presenting new overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch type {
            case "com.openui.openui.new-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                ShortcutDonationService.donateNewChat()

            case "com.openui.openui.voice-call":
                NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
                ShortcutDonationService.donateVoiceCall()

            case "com.openui.openui.camera-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .openUICameraChat, object: nil)
                }

            case "com.openui.openui.new-channel":
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)

            default:
                break
            }
        }
    }

    /// Handles a pending action written to shared UserDefaults by the
    /// Control Center widget extension (runs in a separate process).
    private func handleControlCenterAction(_ action: String) {
        // Dismiss any existing overlays first so new action doesn't stack
        dismissAllOverlays()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch action {
            case "new-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                ShortcutDonationService.donateNewChat()
            default:
                break
            }
        }
    }
}

// MARK: - App Launch Screen

/// Animated launch screen shown during app startup (session validation / restore).
/// Fades away smoothly to reveal the chat view underneath — no jarring swap.
private struct AppLaunchView: View {
    @Environment(\.theme) private var theme

    // Entry animation state
    @State private var logoScale: CGFloat = 0.82
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var textOffset: CGFloat = 18
    @State private var dotsOpacity: Double = 0

    // Rotating arc
    @State private var arcRotation: Double = 0

    // Bloom pulse
    @State private var bloomScale: CGFloat = 1.0
    @State private var bloomOpacity: Double = 0.18

    // Shimmer sweep
    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        ZStack {
            // ── Background: deep layered gradient ──
            launchBackground

            // ── Center content ──
            VStack(spacing: 0) {
                Spacer()

                // Logo card
                ZStack {
                    // Outer bloom glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [theme.brandPrimary.opacity(bloomOpacity), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 90
                            )
                        )
                        .frame(width: 180, height: 180)
                        .scaleEffect(bloomScale)
                        .blur(radius: 8)

                    // Rotating conic arc ring
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(
                            AngularGradient(
                                colors: [theme.brandPrimary.opacity(0.9), theme.brandPrimary.opacity(0.0)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: 118, height: 118)
                        .rotationEffect(.degrees(arcRotation))

                    // Static thin outer ring
                    Circle()
                        .stroke(theme.brandPrimary.opacity(0.12), lineWidth: 1)
                        .frame(width: 118, height: 118)

                    // Glass card behind icon
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 88, height: 88)
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.25),
                                            Color.white.opacity(0.05),
                                            theme.brandPrimary.opacity(0.15)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: theme.brandPrimary.opacity(0.25), radius: 20, x: 0, y: 8)
                        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)

                    // App icon
                    Image("AppIconImage")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                // ── Wordmark ──
                VStack(spacing: 8) {
                    ZStack {
                        // Base text
                        Text("Open Relay")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                            .foregroundStyle(theme.textPrimary)

                        // Shimmer overlay
                        Text("Open Relay")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.white.opacity(0.7),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .mask(
                                Rectangle()
                                    .frame(width: 80, height: 60)
                                    .offset(x: shimmerOffset)
                            )
                    }
                    .padding(.top, 32)

                    // Subtitle / tagline
                    Text("Your AI, Everywhere")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(theme.textTertiary)
                }
                .opacity(textOpacity)
                .offset(y: textOffset)

                Spacer()

                // ── Loading dots ──
                LaunchLoadingDots(color: theme.brandPrimary)
                    .opacity(dotsOpacity)
                    .padding(.bottom, 56)
            }
        }
        .onAppear {
            // Staggered entry
            withAnimation(.spring(response: 0.65, dampingFraction: 0.72).delay(0.05)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.55).delay(0.3)) {
                textOpacity = 1.0
                textOffset = 0
            }
            withAnimation(.easeIn(duration: 0.4).delay(0.55)) {
                dotsOpacity = 1.0
            }

            // Continuously rotate the arc
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                arcRotation = 360
            }

            // Bloom pulse
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                bloomScale = 1.15
                bloomOpacity = 0.28
            }

            // Shimmer sweep (runs once after logo appears)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 1.1)) {
                    shimmerOffset = 260
                }
            }
        }
    }

    @ViewBuilder
    private var launchBackground: some View {
        // Deep base
        Color.black.ignoresSafeArea()

        // Layered radial glows for depth
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Top-left teal glow
                RadialGradient(
                    colors: [theme.brandPrimary.opacity(0.22), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: w * 0.65
                )
                .frame(width: w * 1.1, height: w * 1.1)
                .position(x: w * 0.15, y: h * 0.18)
                .blur(radius: 10)

                // Bottom-right secondary glow
                RadialGradient(
                    colors: [theme.info.opacity(0.14), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: w * 0.55
                )
                .frame(width: w * 0.9, height: w * 0.9)
                .position(x: w * 0.85, y: h * 0.78)
                .blur(radius: 14)

                // Center very subtle warmth
                RadialGradient(
                    colors: [theme.brandPrimary.opacity(0.06), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: w * 0.45
                )
                .frame(width: w, height: w)
                .position(x: w * 0.5, y: h * 0.45)
            }
        }
        .ignoresSafeArea()
    }
}

/// Three-dot pulsing loading indicator for the launch screen.
private struct LaunchLoadingDots: View {
    let color: Color
    @State private var phase = 0

    private let dotSize: CGFloat = 5
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color.opacity(phase == i ? 0.9 : 0.25))
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(phase == i ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.35), value: phase)
            }
        }
        .onAppear {
            // Cycle through dots
            Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}

/// Launch screen that shows error + retry when session restore fails.
private struct AppLaunchErrorView: View {
    let error: String
    let onRetry: () -> Void
    let onSwitchAccount: () -> Void
    @Environment(\.theme) private var theme

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Same modern background
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                RadialGradient(
                    colors: [theme.error.opacity(0.18), .clear],
                    center: .center, startRadius: 0, endRadius: w * 0.65
                )
                .frame(width: w * 1.1, height: w * 1.1)
                .position(x: w * 0.5, y: h * 0.3)
                .blur(radius: 12)
            }
            .ignoresSafeArea()

            VStack(spacing: 20) {
                // Error icon in glass card
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 76, height: 76)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(theme.error.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: theme.error.opacity(0.2), radius: 16, x: 0, y: 6)

                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(theme.error)
                }
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text("Connection Issue")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)

                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)

                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                            Text("Try Again")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        .frame(minWidth: 160)
                        .frame(height: 52)
                        .foregroundStyle(theme.buttonPrimaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(theme.buttonPrimary)
                                .shadow(color: theme.buttonPrimary.opacity(0.4), radius: 12, x: 0, y: 4)
                        )
                    }

                    Button("Sign in with a different account", action: onSwitchAccount)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .padding(.top, 6)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75).delay(0.1)) {
                appeared = true
            }
        }
    }
}

/// Root view that manages the full authentication flow using a phase-based state machine.
struct RootView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var hasAttemptedRestore = false
    /// Controls the "Switch Server" sheet presented from the connection overlay.
    @State private var showServerSwitcherSheet = false

    // Launch overlay — starts visible for any startup path that needs validation.
    // Set to true only when we begin from an authenticated/restoring phase (i.e. a
    // saved session exists). Fades out smoothly once validation/restore is complete.
    @State private var launchOverlayVisible: Bool
    // Separate opacity so we can animate the fade independently of visibility.
    @State private var launchOverlayOpacity: Double

    init() {
        // We need to decide at init time (before the view mounts) whether to
        // show the launch overlay. If the app is starting into an auth-needing
        // state (serverConnection, authMethodSelection etc.) we skip it.
        // Only optimistic-auth and restoring-session paths need it.
        // We can't access @Environment here, so we peek at the raw UserDefaults/
        // Keychain state. The easiest proxy is to check the ServerConfigStore directly.
        let store = ServerConfigStore()
        let needsOverlay: Bool
        if let active = store.activeServer {
            needsOverlay = KeychainService.shared.hasToken(forServer: active.url)
        } else {
            needsOverlay = false
        }
        _launchOverlayVisible = State(initialValue: needsOverlay)
        _launchOverlayOpacity = State(initialValue: needsOverlay ? 1.0 : 0.0)
    }

    private var viewModel: AuthViewModel {
        dependencies.authViewModel
    }

    var body: some View {
        ZStack {
            // ── Background layer: the full phase-based content ──
            phaseContent
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.phase)

            // ── Foreground layer: launch overlay (fades out on top) ──
            if launchOverlayVisible {
                launchOverlay
                    .opacity(launchOverlayOpacity)
                    .ignoresSafeArea()
                    // Disable interaction once fading so the chat underneath is tappable
                    .allowsHitTesting(launchOverlayOpacity > 0.05)
            }
        }
        .task {
            viewModel.runLegacyMigrationIfNeeded()

            guard !hasAttemptedRestore else { return }
            hasAttemptedRestore = true

            guard dependencies.serverConfigStore.activeServer != nil else {
                dismissLaunchOverlay()
                return
            }

            switch viewModel.phase {
            case .authenticated:
                // Optimistic auth — chat view is already rendered underneath the overlay.
                // Fire-and-forget background validation — never needs to block the overlay.
                Task { await viewModel.validateSessionInBackground() }
                // Await model prefetch with its built-in 3 s timeout (races loadModels()
                // against Task.sleep — whichever finishes first wins). This ensures the
                // model selector is already populated when the overlay fades, so the UI
                // appears fully ready with no post-reveal flicker or loading state.
                await dependencies.activeChatStore.prewarmModels(using: dependencies)
                dismissLaunchOverlay()

            case .restoringSession:
                // Token exists but no cached user — restore session with a hard 6 s
                // timeout so the launch screen is never permanently stuck.
                // Whether the restore succeeds or times out, we always dismiss the
                // overlay; if it failed the ConnectionMonitor will surface its overlay.
                await viewModel.withAuthTimeout(seconds: 6) {
                    await viewModel.restoreSession()
                    return ()
                }
                // Await model prefetch with its built-in 3 s timeout so the overlay
                // only fades once models are ready (or 3 s have passed on slow servers).
                await dependencies.activeChatStore.prewarmModels(using: dependencies)
                dismissLaunchOverlay()

            case .authMethodSelection:
                await viewModel.fetchBackendConfigIfNeeded()
                dismissLaunchOverlay()

            default:
                dismissLaunchOverlay()
            }
        }
    }

    /// Fades the launch overlay out smoothly.
    private func dismissLaunchOverlay() {
        withAnimation(.easeInOut(duration: 0.45)) {
            launchOverlayOpacity = 0.0
        }
        // Remove from hierarchy after the fade completes to avoid blocking touches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            launchOverlayVisible = false
        }
    }

    // MARK: - Launch Overlay Content

    @ViewBuilder
    private var launchOverlay: some View {
        if let error = viewModel.errorMessage, viewModel.phase == .restoringSession {
            // Session restore failed — show error + retry inside the overlay.
            AppLaunchErrorView(
                error: error,
                onRetry: {
                    Task { await viewModel.retrySessionRestore()
                        if viewModel.phase == .authenticated {
                            dismissLaunchOverlay()
                        }
                    }
                },
                onSwitchAccount: {
                    viewModel.errorMessage = nil
                    viewModel.phase = .authMethodSelection
                    dismissLaunchOverlay()
                }
            )
            .transition(.opacity)
        } else {
            AppLaunchView()
                .transition(.opacity)
        }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .serverConnection:
            ServerConnectionView(viewModel: viewModel)

        case .restoringSession:
            // Render authenticated content behind the overlay so it's ready when overlay fades.
            // If there's an error (after retries exhausted), the overlay shows the error UI.
            authenticatedContent

        case .authMethodSelection:
            NavigationStack {
                AuthMethodSelectionView(viewModel: viewModel)
            }

        case .credentialLogin:
            NavigationStack {
                LoginView(viewModel: viewModel)
            }

        case .signUp:
            NavigationStack {
                SignUpView(viewModel: viewModel)
            }

        case .pendingApproval:
            PendingApprovalView(viewModel: viewModel)

        case .ldapLogin:
            NavigationStack {
                LDAPLoginView(viewModel: viewModel)
            }

        case .ssoLogin:
            NavigationStack {
                SSOAuthView(viewModel: viewModel)
            }

        case .authenticated:
            authenticatedContent

        case .serverSwitcher:
            NavigationStack {
                ScrollView {
                    SavedServersView(
                        viewModel: viewModel,
                        showAddServerButton: true,
                        onDismiss: {
                            // Return to the correct phase when the user taps X
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                if viewModel.currentUser != nil {
                                    viewModel.phase = .authenticated
                                } else if dependencies.serverConfigStore.activeServer != nil {
                                    viewModel.phase = .authMethodSelection
                                } else {
                                    viewModel.phase = .serverConnection
                                }
                            }
                        },
                        canDismiss: viewModel.currentUser != nil
                            || dependencies.serverConfigStore.activeServer != nil
                    )
                }
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Switch Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // X button — lets the user bail out without switching servers
                    if viewModel.currentUser != nil
                        || dependencies.serverConfigStore.activeServer != nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    if viewModel.currentUser != nil {
                                        viewModel.phase = .authenticated
                                    } else if dependencies.serverConfigStore.activeServer != nil {
                                        viewModel.phase = .authMethodSelection
                                    } else {
                                        viewModel.phase = .serverConnection
                                    }
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 20))
                            }
                            .accessibilityLabel("Close server switcher")
                        }
                    }
                }
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var authenticatedContent: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadMainChatView()
            } else {
                MainChatView()
            }
        }
        .overlay {
            // Connection lost overlay — blocks interaction when server/internet is down.
            // The "Switch Server" button presents the switcher as a sheet so the user
            // can browse options and dismiss without committing to a switch.
            ConnectionOverlayView(monitor: dependencies.connectionMonitor) {
                showServerSwitcherSheet = true
            }
        }
        .sheet(isPresented: $showServerSwitcherSheet) {
            // Server switcher as a dismissible sheet — swipe down or X to cancel.
            // The sheet is self-contained: onDismiss closes the sheet; switching a
            // server also closes the sheet and transitions the app phase.
            NavigationStack {
                ScrollView {
                    SavedServersView(
                        viewModel: viewModel,
                        showAddServerButton: true,
                        onDismiss: { showServerSwitcherSheet = false }
                    )
                }
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Switch Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showServerSwitcherSheet = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .font(.system(size: 20))
                        }
                        .accessibilityLabel("Dismiss server switcher")
                    }
                }
            }
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            // Auto-close the overlay sheet once a server switch completes
            // (phase transitions away from serverSwitcher → authenticated / authMethod)
            if newPhase == .authenticated || newPhase == .authMethodSelection {
                showServerSwitcherSheet = false
            }
        }
        .task {
            // Start the connection monitor once the user is authenticated.
            // This begins NWPathMonitor + /health polling.
            dependencies.startServerConnectionMonitor()
        }
        .task {
            // Check for app updates (App Store) and server updates in parallel.
            // Runs once after authentication on every app launch.
            async let appCheck: () = dependencies.updateChecker.checkForUpdates()
            async let serverCheck: () = dependencies.serverUpdateChecker.checkForUpdates(using: dependencies.apiClient)
            _ = await (appCheck, serverCheck)
        }
        .sheet(isPresented: Binding(
            get: {
                dependencies.updateChecker.availableUpdate != nil ||
                dependencies.serverUpdateChecker.availableUpdate != nil
            },
            set: { isPresented in
                if !isPresented {
                    dependencies.updateChecker.dismissUpdate()
                    dependencies.serverUpdateChecker.dismissUpdate()
                }
            }
        )) {
            CombinedUpdateSheet(
                appUpdate: dependencies.updateChecker.availableUpdate,
                serverUpdate: dependencies.serverUpdateChecker.availableUpdate,
                onDismiss: {
                    dependencies.updateChecker.dismissUpdate()
                    dependencies.serverUpdateChecker.dismissUpdate()
                }
            )
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
        .overlay(alignment: .topTrailing) {
            // Floating pill shown when voice call is minimized.
            // Compact 56×56 square anchored top-right — no Spacer/drag so
            // the overlay only intercepts touches directly on the pill itself.
            if router.isVoiceCallMinimized, let vm = router.voiceCallViewModel {
                VoiceCallPillView(
                    viewModel: vm,
                    onExpand: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            router.expandVoiceCall()
                        }
                    },
                    onEndCall: {
                        Task {
                            await vm.endCall()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                router.dismissVoiceCall()
                            }
                        }
                    }
                )
                .padding(.top, 56)
                .padding(.trailing, 12)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: router.isVoiceCallMinimized)
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(
                    userName: viewModel.currentUser?.displayName ?? "there"
                ) {
                    viewModel.markOnboardingSeen()
                }
            }
            .onAppear {
                // Show onboarding for first-time users
                if !viewModel.hasShownOnboarding {
                    showOnboarding = true
                }

                // Update widget data
                WidgetCenter.shared.reloadAllTimelines()

                // Update shared auth state
                SharedDataService.shared.saveAuthState(
                    isAuthenticated: true,
                    userName: viewModel.currentUser?.displayName,
                    serverURL: dependencies.serverConfigStore.activeServer?.url
                )

                // Prefetch the current user's avatar once so every UserAvatar
                // view renders instantly without a shimmer flash.
                // Only fires if a user + baseURL are known at this point;
                // if restoreSession hasn't completed yet, the avatar is prefetched
                // once currentUser becomes available via the .task block below.
                if let userId = viewModel.currentUser?.id,
                   let baseURL = dependencies.apiClient?.baseURL,
                   !userId.isEmpty, !baseURL.isEmpty,
                   let avatarURL = URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image?v=\(viewModel.profileImageVersion)") {
                    Task {
                        await ImageCacheService.shared.prefetchUserAvatar(
                            url: avatarURL,
                            authToken: dependencies.apiClient?.network.authToken
                        )
                    }
                }
            }
    }
}
