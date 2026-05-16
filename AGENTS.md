# Open Relay — Agent Instructions

## Project Overview

Native iOS/iPadOS client for [Open WebUI](https://openwebui.com). 100% SwiftUI, Swift 6, strict concurrency, MVVM architecture. Targets iOS 18.1+.

- **Repo**: `Ichigo3766/Open-Relay`
- **App Store**: [id6759630325](https://apps.apple.com/app/id6759630325)
- **License**: GPL

---

## Build & Run

- **Xcode 16.0+** required. Open `Open UI.xcodeproj` (not a workspace).
- Xcode auto-fetches Swift Package dependencies on first open.
- Configure signing on the **Open UI** target before running.
- Select an **iOS 18.1+** simulator or device.
- No `Package.swift` — all SPM packages are managed inside `.xcodeproj`.

---

## Project Structure

```
Open UI/                      ← main app target (bundle: com.openui.openui)
├── App/
│   └── Open_UIApp.swift      ← @main entry: AppDelegate, scene delegate, RootView
├── Core/
│   ├── Extensions/            ← Swift extensions (Date, emoji, timestamps)
│   ├── Models/                ← Data models (23 files: ChatMessage, Conversation, etc.)
│   ├── Networking/            ← APIClient, SSEStream, SocketIOService, KeychainService
│   └── Services/             ← 40 service singletons (TTS, ASR, streaming, etc.)
├── Features/                  ← Feature modules (14 directories)
│   ├── Chat/                  ← Core chat UI + ChatViewModel
│   ├── VoiceCall/             ← CallKit voice calls
│   ├── Channels/              ← Group chat rooms
│   ├── Workspace/             ← Models, prompts, skills, tools management
│   ├── Admin/                 ← Admin console
│   └── ... (Auth, Settings, Terminal, Calendar, Automations, etc.)
├── Navigation/
│   ├── AppRouter.swift        ← @Observable router (NavigationPath + sheets)
│   └── Route.swift            ← Route enum
├── Shared/
│   ├── Components/            ← 49 reusable SwiftUI views
│   └── Theme/                 ← AppTheme, ColorTokens, Typography, ViewStyles
├── Open_UI.xcdatamodeld/      ← Core Data model
├── Info.plist                 ← URL scheme (openui://), shortcuts, background modes
└── Open UI.entitlements       ← App entitlements

OpenUIWidgets/                  ← widget extension target
├── OpenUIWidgetsBundle.swift  ← Widget extension entry
└── *.swift                    ← Lock screen, quick actions, control center widgets
```

---

## Architecture

### Dependency Injection
- `AppDependencyContainer` (`@Observable`) is the single DI container, injected via `.environment()` at `RootView`.
- All services are instantiated once in the container. Server-scoped services (`APIClient`, `SocketIOService`, managers) rebuild on server switch via `configureServicesForActiveServer()`.
- Views access services through `@Environment(AppDependencyContainer.self)`.

### State Management
- **`@Observable` macro** (Swift 6) for all view models and containers. No ObservableObject.
- **`AppRouter`** manages `NavigationPath` for main nav + separate `channelPath` for channels. Sheets use `presentedSheet: Route?`.
- **`ActiveChatStore`** caches up to 5 `ChatViewModel` instances (LRU eviction). Streaming VMs are never evicted. Shared model/settings cache lives here.

### Networking
- **SSE** (Server-Sent Events) for streaming chat responses.
- **Socket.IO** for real-time channels, notifications.
- **REST** via `APIClient` for all other API calls.
- Auth token stored in Keychain, scoped per server URL.

### ML / On-Device
- **MLX** for on-device TTS (Kokoro) and ASR (Qwen3).
- `Memory.cacheLimit = 20 MB` set at launch to prevent GPU memory spike.
- All MLX models **must unload before backgrounding** (Metal GPU forbidden in background on iOS < 26). See `Open_UIApp.swift` scenePhase handler.

---

## Key Conventions

### Navigation
- Push via `router.navigate(to:)`, pop via `router.goBack()`, sheets via `router.presentSheet()`.
- Voice call is a `fullScreenCover` managed by `router.presentVoiceCall()` / `minimizeVoiceCall()` / `dismissVoiceCall()`.
- Deep links use `openui://` scheme (handled in `handleDeepLink`). Widget actions use `NotificationCenter` posts.

### Theming
- Custom `.themed(with:accessibility:)` view modifier applies `AppTheme` + `AccessibilityManager`.
- Color scheme driven by `AppearanceManager.resolvedColorScheme` (supports Default, Dark, OLED, Tinted).
- Accessibility: independent text scaling for messages, titles, and UI elements.

### Backgrounding
- On `.inactive`/`.background`: stop TTS, unload Kokoro, pause ASR, run storage cleanup.
- On `.active`: process pending shortcut actions, reconnect socket, health check.
- Background tasks registered: `com.openui.streaming`, `com.openui.asr.transcription`.

### Auth Flow
- Phase-based state machine in `AuthViewModel`: `.serverConnection` → `.restoringSession` → `.authMethodSelection` → login/SSO/LDAP → `.authenticated`.
- Multi-account per server. Token stored per-server in Keychain.
- Server switch calls `router.resetAll()` + rebuilds all server-scoped services.

### Notifications
- Cross-process communication with widgets via `UserDefaults(suiteName: appGroupId)` and `NotificationCenter`.
- Notification tap opens specific chat via `NotificationService.shared.onOpenChat`.

---

## Important Gotchas

1. **No `&&` in PowerShell** — use `; if ($?) { }` or `workdir` parameter.
2. **`Info.plist` is excluded** from file-system sync in pbxproj. Edit only through Xcode or directly in the file.
3. **Scene delegate, not app delegate**, handles shortcut items (`UIApplicationShortcutItems` in Info.plist). Quick actions route through `ShortcutSceneDelegate` → `AppDelegate.pendingShortcutAction` → `scenePhase == .active` handler.
4. **AVAudioSession** must be configured before any `WKWebView` is created (affects silent switch behavior for inline HTML previews).
5. **Cloudflare-protected servers** require CF cookies on avatar fetches. `ImageCacheService` must be configured with CF headers separately from `APIClient`.
6. **SwiftUI `@ObservationIgnored`** is used on internal storage dicts to prevent AttributeGraph cycles during body evaluation.
7. **iPad vs iPhone**: `horizontalSizeClass == .regular` branches to `iPadMainChatView` (persistent sidebar) vs `MainChatView`. Always test both.

---

## Testing

- No automated test suite exists.
- PR template requires manual testing on **both** iPhone and iPad devices/simulators.
- Verify no new build warnings.

---

## PR Checklist (from `.github/pull_request_template.md`)

- [ ] Tested on device (iPhone)
- [ ] Tested on device (iPad) — if relevant
- [ ] Tested on iOS Simulator
- [ ] Build succeeds with no warnings added
- [ ] No regressions in related features
- [ ] Screenshots/recording for UI changes
