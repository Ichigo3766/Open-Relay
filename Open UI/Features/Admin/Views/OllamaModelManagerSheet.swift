import SwiftUI
import UniformTypeIdentifiers

// MARK: - OllamaModelManagerSheet

struct OllamaModelManagerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let urlIdx: Int
    let apiClient: APIClient?

    @State private var viewModel = OllamaModelManagerViewModel()
    @State private var showGGUFFilePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Global error
                    if let err = viewModel.errorMessage {
                        errorBanner(err)
                            .padding(.horizontal, Spacing.screenPadding)
                    }

                    pullSection
                    deleteSection
                    createSection
                    experimentalSection

                    Spacer(minLength: 60)
                }
                .padding(.top, Spacing.md)
            }
            .background(theme.background)
            .navigationTitle("Manage Ollama")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark") {
                        viewModel.cancelAllActiveTasks()
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .tint(.secondary)
                }
            }
        }
        .task {
            viewModel.configure(apiClient: apiClient, urlIdx: urlIdx)
            await viewModel.loadModels()
        }
        .fileImporter(
            isPresented: $showGGUFFilePicker,
            allowedContentTypes: [.init(filenameExtension: "gguf") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                viewModel.uploadGGUFFile(url: url)
                if accessed { url.stopAccessingSecurityScopedResource() }
            case .failure(let error):
                viewModel.ggufUploadError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Delete \"\(viewModel.selectedDeleteModel)\"?",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This model will be permanently removed from your Ollama server.")
        }
    }

    // MARK: - Pull Section

    private var pullSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header with "Update All" button
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                    Text("Pull a model from Ollama.com")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                }
                Spacer()
                if !viewModel.installedModels.isEmpty {
                    Button("Update All") {
                        viewModel.updateAllModels()
                    }
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.brandPrimary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.screenPadding)

            // Input row
            HStack(spacing: Spacing.sm) {
                TextField("Enter model tag (e.g. mistral:7b)", text: $viewModel.pullModelName)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .background(theme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(theme.inputBorder, lineWidth: 0.5)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { viewModel.pullModel(name: viewModel.pullModelName) }

                Button {
                    viewModel.pullModel(name: viewModel.pullModelName)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .scaledFont(size: 22)
                        .foregroundStyle(
                            viewModel.pullModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? theme.textTertiary : theme.brandPrimary
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.pullModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Spacing.screenPadding)

            // Link to ollama.com/library
            HStack(spacing: 4) {
                Text("To access the available model names for downloading,")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                Link("click here.", destination: URL(string: "https://ollama.com/library")!)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.screenPadding)

            // Duplicate warning
            if let dup = viewModel.duplicatePullName {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.brandPrimary)
                    Text("\"\(dup)\" is already downloading.")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, Spacing.screenPadding)
            }

            // Active pulls — one card per model, each with its own whole-model progress bar
            if !viewModel.activePulls.isEmpty {
                VStack(spacing: Spacing.sm) {
                    ForEach(Array(viewModel.activePulls.keys).sorted(), id: \.self) { name in
                        if let state = viewModel.activePulls[name] {
                            pullProgressRow(name: name, state: state)
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
            }
        }
    }

    /// One card per actively-pulling model. Progress is whole-model (all layers summed), not per-file.
    private func pullProgressRow(name: String, state: OllamaPullState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if state.error != nil {
                    Button {
                        viewModel.dismissPullError(name: name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.error)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        viewModel.cancelPull(name: name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let err = state.error {
                Text(err)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.error)
                    .lineLimit(2)
            } else {
                // Whole-model progress bar
                let progress = state.overallProgress

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(theme.inputBackground)
                            .frame(height: 6)

                        if let p = progress {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.brandPrimary)
                                .frame(width: geo.size.width * CGFloat(p) / 100.0, height: 6)
                                .animation(.linear(duration: 0.2), value: p)
                        } else {
                            // Indeterminate shimmer while layers not yet known
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.brandPrimary.opacity(0.4))
                                .frame(width: geo.size.width * 0.3, height: 6)
                        }
                    }
                }
                .frame(height: 6)

                HStack {
                    if let p = progress {
                        Text(String(format: "%.0f%%", p))
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Text(state.status)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(Spacing.md)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(
                    state.error != nil ? theme.error.opacity(0.5) : theme.cardBorder,
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader(title: "Delete a model", icon: "trash")

            HStack(spacing: Spacing.sm) {
                // Model picker
                Menu {
                    if viewModel.isLoadingModels {
                        Text("Loading…")
                    } else if viewModel.installedModels.isEmpty {
                        Text("No models installed")
                    } else {
                        ForEach(viewModel.installedModels, id: \.name) { model in
                            Button(model.name) {
                                viewModel.selectedDeleteModel = model.name
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(viewModel.selectedDeleteModel.isEmpty ? "Select a model" : viewModel.selectedDeleteModel)
                            .scaledFont(size: 15)
                            .foregroundStyle(viewModel.selectedDeleteModel.isEmpty ? theme.textTertiary : theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .background(theme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(theme.inputBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)

                // Delete button
                Button {
                    if !viewModel.selectedDeleteModel.isEmpty {
                        viewModel.showDeleteConfirmation = true
                    }
                } label: {
                    if viewModel.isDeletingModel {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "trash.fill")
                            .scaledFont(size: 18)
                            .foregroundStyle(
                                viewModel.selectedDeleteModel.isEmpty ? theme.textTertiary : theme.error
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedDeleteModel.isEmpty || viewModel.isDeletingModel)
            }
            .padding(.horizontal, Spacing.screenPadding)

            if let err = viewModel.deleteError {
                errorBanner(err)
                    .padding(.horizontal, Spacing.screenPadding)
            }
        }
    }

    // MARK: - Create Section

    private var createSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader(title: "Create a model", icon: "plus.circle")

            VStack(spacing: Spacing.sm) {
                // Model tag input
                HStack(spacing: Spacing.sm) {
                    TextField("Enter model tag (e.g. my-modelfile)", text: $viewModel.createModelTag)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 12)
                        .background(theme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .strokeBorder(theme.inputBorder, lineWidth: 0.5)
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    // Upload button
                    Button {
                        viewModel.createModel()
                    } label: {
                        Image(systemName: "square.and.arrow.up.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(
                                (viewModel.createModelTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                 viewModel.createModelfileJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    ? theme.textTertiary : theme.brandPrimary
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        viewModel.createModelTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        viewModel.createModelfileJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                // JSON modelfile editor
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.createModelfileJSON)
                        .scaledFont(size: 13)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.sm)
                        .background(theme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .strokeBorder(theme.inputBorder, lineWidth: 0.5)
                        )
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if viewModel.createModelfileJSON.isEmpty {
                        Text("e.g. {\"model\": \"my-modelfile\", \"from\": \"ollama:7b\"}")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textTertiary.opacity(0.6))
                            .padding(Spacing.md)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, Spacing.screenPadding)

            // Create progress
            if let state = viewModel.createState {
                createProgressView(state: state)
                    .padding(.horizontal, Spacing.screenPadding)
            }
        }
    }

    private func createProgressView(state: OllamaCreateState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Creating model…")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button {
                    viewModel.cancelCreate()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            if let err = state.error {
                Text(err)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.error)
                    .lineLimit(2)
            } else {
                if let progress = state.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.inputBackground)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.brandPrimary)
                                .frame(width: geo.size.width * CGFloat(progress) / 100.0, height: 6)
                                .animation(.linear(duration: 0.2), value: progress)
                        }
                    }
                    .frame(height: 6)

                    Text(String(format: "%.0f%%", progress))
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(state.status)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(
                    state.error != nil ? theme.error.opacity(0.5) : theme.cardBorder,
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Experimental Section

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Experimental")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button(viewModel.showExperimental ? "Hide" : "Show") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.showExperimental.toggle()
                    }
                }
                .scaledFont(size: 14)
                .foregroundStyle(theme.brandPrimary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.screenPadding)

            if viewModel.showExperimental {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // GGUF header + mode toggle
                    HStack {
                        Text("Upload a GGUF model")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        // Button shows the CURRENT mode name; tapping switches to the other
                        Button(viewModel.ggufMode == .file ? "File Mode" : "URL Mode") {
                            viewModel.ggufMode = viewModel.ggufMode == .file ? .url : .file
                        }
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.brandPrimary)
                        .buttonStyle(.plain)
                    }

                    if viewModel.ggufMode == .file {
                        // File Mode (default): real GGUF file picker + upload
                        ggufFileModeView
                    } else {
                        // URL Mode: HuggingFace URL → pull API with hf.co prefix
                        HStack(spacing: Spacing.sm) {
                            TextField("Enter HuggingFace model URL…", text: $viewModel.ggufURL)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textPrimary)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, 12)
                                .background(theme.inputBackground)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                        .strokeBorder(theme.inputBorder, lineWidth: 0.5)
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .submitLabel(.go)
                                .onSubmit { viewModel.pullGGUFFromURL() }

                            Button {
                                viewModel.pullGGUFFromURL()
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .scaledFont(size: 22)
                                    .foregroundStyle(
                                        viewModel.ggufURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? theme.textTertiary : theme.brandPrimary
                                    )
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.ggufURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        HStack(spacing: 4) {
                            Text("To access the GGUF models available for downloading,")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                            Link("click here.", destination: URL(string: "https://huggingface.co/models?library=gguf")!)
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.brandPrimary)
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - GGUF File Mode

    private var ggufFileModeView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if viewModel.isUploadingGGUF {
                // Upload progress
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(viewModel.ggufUploadStatus.isEmpty ? "Uploading…" : viewModel.ggufUploadStatus)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            viewModel.cancelGGUFUpload()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.inputBackground)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.brandPrimary)
                                .frame(
                                    width: geo.size.width * CGFloat(viewModel.ggufUploadProgress ?? 0) / 100.0,
                                    height: 6
                                )
                                .animation(.linear(duration: 0.3), value: viewModel.ggufUploadProgress)
                        }
                    }
                    .frame(height: 6)

                    if let p = viewModel.ggufUploadProgress {
                        Text(String(format: "%.0f%%", p))
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Preparing…")
                                .scaledFont(size: 11)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                .padding(Spacing.md)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
            } else if let err = viewModel.ggufUploadError {
                // Error state
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.error)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upload failed")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.error)
                        Text(err)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        viewModel.ggufUploadError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(Spacing.md)
                .background(theme.error.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(theme.error.opacity(0.3), lineWidth: 0.5)
                )
            } else {
                // Pick file button
                Button {
                    showGGUFFilePicker = true
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "doc.badge.plus")
                            .scaledFont(size: 17)
                            .foregroundStyle(theme.brandPrimary)
                        Text("Click here to select")
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 14)
                    .background(theme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(theme.inputBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                Text("To access the GGUF models available for downloading,")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                Link("click here.", destination: URL(string: "https://huggingface.co/models?library=gguf")!)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
            Text(title)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(theme.error)
                .lineLimit(2)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
    }
}
