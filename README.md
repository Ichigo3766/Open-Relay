# Open UI

**A beautiful, native iOS client for [Open WebUI](https://openwebui.com).**

Chat with any AI model on your self-hosted Open WebUI server — right from your iPhone. Open UI is built 100% in SwiftUI and brings a fast, polished, native experience that the PWA can't match.

<p align="center">
  <a href="https://apps.apple.com/app/id6759630325">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="50">
  </a>
</p>

<p align="center">
  <img src="openui.gif" alt="Open UI Demo" width="300">
</p>

---

## What It Does

Open UI connects to your Open WebUI server and lets you have conversations with any AI model you've configured —  It's like having ChatGPT on your phone, but pointed at *your* server and *your* models.

---

## Features

**🗨️ Streaming Chat with Full Markdown** — Real-time word-by-word streaming with complete markdown support — syntax-highlighted code blocks (with language detection and copy button), tables, math equations, block quotes, headings, inline code, links, and more. Everything renders beautifully as it streams in.

**🖥️ Terminal Integration** — Enable terminal access for AI models directly from the chat input, giving the model the ability to run commands, manage files, and interact with a real Linux environment. Swipe from the right edge to open a slide-over file panel with directory navigation, breadcrumb path bar, file upload, folder creation, file preview/download, and a built-in mini terminal.

**@ Model Mentions** — Type `@` in the chat input to instantly switch which model handles your message. Pick from a fluent popup, and a persistent chip appears in the composer showing the active override. Switch models mid-conversation without changing the chat's default.

**📐 Native SVG & Mermaid Rendering** — AI-generated SVG code blocks render as crisp, zoomable images with a header bar, Image/Source toggle, copy button, and fullscreen view with pinch-to-zoom. Mermaid diagrams (flowcharts, state, sequence, class, and ER) also render as beautiful inline images.

**📞 Voice Calls with AI** — Call your AI like a phone call using Apple's CallKit — it shows up and feels like a real iOS call. An animated orb visualization reacts to your voice and the AI's response in real-time.

**🧠 Reasoning / Thinking Display** — When your model uses chain-of-thought reasoning (like DeepSeek, QwQ, etc.), the app shows collapsible "Thought for X seconds" blocks. Expand them to see the full reasoning process.

**📚 Knowledge Bases (RAG)** — Type `#` in the chat input for a searchable picker for your knowledge collections, folders, and files. Works exactly like the web UI's `#` picker.

**🛠️ Tools Support** — All your server-side tools show up in a tools menu. Toggle them on/off per conversation. Tool calls are rendered inline with collapsible argument/result views.

**🧠 Memories** — View, add, edit, and delete AI memories (Settings → Personalization → Memories) that persist across conversations.

**🎙️ On-Device TTS (Marvis Neural Voice)** — Built-in on-device text-to-speech powered by MLX. Downloads a \~250MB model once, then runs completely locally — no data leaves your phone. You can also use Apple's system voices or your server's TTS.

**🎤 On-Device Speech-to-Text** — Voice input with Apple's on-device speech recognition, your server's STT endpoint, or an on-device Qwen3 ASR model for offline transcription.

**📎 Rich Attachments** — Attach files, photos (library or camera), paste images directly into chat. Share Extension lets you share content from any app into Open UI. Images are automatically downsampled before upload to stay within API limits.

**📁 Folders & Organization** — Organize conversations into folders with drag-and-drop. Pin chats. Search across everything. Bulk select, delete, and now **Archive All Chats** in one tap.

**🎨 Deep Theming** — Full accent color picker with presets and a custom color wheel. Pure black OLED mode. Tinted surfaces. Live preview as you customize.

**🔐 Full Auth Support** — Username/password, LDAP, and SSO. Multi-server support. Tokens stored in iOS Keychain.

**⚡ Quick Action Pills** — Configurable quick-toggle pills for web search, image generation, or any server tool. One tap to enable/disable without opening a menu.

**🔔 Background Notifications** — Get notified when a generation finishes while you're in another app.

**📝 Notes** — Built-in notes alongside your chats, with audio recording support.

### ⚙️ Additional Settings
- **Default model picker** synced with your server
- **Send on Enter** toggle (Enter sends vs. newline)
- **Streaming haptics** — feel each token as it arrives
- **Temporary chats** — conversations not saved to the server for privacy
- **TTS engine selection** with per-engine configuration
- **STT engine selection** with silence duration control

---

## Requirements

- **iOS 18.0** or later
- **Xcode 16.0** or later (Swift 6.0+)
- A running **[Open WebUI](https://openwebui.com)** server instance accessible from your device

---

## Build & Run Locally

### 1. Clone the Repository

```bash
git clone https://github.com/ichigo3766/Open-UI.git
cd Open-UI
```

### 2. Open in Xcode

```bash
open "Open UI.xcodeproj"
```

Xcode will automatically fetch all Swift Package dependencies on first open. This may take a minute.

### 3. Configure Signing

- In Xcode, select the **Open UI** target in the project navigator
- Go to **Signing & Capabilities**
- Select your **Development Team**
- Update the **Bundle Identifier** if needed (e.g., `com.yourname.openui`)

### 4. Build & Run

- Select an **iOS 18+ simulator** or a connected device
- Press **⌘R** (or click the ▶️ Play button)
- On first launch, enter your Open WebUI server URL and sign in

---

## Tech Stack

- **SwiftUI** — 100% SwiftUI interface
- **Swift 6** with strict concurrency
- **MVVM** architecture
- **SSE (Server-Sent Events)** for real-time streaming
- **CallKit** for native voice call integration
- **MLX Swift** for on-device ML inference (Marvis TTS + Qwen3 ASR)
- **Core Data** for local persistence

---

## Acknowledgments

Special thanks to Conduit by cogwheel — Cross-Platform Open WebUI mobile client and a real inspiration for this project.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
