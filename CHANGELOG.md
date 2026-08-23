# Changelog

## v5.4.1 — August 23, 2026

### Bug Fixes
- Fixed admin users unable to edit models in Admin Console
- Fixed starred tool quick-action pills disappearing on app launch and new chat


## Previous Builds

## v5.4 — August 22, 2026

### What's New
- Added Controls panel (tap the slider icon in any chat) showing attached files, knowledge bases, reference chats, system prompt override, and tool/function valve settings

### Improvements
- Improved server switching: the "Switch Server" screen now has an X button to dismiss without switching, server rows show a reachability check before committing a switch, and the connection-lost overlay presents the switcher as a dismissible sheet.

### Bug Fixes
- Fixed starred tool buttons persisting in the quick-actions row after a tool is deleted or removed from the server.
- Fixed hidden models not appearing in the workspace model editor's base model picker — admins can now select any enabled model (including hidden ones) as a base model when creating or editing workspace models, matching Open WebUI web behavior.


## v5.3.9 — August 21, 2026

### Improvements
- Admin Models screen now shows workspace custom models (e.g. models you've created from a base) alongside base models.

### Bug Fixes
- Fixed second (and subsequent) reasoning/thinking blocks not appearing during streaming.
- Fixed admin model list only loading the first 30 models when more than 30 exist.
- Fixed all users appearing to have edit access to models they don't own; edit button is now greyed out for read-only models.
- Fixed "Hide Model" / "Show Model" failing for Ollama and other base models that don't yet have a workspace record.
- Fixed admin model settings (built-in tools toggles) always resetting to default because the server key names didn't match what the app expected.
- Fixed model public/private badge always showing "PRIVATE" due to access grants being checked in the wrong place.


## v5.3.8 — August 19, 2026

### Bug Fixes
- Fixed follow-up suggestions disappearing ~2 seconds after appearing due to server sync overwriting them with an empty array.
- Fixed follow-up suggestions not persisting when editing a message or switching between message versions.
- Fixed follow-up suggestions never appearing after regenerating a response.
- Fixed reasoning blocks displaying as raw HTML instead of rendering natively during streaming.


## v5.3.7 — August 19, 2026

### Bug Fixes
- Fixed pinned chats inside folders not appearing in the Pinned section.
- Fixed iPad hamburger menu button not responding to taps when sidebar auto-hide mode is enabled


## v5.3.6 — August 17, 2026

### Bug Fixes
- Fixed text getting stuck when a response involves multiple sequential blocks
- Fixed crash when opening a Voice Call on macOS
- Fixed login screen appearing after returning from a long background


## v5.3.5 — August 15, 2026

### Bug Fixes
- Fixed HTTP polling fallback timing out after 60 seconds of silent processing — responses from long-running tasks now wait for the server to confirm the task is complete before finalising, preventing truncated or missing responses.


## v5.3.4 — August 14, 2026

### Improvements
- Minor animation tweaking throughout the app for smoothness.

### Bug Fixes
- Fixed app logging out on every launch — removed an overly aggressive JWT expiry check that was treating tokens with less than 5 minutes remaining as already expired, matching Open WebUI's approach of letting the server decide token validity via 401.


## v5.3.3 — August 14, 2026

### Bug Fixes
- Fixed app permanently freezing on the launch screen when the server was slow or unreachable.
- Fixed login screen briefly flashing on launch when on a slow or unreachable network.
- Fixed iPad crashing on launch when "Always Show Sidebar" was enabled in Appearance settings.
- Fixed new chat button (✏️) not appearing in the navbar when inside a chat on iPad.


## v5.3.2 — August 13, 2026

### Improvements
- Improved valve editing for tools and functions

### Bug Fixes
- Fixed sending a message after deleting the last message in a chat incorrectly adding it as a version of the deleted message instead of starting a fresh new chat.


## v5.3.1 — August 12, 2026

### Improvements
- Improved networking resilience with automatic retry (up to 2 attempts with backoff) on transient network errors and server errors across all API calls.
- Improved streaming resilience with a 60-second stall watchdog that terminates hung SSE connections instead of waiting forever.
- Improved session security by automatically signing out when any API call receives a 401, so expired tokens never leave the app in a broken state.
- Improved streaming reliability by correctly handling multi-line server-sent events per the SSE spec.
- Improved stop-generation to cancel all server-side tasks for a chat in a single request instead of one per task.
- Improved session security by automatically treating stored auth tokens as expired when they are within 5 minutes of their expiry time, preventing 401 errors mid-session.
- Improved image loading efficiency with conditional HTTP requests (ETag/Last-Modified), allowing the server to respond with 304 Not Modified and skip re-downloading unchanged images.

### Bug Fixes
- Fixed app getting stuck on the loading screen when the server is slow or temporarily unreachable on launch.


## v5.3 — August 12, 2026

### What's New
- Folders now support a custom emoji icon and background images
- Folder workspace landing screen now shows a scrollable list of recent chats so you can quickly jump back into any conversation

### Improvements
- Improved server-side background task handling (title generation, follow-up suggestions, tags) to correctly respect your settings and match web client behavior.

### Bug Fixes
- Fixed "Rename" option appearing on chats inside read-only shared folders where editing is not permitted
- Fixed markdown syntax not rendering in user messages when "Render markdown in user messages" is enabled


## v5.2.4 — August 9, 2026

### Improvements
- Significantly improved connection reliability for self-hosted servers on local networks

### Bug Fixes
- Fixed Engine.IO heartbeat sending in the wrong direction


## v5.2.3 — August 7, 2026

### Bug Fixes
- Fixed response text after a tool call not appearing during streaming
- Fixed chat messages overflowing horizontally past the screen edge on smaller iPhones


## v5.2.2 — August 5, 2026

### Improvements
- Chats started inside a folder now correctly send the folder context to the server, ensuring folder-level knowledge and system prompts are applied and the sidebar updates properly.

### Bug Fixes
- Fixed memories not being used in chat — the app now correctly falls back to the server's global memories setting when no explicit preference is stored in the user's account, matching OpenWebUI's behavior.


## v5.2.1 — August 5, 2026

### What's New
- Added iPad sidebar layout toggle in Settings → Appearance: choose between "Always Show Sidebar" (pinned split-view) or the default slide-out drawer overlay.

### Bug Fixes
- Fixed tool calls causing the entire chat response to freeze with no output
- Fixed tool call responses silently delivering no content — events containing only tool call data (no text yet) are no longer dropped.
- Fixed tool call JSON arguments being corrupted


## v5.2 — August 4, 2026

### Improvements
- Added option in Privacy & Security settings to exclude downloaded AI models (TTS/ASR) from iCloud backup — models are redownloadable so they don't need to consume iCloud storage. Enabled by default. (Turn Open Relay off/on in the icloud backup setting to apply.)

### Bug Fixes
- Fixed workspace model system prompts being ignored mid-conversation — the app now correctly falls back to the model's server-side system prompt when no per-chat or personal default prompt is set, so changes made in the OpenWebUI workspace are picked up immediately.
- Fixed memories not being injected into conversations — the memory enabled/disabled toggle now stays in sync across all new chats opened after the toggle is changed.


## v5.1 — August 1, 2026

### What's New
- Added swipe-to-reply gesture in channels — swipe right on any message to reply.
- Reply previews inside message bubbles now show the sender's avatar, name, and a content preview, and tapping them scrolls to and highlights the original message.
- Reply bar above the keyboard now shows the sender's avatar, a reply arrow icon, and message preview for clear context.

### Improvements
- Channels now show a compact single-line reply preview (sender avatar + bold name + italic message) matching the Open WebUI web style.
- Sidebar hamburger button now works in channel views on both iPhone and iPad — tap it to slide open the conversation list from any channel.
- iPad: selecting a channel from the sidebar now correctly closes the drawer and loads the channel.
- iPad sidebar now slides in and out with the same push/scale/blur animation as iPhone — tap the sidebar button or swipe from the left edge to open, swipe left or tap the content to close.
- Channels now show a live "X is typing…" indicator with an animated dot pulse when another user is composing a message.
- New channels and DM conversations started by others now appear in your sidebar instantly without needing to pull-to-refresh.
- Thread reply counts and "# replies" badges on channel messages now update in real time when a new reply is posted.
- Channel member presence state and status emoji/message are now fetched from the server for more accurate online indicators.
- AI model responses in channels now show an animated "Generating…" indicator in the bubble while the model is writing its first tokens, instead of a blank gap.

### Bug Fixes
- Fixed DM conversations showing the wrong name — the recipient's sidebar now correctly shows the sender's name instead of their own name.
- Fixed online/offline status dot in DM conversations always showing as offline even when the other user is actively connected — now correctly reflects the server's real-time active status both in the sidebar and inside the DM.
- Fixed iPad sidebar hamburger menu button not appearing when on the new chat screen or inside a chat.
- Fixed chat responses sometimes never arriving after sending a message, with the server showing "Checking..." indefinitely — caused by a timing race where messages could be sent before the connection was fully ready.
- Fixed the app treating local network servers differently from remote ones, which could cause inconsistent connection status.
- Fixed channel lifecycle events (channel updated/deleted) not being handled in the sidebar, which could leave stale channels visible.
- Fixed occasional duplicate messages when sending two identical messages in quick succession in a channel.


## v5.0 — July 31, 2026

### What's New
- Added Continue button to the assistant action bar — tap to append new content to an incomplete or truncated response.
- Added Fork Chat button to the assistant action bar — clone any conversation and jump straight to the fork.
- Added Notification Targets — configure push/webhook notification destinations in Profile settings (requires OpenWebUI v0.11.0+).
- Added Sub-agents support — enable and configure sub-agents from Admin Console; background subagent mode works in chat.
- Added Chat Variables — define and save personal variables from your profile that can be referenced in chats (requires OpenWebUI v0.11.0+).
- Added LDAP Group Sync and Allow Groups permission controls in Admin → General → Auth (requires OpenWebUI v0.11.0+).
- Added Files, Notifications, and Sub-agents tool toggles to the model editor.
- Added new Admin Console → Settings tabs: Database (import/export config, export chats), Pipelines (manage pipeline valves), Events (webhooks with per-event filtering), and Authentication (LDAP, OAuth/OIDC, access defaults).
- Added External Knowledge Sources in Admin → Settings → Integrations.
- Added Memory System Context and Channel Model Response Mode toggles to Admin → General → Features.
- Added Context Compaction section to Admin → Interface for summarising long chat histories.

### Improvements
- Editing an AI response now saves in-place without triggering a new reply — matching the web UI behavior.
- Admin permissions now correctly gate dictation, voice call, read-aloud, regenerate, edit, and ratings in chat.
- "Attach Notes" in the tools sheet is hidden when the server has Notes disabled.
- Admin → Interface now saves chat config (context compaction) alongside task config in a single Save action.
- All Admin Console text fields are now always-visible multiline boxes — no swipe gesture required.
- Chat composer now expands into a large writing area when you swipe up — swipe down to collapse.

### Bug Fixes
- Fixed jittery scroll, layout jumps, and nav bar flickering at the bottom of chats.
- Fixed Admin → General settings save failing with a validation error.
- Fixed cloning a workspace model failing with "session expired" — now opens a pre-filled editor to review before saving.
- Fixed workspace model list showing a sparkles icon instead of the model's avatar.


## v4.15.9 — July 26, 2026

### Bug Fixes
- Fixed saving Admin → Settings → Interface failing with an error due to missing fields in the request.
- Fixed clearing the system prompt in My Defaults not persisting after saving.


## v4.15.8 — July 25, 2026

### Bug Fixes
- Fixed Custom Headers editor missing from the "Add Server" sheet


## v4.15.7 — July 23, 2026

### Improvements
- Smoother animation when switching between message versions

### Bug Fixes
- Fixed connection stalling and "Server Unreachable" overlay appearing immediately after login when using a local/LAN-only server.
- Fixed deleted message versions reappearing after regenerating a response in the same session.
- Fixed tool-generated attachments not being saved to the server, causing them to disappear when switching versions in the app.
- Fixed editing a message with attachments — the edit bar now shows existing attachments as chips with a × button to remove them before resending.


## v4.15.6 — July 22, 2026

### Bug Fixes
- Fixed connection stalling immediately after login in some cases.
- Fixed Settings → Server connection check getting permanently stuck on "Checking" with a gray dot instead of resolving to green or red.
- Fixed default system prompt and inference parameters going stale — the app now re-fetches your settings from the server when returning from background and when starting a new chat, so changes made on the web UI or another device are picked up immediately.


## v4.15.5 — July 17, 2026

### Improvements
- Improved drawer opening/closing and general smoothness
- Minor performance updates


## v4.15.4 — July 15, 2026

### Bug Fixes
- Fixed false positive proxy detection bug.
- Fixed adding a server with the same URL as an existing one wiping all saved accounts on that server.
- Fixed signed-out account appearing greyed out in the account picker, preventing re-login without switching accounts first.


## v4.15.3 — July 14, 2026

### Bug Fixes
- Improved proxy auth login reliability


## v4.15.2 — July 14, 2026

### Bug Fixes
- Fixed Rich UI embed webviews (weather cards, dashboards, music players, etc.) not appearing after 0.10+ update


## v4.15.1 — July 9, 2026

### Bug Fixes
- Improved streaming resilience for slow models — responses from large reasoning models, long MCP tool chains, and local models should no longer time out prematurely.


## v4.15 — July 8, 2026

### What's New
- Added message rating system - If server has message rating enabled, the user can provide feedback mirroring webui behavior.
- Added Evaluations panel in Admin Console — admins can browse the feedback history. Leaderboard coming soon.


## v4.14 — July 7, 2026

### What's New
- Added URL scheme support — open a new chat from Raycast, Shortcuts, Obsidian, or any app using `openui://new-chat?prompt=Hello&model=gpt-4o&send=true`.
- Added "Ask Open Relay" Shortcuts action — create a new chat with a prompt, optional model, and auto-send directly from Apple Shortcuts. This is a start and will be expanded upon for more usability.
- Added model-switch progress banner for SGLang and OpenAI-compatible backends — when a status URL is configured per-server, a banner shows "Loading qwen3-35b ~42s left" while the model loads.

### Improvements
- Enhanced image and file attachment previews: images now display inlined in chat above the text bubble 

### Bug Fixes
- Fixed occasional app freezing on launch when a large chat was previously open.
- Fixed update notification not appearing instantly after a new version is released on the App Store.
- Fixed "Check for Updates" and "Check for Server Updates" buttons showing "Up to date" (green) after dismissing an update dialogue, even when an update is available.


## v4.13.1 — July 7, 2026

### Improvements
- Replaced the bouncing typing dots with a clean blinking cursor while waiting for the AI response to start.

### Bug Fixes
- Fixed model response getting stuck inside the tool call dropdown during streaming
- Fixed server-generated files showing as non-tappable links


## v4.13 — July 4, 2026

### What's New
- Added Shared Folders — share any folder of chats with specific people or groups, set read or write access, and browse folders others have shared with you directly from the sidebar. Chats in read-only shared folders open in view-only mode with a lock banner instead of the input field.
- Added "Revoke All" button in Shared Chats — revoke every shared link at once with a single tap and confirmation.
- Added "Clone" option in Automations — duplicate any automation as a starting point from its context menu.

### Improvements
- Further scrolling/animation smoothness.


## v4.12 — June 29, 2026

### What's New
- Fixed compatibility with Open WebUI v0.10+ — messages, tool call cards, streaming, and chat history all work correctly after the server switched to a structured `output` array format for storing assistant responses.

### Bug Fixes
- Fixed attached files (PDFs, documents) being "forgotten" after the first reply — the request now retains access to uploaded files in the chat throughout the entire conversation, including on regenerate and edit.


## v4.11.3 — June 28, 2026

### Bug Fixes
- Fixed app interrupting Bluetooth audio (e.g. music in the car) when opening the app — the audio session no longer activates at launch, so background music continues uninterrupted.
- Fixed the first message in a voice call not being spoken aloud — the TTS pipeline now waits reliably for streaming to begin before reading the response.
- Fixed message queue not showing the send button when typing while a response is streaming — the send button now appears so you can queue messages mid-stream.
- Fixed queued messages not auto-sending after the current response finishes streaming.


## v4.11.2 — June 26, 2026

### Improvements
- Many underlying markdown library improvements.
- Smoother animations across various interactions.

### Bug Fixes
- Fixed Workspace Skills list only showing 30 skills — now loads all skills across all pages.
- Fixed reopening a previous chat not scrolling to the bottom — the chat now always opens at the latest message.
- Fixed cross-device streaming now showing the same typewriter effect as self-initiated streams instead of tokens popping in abruptly.
- Fixed navigating away and back to a chat mid-stream showing a garbled or duplicated display instead of the live response.
- Fixed `openui://chat/<id>` deep links not navigating to the specified conversation when the app is already open.


## v4.11.1 — June 19, 2026

### Improvements
- Smoother app start
- Some QOL visual improvements

### Bug Fixes
- Fixed app getting permanently stuck on the loading screen while offline.
- Fixed math formatting
- Fixed LaTeX commands silently failing to render.


## v4.11 — June 16, 2026

### What's New
- Added Attach Files, Attach Notes, Attach Knowledge, and Skills sections to the + menu in chat — quickly attach server-uploaded files, notes, or knowledge bases, and toggle skills directly from the compose menu.

### Improvements
- Reasoning effort parameter now includes "xhigh" as a preset option and a "Custom" free-text mode for any value a provider supports.
- Many qol updates.

### Bug Fixes
- Fixed a frosty/translucent bar appearing at the top of the chat screen when scrolling — the navigation bar background now stays fully transparent at all scroll positions.


## v4.10.1 — June 12, 2026

### Improvements
- Minor visual improvements


## v4.10 — June 8, 2026

### What's New
- Added "Using Entire Document" toggle in the file attachment preview — tap a file pill to choose between Focused Retrieval (default) or sending the full document content inline.

### Bug Fixes
- Fixed "Save to Photos" silently doing nothing — the app now requests Photos permission on first save and opens Settings if access was previously denied.


## v4.9.3 — June 6, 2026

### What's New
- Added My Defaults settings to customize account level system prompt and advanced parameters.

### Improvements
- Improved the animation on app launch


## v4.9.2 — June 4, 2026

### What's New
- Read Aloud (Server TTS only) now continues playing your response when you put the app in background allowing you to listen to long responses while navigating other apps on your phone.

### Improvements
- Improved scroll FABs: The ↑ button jumps to the previous question
- App and server update checks now happen when returning from background as well.
- Terminal button in chat input now only appears when the selected model has terminal capability enabled — configure per model in the workspace model editor. Matches openwebui changes.

### Bug Fixes
- Fixed currency amounts being read incorrectly by TTS
- Fixed text selection popup (Ask/Explain menu) auto-closing after 2 seconds
- Fixed regenerated responses not fully settling markdown


## v4.9 — June 2, 2026

### What's New
- Added "Ask" and "Explain" buttons to the text selection menu in assistant messages — select any text to quote it into the input box or instantly ask for an explanation.
- Added delete chat button to the chat toolbar — tap ··· in any chat and choose Delete to permanently remove it (with confirmation).
- Added Markdown Rendering toggles in Settings → Chat Behavior — independently control whether markdown is rendered in your messages and AI messages.
- Added scroll to top navigation fab

### Improvements
- Tapping the new chat button now transitions smoothly instead of abruptly flashing the UI.
- Sources bar now shows a +N badge when a response has more than 3 citation sources, keeping the bar compact while making all sources accessible.

### Bug Fixes
- Fixed app becoming unresponsive to taps when returning from background with the sidebar partially open mid-swipe


## v4.8.1 — May 31, 2026

### Bug Fixes
- Fixed terminal shell failing to reconnect automatically after being idle — it now correctly detects a dead session and establishes a fresh connection instead of silently giving up.
- Fixed app becoming unresponsive (buttons not tappable) after returning from a long background session


## v4.8 — May 28, 2026

### What's New
- Added "Manage Ollama" sheet — pull models from Ollama.com with real-time whole-model progress, update all installed models at once, delete models, create custom models from a modelfile, and upload local GGUF files directly to your Ollama server, all from within the app.


## v4.7.1 — May 28, 2026

### Improvements
- Smoother transitions throughout the app.
- Fixed iPad sidebar chat list bouncing/hopping when tapping a chat to open it.

### Bug Fixes
- Fixed terminal WebSocket creating multiple orphaned sessions when reconnecting after switching apps or reopening the terminal panel.


## v4.7 — May 26, 2026

### What's New
- Added models tab under Admin Console settings - You can now manage your models from the app directly.

### Bug Fixes
- Fixed app freezing when switching to a chat containing images.
- Fixed intermittent crash when opening model selector, model editor, tool valves, or chat parameters sheets.


## v4.6.1 — May 25, 2026

### What's New
- Complete redesign of open terminal shell architecture — now powered by SwiftTerm, native terminal experience using websockets instead of http polling. It should feel snappier and realtime.

### Bug Fixes
- Fixed typing indicator appearing as a large full-width element while the AI is generating a response.


## v4.6 — May 20, 2026

### What's New
- Added Share Extension — share URLs, files, images, and documents from any app directly into Open Relay.
- Added Face ID / Touch ID sign-in — after signing in once, tap the Face ID button on the login screen to authenticate instantly. Also allows full passwords support now!
- Native Text Selection on macos - When using ipad version on mac, you are now freely able to select text just like you would in any other app. 

### Improvements
- Further stability improvements when loading into chats.
- Improved password manager and iCloud Keychain AutoFill support on the sign-in screen.

### Bug Fixes
- Fixed the app signing you out when your server is temporarily unreachable — transient connectivity issues should no longer clear your session.


## v4.5.3 — May 18, 2026

### Bug Fixes
- Attempted fix for "Sign In Failed" error when signing in with Microsoft Entra ID 
- Fixed multiple crashes affecting streaming responses.


## v4.5.2 — May 18, 2026

### Bug Fixes
- Fixed sidebar sections (Pinned, Today, Yesterday, etc.) resetting to expanded on every app launch — collapse state now persists across launches.
- Fixed various server-level enabled/disabled settings.


## v4.5.1 — May 16, 2026

### Improvements
- Images embedded directly in responses now display inline with no raw data visible during generation

### Bug Fixes
- Fixed the chat scrolling back to the bottom after streaming ends if the user had manually scrolled up during the response.


## v4.5 — May 15, 2026

### What's New
- Added a "save as permanent" button to temporary chats
- Images embedded directly in responses now display inline — tap to view fullscreen with pinch-to-zoom, or hold to save to Photos or share

### Improvements
- Significantly reduced false "server disconnected" alerts
- Returning to the app from the background should reconnect instantly
- Added a subtle haptic when a response finishes streaming

### Bug Fixes
- Fixed a race condition where streaming auto-scroll would randomly disengage mid-response.


## v4.4 — May 14, 2026

### What's New
- Added Message Queue — when enabled in Chat Settings, messages sent while the AI is responding are queued and sent automatically when the response finishes. Each queued message can be sent immediately, edited, or removed from the queue.

### Improvements
- Added a share button to inline Rich UI embeds.

### Bug Fixes
- Fixed double requests (false emoji generation) being sent on every request.


## v4.3 — May 13, 2026

### What's New
- Hold on any message text to select and copy — long-press text selection now works alongside the existing double-tap.

### Improvements
- Input bar buttons and icons now scale with your Accessibility UI Scale setting in both chat and channel views.
- Code block/native visualization performance has been drastically improved - While streaming code blocks that could contain 600+ lines, UI remains responsive and lag free!
- Markdown underlying improvements.

### Bug Fixes
- Fixed streaming haptics not firing during streaming.
- Fixed the message composer requiring multiple taps to open the keyboard — tapping anywhere on the input bar now reliably focuses it.
- Fixed a jitter when dismissing the keyboard by scrolling — the input bar now glides down in perfect sync with the keyboard instead of snapping after it closes.
- Fixed continuous main-thread animation frames competing with the WebContent render during HTML streaming, causing visible lag when JS-heavy content streams in.


## v4.2.2 — May 12, 2026

### Bug Fixes
- Fixed app not showing the update notification for new versions
- Fixed pending accounts incorrectly entering the app on relaunch
- Fixed pipe/function models throwing error due to latest owui changes

## v4.2.1 — May 12, 2026

### Bug Fixes
- Fixed update notification popup appearing every time the app launches — once dismissed, it won't reappear for that version; the update icon in the sidebar stays visible so you can tap it anytime.
- Fixed widgets not rendering properly.


## v4.2 — May 10, 2026

### What's New
- Terminal now has a fullscreen mode — tap the expand button in the terminal toolbar to open a full-screen terminal view with more room to work.
- Terminal now shows a quick-action shortcut bar with Tab, history up/down (↑ ↓), and Clear buttons for faster keyboard-free input.

### Improvements
- Terminal shell now starts warming up as soon as you enable terminal access, so input is ready instantly when you open the panel.

### Bug Fixes
- Fixed terminal output displaying raw ANSI escape codes (e.g. `[1m[96m…[0m`) instead of clean text.
- Fixed terminal access (terminal_id) still being included in chat requests even after disabling the terminal toggle.
- Fixed server update changelog showing raw HTML code blocks or being invisible — now renders as native SwiftUI views with bold titles and color-coded category labels.
- Server update sheet now shows the server's favicon as the icon (with a server.rack fallback if unavailable).
- Fixed conversation tags not appearing — tags were being read from the wrong field in the server response; now correctly reads from the updated server format.
- Fixed conversation timestamps (created/updated dates) showing the wrong time after loading a chat — the server sends them as integers which weren't being handled correctly.


## v4.1 — May 8, 2026

### What's New
- Long-press any chat inside a folder to enter selection mode — multi-select, then remove from folder, move to another folder, or delete in bulk.
- Added "Move to Folder" button in the main chat list's selection toolbar — select multiple chats and move them all into a folder at once.
- Added server update notifications — the app now checks your Open WebUI server for available updates on launch. A "Check for Server Updates" button is also available in About → Server.
- Image size reduction - 5mb cap on vision models cause error if the image is too big.
- Native visualizations now support audio output.

### Improvements
- Minor code block performance improvements.
- Removed "Clear Local Cache" option from Privacy & Security settings as Storage Menu covers it all.

### Bug Fixes
- Terminal now runs as a persistent bash session with proper stdin support; suppressed harmless startup warnings
- Fixed terminal remaining active for the model after disabling it — the model no longer receives terminal access when the toggle is off
- Fixed admin-disabled terminal servers appearing as available and being silently used in requests
- Fixed multi-server terminal: switching servers with the toggle off no longer leaves a stale server selected that could re-activate on the next enable
- Fixed folders only showing up to 10 chats — now loads all chats across all pages smoothly
- Fixed typing indicator animation
- Fixed update notice incorrectly triggering based on GitHub tags instead of the actual App Store version.


## v4.0 — May 5, 2026

### What's New
- Added dedicated Input Box Text size slider in Accessibility settings — independently scale the font in the chat and channel message composer.
- A complete re-write of the streaming pipeline — Massively improved streaming performance. App should feel fully responsive while streaming. 

### Improvements
- Switching between chats should feel smoother. 
- Screen now stays on while TTS is reading a response aloud, just like during voice calls.
- Voice calls now respect the admin-configured Voice Mode prompt from OpenWebUI's interface settings — the model automatically receives the right system prompt to keep responses concise and speech-friendly.

### Bug Fixes
- Fixed nested code blocks rendering as plain text.
- Fixed citation source icons showing as letter avatars instead of favicons.
- Known Issue: Inline visualizer plugin is not correctly working with the new re-write and needs a bit more work. Continue using the native visualizer which works perfectly and much better than pluggin. In future, the pluggin support may be dropped as it requires lot of processing since its written for the webui (includes iframe code in the tool block) and causes lag and has no real benifit over the native visualization. 


## v3.5 — May 3, 2026

### What's New
- Added user valve editor for tools — tap the gear icon next to any tool in the tools picker to configure its settings.
- Added in-app update notice — the app checks for new versions on every launch and shows a sheet with release notes; tapping "Later" dismisses it and leaves an update icon next to the New Chat button in sidebar so you can reopen it anytime.
- Added star button to every tool in the tools picker — tap ⭐ to instantly pin it as a quick-action pill in the chat input, no settings detour required.

### Improvements
- Tool call results now display with full syntax highlighting and virtual windowing — only the visible portion is rendered, matching how regular code blocks work.
- Streaming responses now scroll more smoothly with less jank, reduced CPU usage, and no animation stutter.
- Dramatically improved performance for reasoning/thinking models — the app no longer gets slower as the model thinks longer.
- Channel deletes, edits, reactions, and pins from other devices now appear live without needing to refresh.
- Deleting a channel message now animates out instantly instead of waiting for the server.

### Bug Fixes
- Fixed TTS audio not playing through earbuds or wired headphones in both chat read-aloud and voice calls.
- Fixed regenerated responses not showing server errors in the chat bubble
- Fixed the chat not scrolling to the regenerating message — regenerating a response now animates the view to the new message the same way sending does.
- Fixed non-toggleable filters incorrectly appearing under Default Filters in the model editor.
- Fixed toggle-filter functions in the tools picker always turning on when globally enabled, ignoring the model's configured default state.
- Fixed crash in channels when deleting a message.
- Fixed channel context menu appearing off-screen when the keyboard was open.
- Fixed new chats always starting with the last-used model instead of the server-configured default model.
- Fixed Settings → Default Model changes not applying to new chats opened in the same session.
- Hidden models (disabled by an admin in OpenWebUI) no longer appear in the model picker or the Default Model setting.
- Fixed thinking blocks breaking the "Explored N" tool-call grouping on reasoning models — all tool calls now collapse into a single pill as expected.


## v3.4.2 — May 1, 2026

### Improvements
- Dramatically improved app's performance while streaming!


## v3.4.1 — April 30, 2026

### Bug Fixes
- Fixed streaming responses appearing too fast bypassing the typewriter style.
- Fixed inline visualizer text flickering and disappearing during live visualization streaming.


## v3.4 — April 30, 2026

### What's New
- Added Native Inline Live Visualization  — charts, graphs, svgs and interactive visualizations now render LIVE directly inside chat messages. No need for Inline visualizer pluggin (Works with it as well!). Add "output the code in one file" (or create a prompt in your worspace instead of typing it each time) at the end of your prompt and watch it get built live!

### Improvements
- Consecutive tool calls from different tools now group into a single collapsible row, matching the web UI.
- Citation badges in AI responses now show domain names by default instead of full page titles, and correctly render grouped citations like [1, 2, 3]. Toggle between domain and title in Settings → Chat Behavior.
- Improved math rendering accuracy — formulas inside code blocks now correctly restore their original delimiters instead of showing placeholder text.
- Tables with clickable links now handle taps more reliably, and table cells are reused more efficiently for smoother scrolling.

### Bug Fixes
- Fixed JavaScript not executing in HTML code block previews — interactive apps like Kanban boards, games, and dashboards now work correctly, including drag-and-drop, button clicks, and localStorage persistence.
- Switching accounts now instantly clears the chat list and reloads conversations, folders, and channels for the new account.
- Fixed some action buttons not working that required js to complete its task.
- Fixed certain tool call Rich UI embeds (music players, video players, dashboards) being non-interactive
- Fixed AI message content being clipped at the bottom.
- Fixed quick action pills disappearing from the chat input bar after starting a new chat or switching conversations.
- Fixed built-in tools (web search, image generation, code interpreter) resetting to their model defaults after sending a message, ignoring any toggles the user had changed.


## v3.3.1 — April 24, 2026

### Improvements
- Significantly improved text streaming — Experience the new typewriter-style streaming instead of pop-ins.

### Bug Fixes
- Fixed server-side filter content not appearing in the chat until navigating away and back.
- Fixed models not able to see image attachments.


## v3.3 — April 24, 2026

### What's New
- Added Calendar — view, create, and delete events from your Open WebUI calendars (Personal and Scheduled Tasks). Color-coded month grid with event dots, day event list, create event form with calendar picker, date/time, location, reminder options, and description. Access from the ••• menu in the sidebar.
- Added Automations — schedule prompts to run automatically on a recurring schedule (hourly, daily, weekly, monthly, or custom RRULE). Create, edit, enable/disable, run immediately, and view execution history. Access from the ••• menu in the sidebar.
- Admin Console → General Settings → Features now includes Calendar and Automations toggles.
- Model editor (workspace and admin) now shows Task Management, Automations, and Calendar checkboxes in the Built-in Tools section.
- Added task list panel above the chat input — when a model uses task management tools, a collapsible panel shows all tasks with their status.

### Improvements
- Screen stays on during voice calls — the display no longer turns off mid-conversation, keeping the call active without needing to tap the screen.
- Tool call OUTPUT now shows pretty-printed, expanded JSON instead of a single compressed line.
- Multiple consecutive tool calls with the same name are now grouped into a single collapsible row.
- Admin users can now open the Admin Console directly from the sidebar (•••) menu.
- Various UI element consistency across the app.

### Bug Fixes
- Fixed sidebar and chat features (Notes, Channels, Folders, Memories) now correctly respect the user's individual permissions from the server
- Fixed message versioning - completely rebuilt end-to-end to match OpenWebUI's conversation tree
- Attempting to fix Microsoft (and other OAuth) sign-in staying stuck on the web page after successful login instead of returning to the app.


## v3.2.2 — April 21, 2026

### Improvements
- Significantly improved sidebar performance for users with large conversation lists.

### Bug Fixes
- Fixed user messages disappearing when re-opening a chat after the latest OpenWebUI server update (updated the completions request to include the `user_message` field required by the new server API).
- Fixed error messages in chat being truncated — full error text now displays without a line limit.
- Fixed tapping Photo in the attachment menu returning to the + tools sheet after selecting a photo — the sheet now dismisses immediately when a photo is picked.


## v3.2.1 — April 20, 2026

### What's New
- Added system variables - System variables (`{{USER_LOCATION}}`, `{{USER_NAME}}`, `{{CURRENT_DATETIME}}`, etc.) will now automatically be replaced with their value at runtime matching the webui behavior.

### Bug Fixes
- Fixed GPS location not using the device's actual GPS — location is now always fresh and includes a full reverse-geocoded address. Also fixed the chat hanging intermittently when location sharing is enabled.


## v3.2 — April 18, 2026

### What's New
- Added GPS location sharing — enable "Share Location" in Privacy & Security settings to send your real location to the AI model when using `{{USER_LOCATION}}` in system prompt for tools like maps, weather, etc.

### Improvements
- Redesigned tool call display to provide full details, including rich result items shown inline under each status step.
- Tool call status indicator also improved.

### Bug Fixes
- Fixed tool call status history (web search steps, location resolving, etc.) disappearing when switching chats — status updates now persist correctly when reopening a conversation.
- Removed further throttling for streaming token by token.


## v3.1 — April 17, 2026

### What's New
- Added Groups management to Admin Console — create, edit, and delete user groups, manage group members, configure permissions per group, and set default permissions for all users. Swipe left on a group to delete with confirmation.

### Improvements
- Reorganised Admin Console into cleaner top-level tabs (Users, Analytics, Functions, Settings), with Settings containing a searchable section picker for General, Connections, Integrations, Documents, Web Search, Code Execution, Interface, Audio, and Images.

### Bug Fixes
- Fixed code blocks flickering/flashing colors during streaming
- Fixed HTML code blocks not rendering as live previews after the AI finishes responding.
- Fixed thinking/reasoning block staying expanded after thinking completes — it now collapses automatically once the model finishes reasoning.
- Fixed profile avatar related issues.


## v3.0.1 — April 15, 2026

### Bug Fixes
- Fixed TTS mispronouncing numbers


## v3.0 — April 14, 2026

### What's New
- Added multi-account support per server — login to multiple accounts on the same server and switch between them instantly with a long-press on your avatar in sidebar or from the setting -> manage servers.
- Added robust automatic server reconnection and a user facing error message when unable to reach the server.
- Added Python code execution — tap the Run button on any Python code block to execute it on-device using Pyodide (WebAssembly). Supports numpy, pandas, matplotlib, sympy, and more. 
- Admin's Paradise:
    - Added Analytics dashboard, General, Connections, Integrations, Code Execution, Documents, Web Search, Interface, Audio, and Images Tabs to admin console with full control. 

### Improvements
- New tools now start with a helpful Python template
- Images in AI responses now render inline — markdown image links display as actual images, tap to open the linked page.
- Redesigned the Account page in Settings - Added ability to modify account details. 
- Added group-based access control — you can now grant access to entire groups (not just individual users) across Prompts, Knowledge, Models, Tools, Skills, and Channels.
- Tapping a processed file attachment now shows the extracted text content and a native PDF preview in a tabbed sheet, matching the web UI experience.
- Streaming responses now grow smoothly per-character without visible height-update chunking.
- Extended tool API request timeout to 5 minutes to prevent timeouts when loading or saving complex tools.
- Added a tip below the TTS voice preview button explaining that it lets you hear how the selected voice sounds.

### Bug Fixes
- Fixed follow-up suggestions being cut off after two lines — they now expand to show the full text.
- Fixed Voice Call not transcribing speech when connected to CarPlay — the microphone now works correctly through the car's hands-free system.
- Fixed deleting a chat, channel, or folder chat leaving the screen stuck on stale content — the app now automatically navigates to the new chat screen after any deletion.
- Fixed cloning tools failing due to wrong character in name.
- Fixed saving workspace items (tools, skills, prompts, models) showing a false "session expired" error.


## v2.6.2 — April 9, 2026

### Improvements
- Reverted streaming responses back to appearing character-by-character instead of arriving in chunks - Feels smoother!

### Bug Fixes
- Fixed scrolling to bottom when entering chats.
- Fixed background notifications not reliably delivering


## v2.6.1 — April 9, 2026

### What's New
- Added "Show Response Preview" option in Settings → Notifications — when enabled, the first lines of the AI response appear in the completion notification. Off by default.

### Improvements
- Significant Markdown library performance updates. Increased smoothness while streaming long responses!
- User avatars are not fetched at app restart instead of using stale data.

### Bug Fixes
- Fixed Qwen3 TTS switching to an English accent mid-response when speaking non-English text — the voice now stays in the correct language.
- Fixed Qwen3 TTS producing corrupted/distorted audio during voice calls after a few sentences due to unbounded GPU memory growth — memory is now properly cleared after each sentence.
- Fixed voice call TTS continuing to speak the full response after disconnecting — ending a call now stops playback immediately.
- Fixed voice call TTS randomly pausing and skipping sentences — the audio pipeline now stays open for the full response instead of tearing down between sentences.
- Fixed the same response being spoken twice during voice calls — the streaming and speak pipelines no longer overlap.
- Fixed switching from a voice call to chat read-aloud causing audio glitches — each session now cleanly resets state before starting.



## v2.6 — April 9, 2026

### What's New
- Added per-chat advanced parameters panel — tap the sliders icon in any chat to override temperature, top-p, system prompt, and 20+ other parameters for that specific conversation.
- Added Reference Chats — include a previous conversation as context in any message via the + attachment menu.
- Replaced Marvis TTS with:
    - Qwen3 TTS (Recomended) — supporting English, Chinese, Korean, Japanese, German, Spanish, French, Italian, Portuguese, Russian, and Arabic, with multiple speaker voices and language selection in Settings.
    - Added Kokoro TTS as a secondary option — 54 voices across 9 languages (American/British English, Spanish, French, Hindi, Italian, Japanese, Portuguese, Chinese) with adjustable speed.

### Improvements
- Corrected slider ranges and states in the workspace model editor.

### Bug Fixes
- Fixed tapping the edit button in the model picker not opening the model editor for certain models.
- Fixed saving a new workspace model showing a false "session expired" error.
- Model picker no longer floods the server with hundreds of simultaneous image requests during fast scrolling
- Fixed prompt library, knowledge, model, and skill pickers going behind the navigation bar when using a large third-party keyboard.
- Fixed pinning a model in model selector would not update the star immediately. 
- System prompt is now also sent in request params for better compatibility with server-side prompt handling.


## v2.5 — April 7, 2026

### What's New
- Redesigned appstore screenshots and the icon!

### Improvements
- Added haptic feedback when tapping the model selector.

### Bug Fixes
- Base model picker when creating a workspace model now only shows provider models, not other workspace models.
- Model ID, Prompt command, Skill ID, and Tool ID fields now correctly auto-fill from the name when creating new items in the workspace.
- Added consistent pill background to the navigation bar model selector chip.


## v2.4.4 — April 7, 2026

### Improvements
- Reduced memory usage for large conversations!
- Big Channels UI improvements.
- Scrolling up during a streaming response now breaks out of auto-scroll immediately.

### Bug Fixes
- Fixed "Send on Enter" not working in channels and thread replies — pressing Enter now sends the message as expected when the setting is enabled.
- Fixed thread replies appearing twice in the thread view when sent


## v2.4.3 — April 5, 2026

### What's New
- Added inline #URL detection — type `#` followed by a URL in the chat input to see a suggestion pill; tap it to scrape and attach the webpage as a file.
- Added tap-to-preview for all attachment types — tap any image, audio, or file pill in the input bar to see a fullscreen preview.

### Improvements
- Sending a message now smoothly scrolls your question to the top of the screen so the AI response streams in below it.
- Reverted back to orginal scrolling behavior until further polishing. The memory will still be significantly lower if code blocks are in the chat. 
- Adding a website URL via the + button now scrapes the page and attaches it as a file instead of pasting the URL into the text box.
- Using the prompt library with "/" now appends the selected prompt to your existing text instead of replacing it.

### Bug Fixes
- Fixed knowledge, prompt, skill, and model picker overlays covering the text input field — the input box now stays visible when any picker is open.

## v2.4.2 — April 3, 2026

### What's New
- Added voice dictation — tap the mic button in the chat input bar to dictate, then tap Stop to append the transcribed text to your message using on-device or server model.
- Full prompt versioning support - Version history for every message is properly preserved where previously on worked for assistant messages.  

### Improvements
- Drastically reduced cpu/memory usage across the app - About 70%+ (scaled with #/length of messages) drop in memory and 20-40% in cpu utilization for same tasks.
- Tapping "Edit" on a channel message now opens the keyboard automatically so you can start typing right away.
- The thread replies sheet now opens at a comfortable near-full-height and can be dragged to dismiss.

### Bug Fixes
- Fixed channel unread badges never clearing — opening a channel now marks it as read and clears the badge immediately.
- Fixed channels and thread replies ignoring the "Send on Enter" toggle — pressing Return now correctly inserts a new line when the toggle is off.
- Fixed channel reactions added from the web showing as raw shortcode text (e.g. "sunglasses") instead of the actual emoji.
- Fixed thinking blocks swallowing the model's actual reply when the model omits the opening think tag — the response now renders correctly below the collapsed reasoning block.

## v2.4.1 — April 1, 2026

### What's New
- Experimental significant memory reduction approach + a more responsive UI and faster streaming.

### Bug Fixes
- Fixed Shift+Enter not inserting a new line on the first use after app restart on iPad with a hardware keyboard.


## v2.4 — March 31, 2026

### What's New
- Added Storage browser in Settings — view all app storage usage and use quick-action buttons to clear caches or remove ML model files in one tap.
- Added multi-language support for 56 languages (Hindi, Chinese, French, German, Japanese, Korean, Spanish, Polish, and many more).
- Added in-app Language picker in Settings → Display — browse all supported languages.

### Improvements
- Welcome screen prompt cards now prioritize per-model suggestions over global admin prompts — model-specific prompts show first, with admin-configured prompts as the fallback.
- The server connection screen, onboarding, and About screen now display the actual app icon instead of a generic placeholder icon.
- Long-press any pinned model in the sidebar to unpin it directly, without having to open the model picker.

### Bug Fixes
- Fixed Marvis Neural TTS producing garbled/garbage audio on responses that contain bullet lists, or paragraphs ending with a colon — the text preprocessor no longer generates invalid "colon-period" sequences that the model can't handle.
- Fixed server-side TTS accumulating gigabytes of temporary audio files over time — each spoken sentence now deletes its temp file immediately after playback, and any unplayed files are cleaned up when TTS is stopped.
- Fixed app crash when backgrounding during on-device speech-to-text transcription.
- Fixed thinking/reasoning blocks not responding to taps while a response is streaming — you can now expand or collapse the thinking block at any time during streaming.
- Fixed memories getting disabled by itself — pinning a model, changing the default model, or toggling memory from any screen no longer wipes other user settings.
- Fixed default model not sticking — pinning a model was incorrectly overwriting the default model setting with the pinned models list.

## v2.3.1 — March 30, 2026

### What's New
- Added German and French conversational voice options for Marvis Neural TTS.
- Added minimize/PiP for voice calls — tap the chevron button in the voice call screen to shrink it to a floating pill. Tap the pill to restore the full call, or tap the red button to end it. The call stays active while minimized.

### Improvements
- Drastically improved TTS text-to-speech naturalness: Sentences now create proper pauses, even better than openwebui splitting.

### Bug Fixes
- Fixed voice calls not starting to speak until the full AI response finished generating — responses now begin playing as soon as the first complete sentence arrives.
- Fixed audible gaps between spoken sentences in server-side TTS — replaced the old polling-based audio player with gapless queue playback so chunks play back-to-back without any pauses.

## v2.3 — March 30, 2026

### What's New
- Added Action Buttons support

### Improvements
- Replaced Parakeet (English-only) with Qwen3 ASR for on-device audio transcription — now supports automatic language detection and multilingual transcription (Spanish, French, German, Italian, Portuguese, Russian, Chinese, Japanese, Korean, and more).
- Model editor now supports enabling/disabling action buttons
- Toggle-filter functions now appear as toggleable tools in the Tools menu alongside regular tools.
- Filter functions are now properly resolved using the global vs per-model logic — global filters always apply, per-model filters respect configuration.
- Starter prompt cards on the welcome screen now fall back to per-model suggestion prompts when the admin hasn't set global prompts, and update automatically when switching models.
- The TTS/STT settings screen now correctly shows "Not Loaded" (when the model is downloaded but not in memory) vs "Not Downloaded" (when no model files exist on disk), and the download/load button label and icon also adapt accordingly.

### Bug Fixes
- Fixed on-device TTS and STT models taking up twice the expected storage — the HuggingFace download library was leaving a duplicate blob cache alongside the working model files. Existing users will automatically reclaim the wasted space on their next app launch.
- Fixed Shift+Enter intermittently sending the message instead of inserting a new line on iPad with a hardware keyboard.
- Fixed accessibility sizing not applying to assistant messages, drawer lists, and input boxes. 
- Fixed orphaned `</think>` closing tags leaking into chat messages as visible code blocks when models like Qwen skip the opening tag or when streaming splits tags across chunks.
- Fixed selecting a model and immediately sending a message no longer uses stale config.

## v2.2 — March 28, 2026

### What's New
- Added pinned models — star any model in the model picker to pin it for quick access. Pinned models appear in a dedicated section at the top of the picker and as shortcuts in the sidebar, synced with your Open WebUI server.
- Model picker now shows the currently selected model at the top of the sheet for easy reference.

### Improvements
- Home screen widgets with full theme support — widgets now properly adapt to Default, Dark, Clear, and Tinted modes instead of being stuck on a dark background.

### Bug Fixes
- Fixed thinking/reasoning blocks from models (Qwen, DeepSeek, etc.) showing as raw tags in the chat instead of rendering as a collapsible "Thinking" section. Now handles all six reasoning tag formats during streaming and fixes stray summary tags leaking mid-stream.
- Fixed on-device audio transcription cutting off the last portion (and many words throughout) of uploaded audio.

## v2.1 — March 27, 2026

### What's New
- Admins can now edit any model's settings directly from the model picker — tap the  icon next to any model to open the full model editor without leaving the chat.
- Added Tools, Skills, and Filters sections to the Model Editor
- Added Functions management to the Admin Console

### Improvements
- Significantly reduced redundant network calls to avatar endpoints - Avatars now load much faster. 
- Fixed keyboard return key showing "return" instead of "Send" when Send on Enter is enabled.

### Bug Fixes
- Fixed tool call progress not showing during web search, image generation, and other default function calls — status indicators now display in real time with animated shimmer and search query pills, matching the Open WebUI web interface.
- Fixed the app prematurely closing the streaming connection while tools were still executing in the background.

## v2.0.0 — March 26, 2026

### What's New
- Workspace Management - Introducing workspace access directly form the app. Control your models, knowledge, Prompts, skills, and Tools directly from the app. 
- Skills - Type '$' in chat to browse and apply your skills. 
- Added Archived Chats browser — tap the ⋯ menu in the chat list to open list of all your archived chats. Restore individual chats or unarchive everything at once.
- Added Shared Chats manager — tap the ⋯ menu in the chat list to view all your currently shared chats, copy their share links, or revoke access for any shared conversation.
- Added Rich UI embed support — tools that return interactive HTML (audio (Ace Step Music), video, cards, SMS composers, dashboards, charts, forms, and more) now render inline in the chat as live, interactive webviews.
- Added token usage popover — tap the ⓘ info icon in the assistant action bar to see per-message token stats.
- Home screen widgets and Shortcuts support - Start your chat from the widgets or directly from your action button using shortcuts.

### Improvements
- Folders, Channels, and Chats sidebar sections are now collapsible
- Server-side TTS now supports selecting a voice from your OpenWebUI server's available voices in Settings → Text-to-Speech.
- Server-side STT now fully works for live microphone input and voice calls
- Voice calls with AI now default to loudspeaker and include a speaker toggle button so you can switch between speaker and earpiece during a call.
- Reading messages aloud in chat now plays through the loudspeaker instead of the earpiece.
- Added Landscape mode for iPhone
- Allow closing Terminal File browser drawer while still having terminal enabled on ipad and ios landscape mode. 

### Bug Fixes
- Fixed pipe/function models (e.g. OpenRouter Pipe) hanging for ~60 seconds before responding
- Fixed multiple bugs related to STT and TTS pipeline.
- Fixed profile picture not loading in settings. 

## v1.3.1 — March 22, 2026

### What's New
- Completely redesigned model picker — tap the model name in the toolbar to open a native bottom sheet with search and filter pills (by connection type and tag).
- Folders can now have a default model set when creating them
- Folders, Channels, and Notes in the drawer are now hidden when the server has those features disabled.
- Added delete confirmation dialogs for chats, folders, and channels across all views
- Channels list now groups conversations by type: Direct Messages, Groups, and Channels — making it easier to find what you need at a glance.
- iPad conversation context menu now includes Share, Clone, Remove from Folder, and a grouped Download submenu — fully matching iPhone.
- iPad now supports editing folder settings (name, system prompt, knowledge) after creation.
- iPad subfolders now render correctly in a nested tree layout, matching iPhone.
- iPad voice transcription is no longer accidentally cancelled when tapping New Chat while recording is in progress.

### Improvements
- Performance boost for streaming and code blocks rendering.

### Bug Fixes
- Fixed "Delete Folder Only" incorrectly deleting the chats inside — chats are now properly moved to your main chat list instead.
- Fixed the tool state resetting when enabling new tools.
- Fixed deleting models in settings -> STT/TTS.

## v1.3 — March 20, 2026

### What's New
- Added multi-server management — save multiple OpenWebUI server connections and switch between them instantly from Settings or the server connection screen. 
- Chat sharing is now fully functional. Long-press any conversation and tap Share to open the share menu.
- Complete support for memories - Added Enable Memory toggle in Settings → Personalization → Memories to enable/disable the feature
- Folders now support full project workspace configuration — long-press any folder to edit its name, system prompt, default models, and attached knowledge bases (RAG context for all chats in the folder).
- Added custom headers on sign in. 

### Improvements
- On iPad with a Magic Keyboard or other hardware keyboard, pressing Enter now sends the message and Shift+Enter inserts a new line — matching the natural expectation when typing on a physical keyboard.
- Added a dedicated Feedback section in Settings → About
- Compacted the channel toolbar action icons (pin, members, settings) for better visual balance.
- Added a "New Chat" button to the drawer bottom bar so you can start a new chat from anywhere, including while inside a channel.
- All drawer rows (channels, chats, folders) are now tappable across the full row width, not just over the text.

### Bug Fixes
- Fixed email/password login failing with "Failed to decode response" when connecting via an HTTP URL that redirects to HTTPS — the app now automatically detects and upgrades to the HTTPS address.
- Fixed OAuth sign-in getting stuck on "Authenticating…" indefinitely after a successful OAuth flow — login now completes correctly.
- Fixed member avatars not showing properly throughout channels ui. 
- Fixed selected members not appearing in the "Initial Members" list when adding them during Group channel creation.
- Fixed welcome screen prompt cards not appearing on the very first app launch
- Fixed chats not loading older than a month. Now chats will properly load and match the openwebui grouping.
- Fixed model and user avatar images showing an infinite loading shimmer on servers using self-signed certificates.


## v1.2.1 — March 18, 2026

### What's New
- Servers protected by auth proxies (Authelia, Authentik, Keycloak, oauth2-proxy, etc.) now show a sign-in WebView instead of a "proxy authentication" error, letting you authenticate through whatever portal your server uses.

### Improvements
- Welcome screen prompt suggestions are now sourced from the server's.
- Allow STT language change within the call feature.
- Tapping an audio attachment chip after on-device transcription now opens a preview sheet showing the full transcript text, with a copy button, before sending.
- Audio files attached in chat are now uploaded to the server by default (server handles transcription automatically). On-Device transcription is available as an alternative in Settings → Speech-to-Text → Audio File Transcription.

### Bug Fixes
- File attachments now show a distinct "Processing…" spinner for server-side transcription as well after upload completes, so you can see when the server is indexing or transcribing the file before it's ready to send.
- Fixed audio file transcription being cancelled when navigating away from a chat — transcription now continues in the background and completes even if you switch chats.
- Fixed channels incorrectly showing as read-only for the channel owner and members with write access when access grants were present.
- Fixed background chat content (e.g. prompt cards) being accidentally tappable or scrollable while swiping to open the left or right drawer panel.
- Fixed function calling mode not being respected — the app was incorrectly overriding the server's per-model setting; it now lets the server control this entirely, matching the web client behavior.

## v1.2 — March 16, 2026

### What's New
- Added Channels — collaborative, topic-based chat rooms where multiple users and AI models interact.
- Added Accessibility settings with customizable text scaling — independently adjust message text, conversation titles, and UI elements (buttons, icons, spacing) with live preview and quick presets.
- Added slash command prompt library — type `/` in the chat input to browse and search your Open WebUI prompt library.

### Improvements
- Inline source citations now appear as small, elevated pill badges showing shortened page titles or domain names — matching the Open WebUI web interface style.
- Profile/model avatars will now show properly.

### Bug Fixes
- Fixed repeated `heartbeat() missing 1 required positional argument: 'data'` errors in Open WebUI server logs
- Fixed web search, image generation, and code interpreter toggles being ignored when turned off mid-chat — toggling a tool off now correctly prevents it from being used.
- Fixed conversations older than "This Month" not loading — pagination now properly triggers when scrolling to the bottom, allowing all conversation history to load.

## v1.1.0 — March 12, 2026

### What's New
- Added Cloudflare protected endpoint support.

### Improvements
- Full iPad layout overhaul — persistent sidebar, centered reading width, 4-column prompt grid, terminal as persistent panel.
- Added example URL placeholder in the server connection field so users know to include http:// or https:// in their URL.
- Moved the terminal toggle from the pills row to a compact inline icon next to the voice button, keeping the chat input single-line when no quick pills are pinned.
- Redesigned onboarding experience.

### Bug Fixes
- Fixed dollar amounts being incorrectly rendered as math equations instead of plain text.
- Fixed stale model list persisting after signing out and logging into a different server or account — models now refresh correctly without needing to restart the app.
- Fixed model avatars not updating when changed by the admin — avatar images are now properly invalidated and re-fetched on each model refresh.
- Fixed false proxy error on Cloudflare-protected servers.

## v1.0.0 — March 12, 2026

### What's New
- Added `@` model mention — type `@` in the chat input to quickly switch which model handles your message. Pick a model from the fluent popup, and a persistent chip appears in the composer showing the active override. The override stays until you dismiss it or pick a different model, letting you freely switch between models mid-conversation without changing the chat's default.
- Added Open Terminal integration — enable terminal access for AI models directly from the chat input pill, giving the model the ability to run commands, manage files, and interact with a real Linux environment.
- Added Terminal File Browser — swipe from the right edge to open a slide-over file panel with directory navigation, breadcrumb path bar, file upload, folder creation, file preview/download, and a built-in mini terminal for running commands directly.
- Added native SVG rendering in chat messages — AI-generated SVG code blocks now display as crisp, zoomable images with a header bar, Image/Source toggle, copy button, and fullscreen view with pinch-to-zoom and share sheet support.
- Added native Mermaid diagram rendering in chat messages (flowcharts, state, sequence, class, and ER diagrams rendered as beautiful images).
- Added Memories management (Settings → Personalization → Memories) — view, add, edit, and delete AI memories that persist across conversations.
- Added "Archive All Chats" option in the chat list menu for bulk archiving.

### Improvements
- App now sends timezone to the server on login, matching the web client for correct server-side date formatting.
- Archived chats endpoint now supports search, sort, and filter parameters for faster navigation.
- Matching formatting of content to the Open WebUI formatting.
- Sidebar drawer now slides smoothly with your finger.
- Returning to an existing chat now remembers the last model used in that conversation instead of reverting to the default model.
- Unified TTS and STT under a single mlx-audio-swift package, replacing two separate dependencies for smaller app size and easier maintenance.
- Improved audio transcription for long files with energy-based silence detection for smarter chunking at natural pauses.
- Smoother TTS audio playback with automatic crossfading between chunks, eliminating audio artifacts at sentence boundaries.
- User-attached images and files now display inline inside the message bubble instead of floating above it.

### Bug Fixes
- Fixed chat search using wrong query parameter, which could cause search to silently fail on some server versions.
- Fixed tag removal using incorrect API endpoint format (path-based instead of body-based DELETE).
- Fixed tag addition using wrong request body field name.
- Fixed tags list fetching from wrong endpoint, now uses the correct structured tags API.
- Fixed clone conversation not sending required request body.
- Fixed feature toggles (Web Search, Image Generation, Code Interpreter) still appearing in the tools menu even when the admin disabled the capability on the model. Toggles now respect per-model capabilities.
- Fixed tool-generated file download links opening in Safari instead of downloading within the app. Files are now downloaded and presented via the share sheet.
- Fixed some chats created from the app appearing blank or corrupted on the Open WebUI web interface.
- Fixed uploaded photos, PDFs, and other files not displaying on the Open WebUI web interface when sent from the app.
- Fixed chat view becoming pannable in all directions after follow-up suggestions appear, instead of strictly vertical scrolling.
- Fixed image uploads exceeding the 5 MB API limit by automatically downsampling photos to 2 megapixels before upload.
- Fixed external response stream not stopping when clicking the stop button.
