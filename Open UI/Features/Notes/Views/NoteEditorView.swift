import SwiftUI
import UniformTypeIdentifiers

/// Editor view for a single note with markdown editing,
/// audio recording, and file attachment support.
struct NoteEditorView: View {
    let noteId: String

    @State private var note: Note?
    @State private var titleText: String = ""
    @State private var contentText: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var hasChanges = false
    @State private var showAudioRecorder = false
    @State private var showFilePicker = false
    @State private var showAudioPlayer: AudioAttachment?
    @State private var isPreviewMode = true
    @State private var recordingService = AudioRecordingService()
    @State private var isGeneratingTitle = false
    @State private var isEnhancing = false
    @State private var aiErrorMessage: String?

    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @FocusState private var isContentFocused: Bool

    private var notesManager: NotesManager? {
        dependencies.notesManager
    }

    private var apiClient: APIClient? {
        dependencies.apiClient
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading note…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let note {
                editorContent(note)
            } else {
                ContentUnavailableView(
                    "Note Not Found",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This note could not be loaded.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: Spacing.sm) {
                    // AI features menu
                    Menu {
                        Button {
                            Task { await generateTitle() }
                        } label: {
                            SwiftUI.Label(
                                isGeneratingTitle ? "Generating…" : "Generate Title",
                                systemImage: "sparkles"
                            )
                        }
                        .disabled(isGeneratingTitle || contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            Task { await enhanceContent() }
                        } label: {
                            SwiftUI.Label(
                                isEnhancing ? "Enhancing…" : "Enhance with AI",
                                systemImage: "wand.and.stars"
                            )
                        }
                        .disabled(isEnhancing || contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } label: {
                        if isGeneratingTitle || isEnhancing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                    .accessibilityLabel("AI Features")

                    // Preview toggle
                    Button {
                        isPreviewMode.toggle()
                    } label: {
                        Image(systemName: isPreviewMode ? "pencil" : "eye")
                    }
                    .accessibilityLabel(isPreviewMode ? "Edit" : "Preview")

                    // Audio recording
                    Button {
                        showAudioRecorder = true
                    } label: {
                        Image(systemName: "mic.circle")
                    }
                    .accessibilityLabel("Record audio")

                    // File attachment
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .accessibilityLabel("Attach file")

                    // Save indicator
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else if hasChanges {
                        Circle()
                            .fill(theme.brandPrimary)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .alert("AI Error", isPresented: .init(
            get: { aiErrorMessage != nil },
            set: { if !$0 { aiErrorMessage = nil } }
        )) {
            Button("OK") { aiErrorMessage = nil }
        } message: {
            Text(aiErrorMessage ?? "")
        }
        .task { loadNote() }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(recordingService: recordingService) { result in
                handleAudioRecording(result)
            }
        }
        .sheet(item: $showAudioPlayer) { attachment in
            AudioPlayerSheet(attachment: attachment, baseURL: dependencies.conversationManager?.baseURL)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Editor Content

    private func editorContent(_ note: Note) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    // Title
                    if isPreviewMode {
                        Text(titleText.isEmpty ? "Untitled" : titleText)
                            .font(AppTypography.headlineLargeFont)
                            .foregroundStyle(theme.textPrimary)
                    } else {
                        TextField("Title", text: $titleText)
                            .font(AppTypography.headlineLargeFont)
                            .foregroundStyle(theme.textPrimary)
                            .onChange(of: titleText) { _, _ in scheduleAutoSave() }
                    }

                    // Metadata
                    HStack(spacing: Spacing.md) {
                        Text("\(note.wordCount) words")
                            .font(AppTypography.captionFont)
                            .foregroundStyle(theme.textTertiary)

                        Text("\(contentText.count) characters")
                            .font(AppTypography.captionFont)
                            .foregroundStyle(theme.textTertiary)

                        Spacer()

                        Text("Updated \(note.updatedAt.chatTimestamp)")
                            .font(AppTypography.captionFont)
                            .foregroundStyle(theme.textTertiary)
                    }

                    Divider()
                        .foregroundStyle(theme.divider)

                    // Audio attachments
                    if !note.audioAttachments.isEmpty {
                        audioAttachmentsSection(note.audioAttachments)
                    }

                    // File attachments
                    if !note.fileAttachments.isEmpty {
                        fileAttachmentsSection(note.fileAttachments)
                    }

                    // Content area — fills remaining screen height
                    if isPreviewMode {
                        markdownPreview
                    } else {
                        markdownEditor(screenHeight: geometry.size.height)
                    }
                }
                .padding(Spacing.screenPadding)
            }
        }
    }

    // MARK: - Markdown Editor

    private func markdownEditor(screenHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Formatting toolbar
            markdownToolbar

            TextEditor(text: $contentText)
                .font(AppTypography.bodyMediumFont)
                .foregroundStyle(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: max(400, screenHeight * 0.6))
                .focused($isContentFocused)
                .onChange(of: contentText) { _, _ in scheduleAutoSave() }
        }
    }

    /// A row of markdown formatting buttons.
    private var markdownToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                markdownButton("H1", action: { insertMarkdown("# ") })
                markdownButton("H2", action: { insertMarkdown("## ") })
                markdownButton("B", action: { wrapSelection("**") })
                markdownButton("I", action: { wrapSelection("*") })
                markdownButton("~", action: { wrapSelection("~~") })
                markdownButton("`", action: { wrapSelection("`") })
                markdownButton("•", action: { insertMarkdown("- ") })
                markdownButton("1.", action: { insertMarkdown("1. ") })
                markdownButton("[ ]", action: { insertMarkdown("- [ ] ") })
                markdownButton(">", action: { insertMarkdown("> ") })
                markdownButton("---", action: { insertMarkdown("\n---\n") })
                markdownButton("```", action: { insertMarkdown("```\n\n```") })
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func markdownButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(AppTypography.codeFont)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        }
    }

    // MARK: - Markdown Preview

    private var markdownPreview: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if contentText.isEmpty {
                Text("Nothing to preview")
                    .font(AppTypography.bodyMediumFont)
                    .foregroundStyle(theme.textTertiary)
                    .italic()
            } else {
                StreamingMarkdownView(
                    content: contentText,
                    isStreaming: false,
                    textColor: theme.textPrimary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Audio Attachments

    private func audioAttachmentsSection(_ attachments: [AudioAttachment]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Voice Notes")
                .font(AppTypography.labelMediumFont)
                .foregroundStyle(theme.textSecondary)

            ForEach(attachments) { attachment in
                Button {
                    showAudioPlayer = attachment
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "waveform")
                            .foregroundStyle(theme.brandPrimary)
                        Text(attachment.fileName)
                            .font(AppTypography.bodySmallFont)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(formatDuration(attachment.duration))
                            .font(AppTypography.captionFont)
                            .foregroundStyle(theme.textTertiary)
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(theme.brandPrimary)
                    }
                    .padding(Spacing.sm)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
            }
        }
    }

    // MARK: - File Attachments

    private func fileAttachmentsSection(_ attachments: [FileAttachmentRef]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Attachments")
                .font(AppTypography.labelMediumFont)
                .foregroundStyle(theme.textSecondary)

            ForEach(attachments) { attachment in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: iconForMimeType(attachment.mimeType))
                        .foregroundStyle(theme.brandPrimary)
                    Text(attachment.fileName)
                        .font(AppTypography.bodySmallFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(formatFileSize(attachment.fileSize))
                        .font(AppTypography.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(Spacing.sm)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
            }
        }
    }

    // MARK: - Helpers

    private func loadNote() {
        guard let manager = notesManager else {
            isLoading = false
            return
        }
        // Load from server asynchronously, falling back to local cache
        Task {
            if let serverNote = await manager.fetchNote(id: noteId) {
                note = serverNote
                titleText = serverNote.title
                contentText = serverNote.content
            } else {
                // Fallback: try local cache
                note = manager.fetchLocalNote(id: noteId)
                if let note {
                    titleText = note.title
                    contentText = note.content
                }
            }
            isLoading = false
        }
    }

    private func scheduleAutoSave() {
        hasChanges = true
        // Debounced auto-save after 1 second of inactivity
        Task {
            try? await Task.sleep(for: .seconds(1))
            await saveNote()
        }
    }

    private func saveNote() async {
        guard var updatedNote = note else { return }
        isSaving = true

        updatedNote.title = titleText
        updatedNote.content = contentText
        await notesManager?.updateNote(updatedNote)
        note = updatedNote

        isSaving = false
        hasChanges = false
    }

    // MARK: - AI Features

    /// Generates a title for the note using AI.
    private func generateTitle() async {
        guard let apiClient,
              !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        isGeneratingTitle = true
        aiErrorMessage = nil

        do {
            let defaultModel = await apiClient.getDefaultModel()
            guard let modelId = defaultModel else {
                aiErrorMessage = "No AI model available. Please configure a model first."
                isGeneratingTitle = false
                return
            }

            if let title = try await apiClient.generateNoteTitle(
                content: contentText, modelId: modelId
            ) {
                titleText = title
                hasChanges = true
                scheduleAutoSave()
            }
        } catch {
            aiErrorMessage = "Failed to generate title: \(error.localizedDescription)"
        }

        isGeneratingTitle = false
    }

    /// Enhances the note content using AI.
    private func enhanceContent() async {
        guard let apiClient,
              !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        isEnhancing = true
        aiErrorMessage = nil

        do {
            let defaultModel = await apiClient.getDefaultModel()
            guard let modelId = defaultModel else {
                aiErrorMessage = "No AI model available. Please configure a model first."
                isEnhancing = false
                return
            }

            if let enhanced = try await apiClient.enhanceNoteContent(
                content: contentText, modelId: modelId
            ) {
                contentText = enhanced
                hasChanges = true
                scheduleAutoSave()
            }
        } catch {
            aiErrorMessage = "Failed to enhance content: \(error.localizedDescription)"
        }

        isEnhancing = false
    }

    private func handleAudioRecording(_ result: RecordingResult) {
        guard var updatedNote = note else { return }

        let attachment = AudioAttachment(
            fileName: result.fileName,
            duration: result.duration
        )
        updatedNote.audioAttachments.append(attachment)
        note = updatedNote
        Task { await notesManager?.updateNote(updatedNote) }

        // Upload to server if available
        Task {
            do {
                let fileId = try await notesManager?.uploadAudio(data: result.data, fileName: result.fileName)
                if var currentNote = note,
                   let index = currentNote.audioAttachments.firstIndex(where: { $0.id == attachment.id }) {
                    currentNote.audioAttachments[index].fileId = fileId
                    await notesManager?.updateNote(currentNote)
                    note = currentNote
                }
            } catch {
                // File saved locally, server upload failed - that's OK
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, var updatedNote = note else { return }

        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url) else { continue }

            let attachment = FileAttachmentRef(
                fileName: url.lastPathComponent,
                fileSize: Int64(data.count),
                mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            )
            updatedNote.fileAttachments.append(attachment)

            // Upload to server
            Task {
                do {
                    let fileId = try await notesManager?.uploadFile(data: data, fileName: url.lastPathComponent)
                    if var currentNote = note,
                       let index = currentNote.fileAttachments.firstIndex(where: { $0.id == attachment.id }) {
                        currentNote.fileAttachments[index].fileId = fileId
                        await notesManager?.updateNote(currentNote)
                        note = currentNote
                    }
                } catch {
                    // Saved locally, upload failed
                }
            }
        }

        note = updatedNote
        Task { await notesManager?.updateNote(updatedNote) }
    }

    private func insertMarkdown(_ prefix: String) {
        contentText += prefix
    }

    private func wrapSelection(_ wrapper: String) {
        contentText += "\(wrapper)text\(wrapper)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func iconForMimeType(_ mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType.contains("pdf") { return "doc.text" }
        return "doc"
    }
}

// MARK: - Audio Recorder Sheet

struct AudioRecorderSheet: View {
    @Bindable var recordingService: AudioRecordingService
    let onComplete: (RecordingResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.xl) {
                Spacer()

                // Waveform visualization
                HStack(spacing: 4) {
                    ForEach(0..<20, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.brandPrimary)
                            .frame(width: 4, height: barHeight(for: index))
                    }
                }
                .frame(height: 80)

                // Duration
                Text(formatDuration(recordingService.duration))
                    .font(AppTypography.displayMediumFont)
                    .foregroundStyle(theme.textPrimary)
                    .monospacedDigit()

                Spacer()

                // Controls
                HStack(spacing: Spacing.xxl) {
                    // Cancel
                    Button {
                        recordingService.cancelRecording()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(theme.textTertiary)
                    }

                    // Record / Pause
                    Button {
                        switch recordingService.state {
                        case .idle:
                            try? recordingService.startRecording()
                        case .recording:
                            recordingService.pauseRecording()
                        case .paused:
                            recordingService.resumeRecording()
                        default:
                            break
                        }
                    } label: {
                        Circle()
                            .fill(theme.error)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Group {
                                    if case .recording = recordingService.state {
                                        Image(systemName: "pause.fill")
                                            .font(.system(size: 32))
                                            .foregroundStyle(.white)
                                    } else {
                                        Circle()
                                            .fill(.white)
                                            .frame(width: 24, height: 24)
                                    }
                                }
                            )
                    }

                    // Done
                    Button {
                        if let result = recordingService.stopRecording() {
                            onComplete(result)
                        }
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(theme.success)
                    }
                    .disabled(recordingService.state == .idle)
                }

                Spacer().frame(height: Spacing.xxl)
            }
            .navigationTitle("Record Audio")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(recordingService.audioLevel)
        let variation = sin(CGFloat(index) * 0.5) * 0.3
        return max(4, (level + variation) * 60)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Audio Player Sheet

struct AudioPlayerSheet: View {
    let attachment: AudioAttachment
    let baseURL: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.xl) {
                Spacer()

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(theme.brandPrimary)

                Text(attachment.fileName)
                    .font(AppTypography.bodyMediumFont)
                    .foregroundStyle(theme.textPrimary)

                Text(formatDuration(attachment.duration))
                    .font(AppTypography.headlineMediumFont)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()

                // Playback controls placeholder
                Text("Audio playback requires AVAudioPlayer integration")
                    .font(AppTypography.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(Spacing.screenPadding)
            .navigationTitle("Voice Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
