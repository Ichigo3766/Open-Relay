<div align="center">

<img src="openrelayicon.png" width="120" alt="Open Relay App Icon" style="border-radius: 22px;" />

# Open Relay

**The best native iOS/iPadOS & Watch client for [Open WebUI](https://openwebui.com)**

*Chat with any AI model on your self-hosted server — beautifully.*

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/id6759630325)

[![GitHub stars](https://img.shields.io/github/stars/Ichigo3766/Open-Relay?style=social)](https://github.com/Ichigo3766/Open-Relay/stargazers)
[![License: GPL](https://img.shields.io/badge/License-GPL-blue.svg)](LICENSE)
[![iOS 18+](https://img.shields.io/badge/iOS-18%2B-black?logo=apple)](https://apps.apple.com/app/id6759630325)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Ichigo3766/Open-Relay/pulls)

</div>

---

<div align="center">
  <img src="openui.gif" alt="Open Relay in action" width="320" />
</div>

---

## ⭐ Why Star This Repo?

Open Relay is **completely free** and **open source**. If it saves you time or brings you joy, a ⭐ star helps other people discover it and motivates continued development. Takes 1 second — [star it here](https://github.com/Ichigo3766/Open-Relay/stargazers). Thank you! 🙏

---

## 🚀 Get the App

<div align="center">
  <a href="https://apps.apple.com/app/id6759630325">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="60" />
  </a>
  <br/><br/>
  <b>Live on the App Store · iPhone & iPad · iOS 18+</b>
</div>

---

## ✨ What Is Open Relay?

Open Relay is a **100% SwiftUI** native iOS & iPadOS app that connects to your self-hosted [Open WebUI](https://openwebui.com) server, giving you a fast, polished, truly native experience that the mobile web browser can't match.

Think of it as **ChatGPT on your phone** — but pointed at *your* server, running *your* models, with *your* data staying private.

---

## 🎯 Feature Highlights

| | Feature | Description |
|---|---|---|
| 🗨️ | **Streaming Chat** | Real-time word-by-word streaming with full Markdown — code blocks, tables, math, mermaid diagrams, and more |
| 📞 | **AI Voice Calls** | Call your AI like a real phone call via CallKit — animated orb visualization reacts live to your voice |
| 🎙️ | **On-Device TTS / STT** | Marvis Neural Voice (MLX, ~250 MB, fully offline) + Qwen3 ASR for on-device speech recognition |
| 🖥️ | **Terminal Integration** | Give AI direct terminal access; slide-over file panel with directory nav, file upload, mini terminal |
| 🧠 | **Reasoning Display** | Collapsible "Thought for X seconds" blocks for chain-of-thought models (DeepSeek, QwQ, etc.) |
| 📐 | **SVG & Mermaid** | AI-generated SVGs and Mermaid diagrams render as crisp, zoomable inline images |
| 🌐 | **Rich HTML Embeds** | Interactive HTML tools (audio, video, charts, dashboards, forms) render as live inline webviews |
| 📁 | **Folders & Org** | Drag-and-drop folders with per-folder system prompts, models, and knowledge bases |
| 💬 | **Channels** | Topic-based group chat rooms for multiple users and AI models |
| 📚 | **Knowledge Bases** | Type `#` for a searchable picker for your knowledge collections (RAG) |
| 🛠️ | **Tools & Workspace** | Toggle tools per conversation; manage models, prompts, skills, and tools from within the app |
| 🧠 | **Memories** | View, add, edit, and delete AI memories that persist across conversations |
| 🤖 | **Automations** | Schedule prompts to run automatically at recurring times |
| 📅 | **Calendar** | Schedule events with AI assistance |
| 🎨 | **Deep Theming** | Accent color picker, pure black OLED mode, tinted surfaces — with live preview |
| ♿ | **Accessibility** | Independent font size, UI scaling, and live preview with presets |
| 🔐 | **Full Auth Support** | Username/password, LDAP, SSO, and auth proxy support (Authelia, Authentik, Keycloak, etc.) |
| 🔗 | **Multi-Server** | Save multiple Open WebUI servers, switch instantly |
| 🏠 | **Widgets & Shortcuts** | Home screen widgets and Action Button integration via Shortcuts |
| 📱 | **iPad Native** | Full persistent sidebar, 4-column grids, persistent terminal panel |

### Composer Shortcuts

| Trigger | Action |
|---|---|
| `@` | Switch model mid-conversation |
| `/` | Browse & search your prompt library |
| `$` | Browse & apply skills |
| `#` | Pick a knowledge base / file (RAG) |

---

## 📋 Requirements

| | Requirement |
|---|---|
| 📱 **Device** | iPhone or iPad |
| 🍎 **iOS** | iOS 18.0 or later |
| 🛠️ **Build** | Xcode 16.0+ / Swift 6.0+ |
| 🌐 **Server** | A running [Open WebUI](https://openwebui.com) instance |

---

## 🔨 Build & Run Locally

### 1. Clone

```bash
git clone https://github.com/ichigo3766/Open-Relay.git
cd Open-Relay
```

### 2. Open in Xcode

```bash
open "Open UI.xcodeproj"
```

> Xcode will automatically fetch all Swift Package dependencies on first open. This may take a minute.

### 3. Configure Signing

1. Select the **Open UI** target in the Project Navigator
2. Go to **Signing & Capabilities**
3. Choose your **Development Team**
4. Update the **Bundle Identifier** if needed

### 4. Run

Select an **iOS 18+ simulator** or connected device → press **⌘R**

On first launch, enter your Open WebUI server URL and sign in.

---

## 🧱 Tech Stack

| Layer | Technology |
|---|---|
| UI | SwiftUI (100%) |
| Language | Swift 6, strict concurrency |
| Architecture | MVVM |
| Streaming | SSE (Server-Sent Events) |
| Voice Calls | CallKit |
| On-Device ML | MLX Swift (Marvis TTS + Qwen3 ASR) |
| Persistence | Core Data |

---

## 🔗 URL Scheme

Open Relay supports a custom URL scheme (`openui://`) so you can launch the app and trigger actions from **Raycast, Obsidian, Apple Shortcuts, Home Assistant, terminal scripts**, or any tool that can open a URL.

### Supported URLs

| URL | What it does |
|---|---|
| `openui://new-chat` | Open a new chat with focus on the input field |
| `openui://new-chat?prompt=Hello` | Open a new chat with "Hello" pre-filled in the input |
| `openui://new-chat?prompt=Hello&send=true` | Open a new chat, pre-fill "Hello", and send it immediately |
| `openui://new-chat?model=gpt-4o` | Open a new chat and select the specified model |
| `openui://new-chat?prompt=Hello&model=gpt-4o&send=true` | Pre-fill, select a model, and auto-send |
| `openui://new-chat?mode=voice-recording` | Start a new AI voice call |
| `openui://continue` | Resume the last conversation |
| `openui://chat/{conversationId}` | Open a specific conversation by ID |
| `openui://channel/{channelId}` | Open a specific channel by ID (also accepts `openui://channels/{channelId}`) |
| `openui://voice-call` | Start a voice call |
| `openui://new-note` | Open the Notes section |
| `openui://new-channel` | Create a new Channel |
| `openui://note/{noteId}` | Open a specific note by ID |

### Query Parameters

| Parameter | Values | Description |
|---|---|---|
| `prompt` | Any text (max 4,000 chars) | Pre-fills the chat input field |
| `model` | Model ID string | Selects the model by ID (e.g. `gpt-4o`, `llama3.2`) |
| `send` | `true` | Auto-sends the prompt immediately (requires `prompt`) |
| `mode` | `voice-recording` | Opens a voice call instead of text chat |

### Examples

**Raycast Script Command:**
```bash
open "openui://new-chat?prompt=Summarize%20my%20clipboard&send=true"
```

**Apple Shortcut action:**
Use the built-in **"Ask Open Relay"** Shortcuts action (appears in the Shortcuts app under Open Relay) to open a chat with a prompt, optional model, and auto-send — all configurable from the Shortcuts editor.

**Home Assistant automation:**
```yaml
service: notify.mobile_app_your_phone
data:
  message: "shortcut"
  data:
    url: "openui://new-chat?prompt=What%27s+the+weather+forecast%3F&send=true"
```

**Home Assistant — open a channel when the notification is tapped:**
```yaml
service: notify.mobile_app_your_phone
data:
  message: "New post in #alerts"
  data:
    url: "openui://channel/YOUR_CHANNEL_ID"
```

To get a channel's ID, long-press the channel in the Open Relay sidebar and choose **Copy Channel Link**, or copy the last part of the channel's address in the web app (`https://your-server/channels/<id>`).

---

## 🤝 Contributing

Pull requests are welcome! Whether it's a bug fix, improvement, or new feature — feel free to open an issue or submit a PR.

1. Fork the repo
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

---

## 📄 License

This project is licensed under the **GPL License**. See [LICENSE](LICENSE) for details.

---

<div align="center">

Made with ❤️ for the Open WebUI community

**[⭐ Star this repo](https://github.com/Ichigo3766/Open-Relay/stargazers) · [🐛 Report a Bug](https://github.com/Ichigo3766/Open-Relay/issues) · [💡 Request a Feature](https://github.com/Ichigo3766/Open-Relay/issues)**

</div>
