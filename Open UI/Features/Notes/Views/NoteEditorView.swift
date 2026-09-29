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
    @State private var files: NoteFilesModel?
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var isPreviewMode = true
    @State private var recordingService = AudioRecordingService()
    @State private var isGeneratingTitle = false
    @State private var isEnhancing = false
    @State private var aiErrorMessage: String?
    @State private var autoSaveTask: Task<Void, Never>?

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
                                isGeneratingTitle ? "Generating..." : "Generate Title",
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
                    .disabled(files?.canEdit != true || files?.isBusy == true || files?.pending != nil || isImporting)

                    // File attachment
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .accessibilityLabel("Attach file")
                    .disabled(files?.canEdit != true || files?.isBusy == true || files?.pending != nil || isImporting)

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
        .task { await loadNote() }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(recordingService: recordingService) { result in
                handleAudioRecording(result)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .onDisappear { importTask?.cancel() }
    }

    // MARK: - Editor Content

    private func editorContent(_ note: Note) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    // Title
                    if isPreviewMode {
                        Text(titleText.isEmpty ? "Untitled" : titleText)
                            .scaledFont(size: 28, weight: .bold)
                            .foregroundStyle(theme.textPrimary)
                    } else {
                        TextField("Title", text: $titleText)
                            .scaledFont(size: 28, weight: .bold)
                            .foregroundStyle(theme.textPrimary)
                            .onChange(of: titleText) { _, _ in scheduleAutoSave() }
                    }

                    // Metadata
                    HStack(spacing: Spacing.md) {
                        Text("\(note.wordCount) words")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)

                        Text("\(contentText.count) characters")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)

                        Spacer()

                        Text("Updated \(note.updatedAt.chatTimestamp)")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }

                    Divider()
                        .foregroundStyle(theme.divider)

                    if let files {
                        NoteFilesSection(model: files)
                    }
                    if isImporting { ProgressView("Importing attachment…") }

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
                .scaledFont(size: 16)
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
                .scaledFont(size: 14, design: .monospaced)
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
                    .scaledFont(size: 16)
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

    // MARK: - Helpers

    private func loadNote() async {
        guard let manager = notesManager else {
            isLoading = false
            return
        }
        if let api = apiClient {
            let container = dependencies
            let userId = container.authViewModel.currentUser?.id
            let model = NoteFilesModel(noteId: noteId, api: api) { [weak container] in
                container?.apiClient === api && container?.authViewModel.currentUser?.id == userId
            }
            files = model
            let json = await model.load()
            guard !Task.isCancelled, model.sessionIsCurrent else { return }
            if let json { note = Note.fromServerJSON(json) }
        }
        if note == nil { note = manager.fetchLocalNote(id: noteId) }
        if let note {
            titleText = note.title
            contentText = note.content
        }
        isLoading = false
    }

    private func scheduleAutoSave() {
        hasChanges = true
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
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
        guard let files else { return }
        importTask = Task { await files.attach(data: result.data, name: result.fileName) }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let files else { return }
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { files.error = error.localizedDescription }
            return
        }
        guard !isImporting else { return }
        isImporting = true
        importTask = Task {
            defer { isImporting = false }
            for url in urls {
                do {
                    try Task.checkCancellation()
                    let data = try await Task.detached(priority: .userInitiated) {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url, options: .mappedIfSafe)
                    }.value
                    try Task.checkCancellation()
                    await files.attach(data: data, name: url.lastPathComponent)
                    if files.error != nil { break }
                } catch {
                    if !Task.isCancelled { files.error = error.localizedDescription }
                    break
                }
            }
        }
    }

    private func insertMarkdown(_ prefix: String) {
        contentText += prefix
    }

    private func wrapSelection(_ wrapper: String) {
        contentText += "\(wrapper)text\(wrapper)"
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
                    .scaledFont(size: 36, weight: .bold)
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
                            .scaledFont(size: 48)
                            .foregroundStyle(theme.textTertiary)
                    }

                    // Record / Pause
                    Button {
                        switch recordingService.state {
                        case .idle:
                            Task { try? await recordingService.startRecording() }
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
                                            .scaledFont(size: 32)
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
                            .scaledFont(size: 48)
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
