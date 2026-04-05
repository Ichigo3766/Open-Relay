# Changelog

## 📦 NEXT BUILD

### What's New

### Improvements

### Bug Fixes


## Previous Builds

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

## Previous Builds

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
