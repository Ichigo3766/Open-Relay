import SwiftUI

// MARK: - Admin Pipelines View

/// Admin Settings → Pipelines — manage pipeline servers, install/delete pipelines, configure valves.
struct AdminPipelinesView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminPipelinesViewModel()
    @State private var showDeleteConfirm = false
    @State private var pipelineToDelete: Pipeline? = nil

    private var selectedServer: PipelineServer? {
        viewModel.pipelineServers.first { $0.idx == viewModel.selectedServerIdx }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    if viewModel.isLoading {
                        loadingState
                    } else if viewModel.pipelineServers.isEmpty {
                        emptyState
                    } else {
                        sourceSection
                        if !viewModel.pipelines.isEmpty || viewModel.isLoadingPipelines {
                            pipelinesSection
                        }
                        if !viewModel.isLoadingPipelines && !viewModel.valveProperties.isEmpty {
                            valvesSection
                        }
                    }
                    Spacer(minLength: 100)
                }
                .padding(.top, Spacing.md)
            }
            .background(theme.background)

            if !viewModel.valveProperties.isEmpty && !viewModel.isLoadingValves {
                floatingSaveButton
            }
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.load()
        }
        .confirmationDialog("Delete Pipeline", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            if let p = pipelineToDelete {
                Button("Delete \"\(p.name)\"", role: .destructive) {
                    Task { await viewModel.deletePipeline(id: p.id, urlIdx: viewModel.selectedServerIdx) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This pipeline will be removed from the server.")
        }
    }

    // MARK: - Loading / Empty

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Loading pipelines…").scaledFont(size: 16).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "puzzlepiece.extension").scaledFont(size: 40).foregroundStyle(theme.textTertiary)
            Text("Pipelines Not Detected")
                .scaledFont(size: 16, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text("No pipeline servers are configured. Add an OpenAI API connection pointing to a Pipelines server.")
                .scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.screenPadding)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    // MARK: - Source Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader(icon: "server.rack", title: "Source")

            SettingsSection(footer: "Select the Pipelines server to manage.") {
                // Server picker
                if viewModel.pipelineServers.count > 1 {
                    HStack {
                        Text("Pipeline URL").scaledFont(size: 15).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Menu {
                            ForEach(viewModel.pipelineServers) { server in
                                Button {
                                    viewModel.selectedServerIdx = server.idx
                                    Task { await viewModel.loadPipelines(urlIdx: server.idx) }
                                } label: {
                                    HStack {
                                        Text(server.url).lineLimit(1)
                                        if viewModel.selectedServerIdx == server.idx {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedServer?.url ?? "").scaledFont(size: 14).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").scaledFont(size: 10)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)
                    Divider().padding(.leading, Spacing.md)
                } else {
                    // Show URL as read-only
                    HStack {
                        Text("Pipeline URL").scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text(selectedServer?.url ?? "").scaledFont(size: 14).foregroundStyle(theme.textTertiary).lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)
                    Divider().padding(.leading, Spacing.md)
                }

                // GitHub URL install
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Install from GitHub URL").scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textSecondary)
                    HStack(spacing: Spacing.sm) {
                        TextField("Enter GitHub Raw URL", text: $viewModel.githubURL)
                            .scaledFont(size: 15).foregroundStyle(theme.textPrimary)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                        if viewModel.isDownloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Install") {
                                Task { await viewModel.downloadPipeline(urlIdx: viewModel.selectedServerIdx) }
                            }
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(viewModel.githubURL.isEmpty ? theme.textTertiary : theme.brandPrimary)
                            .disabled(viewModel.githubURL.isEmpty)
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.chatBubblePadding)
            }

            if let err = viewModel.error {
                errorBanner(err)
            }
            if viewModel.downloadSuccess {
                successBanner("Pipeline installed successfully.")
            }
        }
    }

    // MARK: - Pipelines Section

    private var pipelinesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader(icon: "puzzlepiece.extension", title: "Pipelines")

            if viewModel.isLoadingPipelines {
                SettingsSection {
                    HStack { Spacer(); ProgressView().controlSize(.regular).padding(.vertical, Spacing.lg); Spacer() }
                }
            } else {
                SettingsSection {
                    ForEach(Array(viewModel.pipelines.enumerated()), id: \.element.id) { index, pipeline in
                        pipelineRow(pipeline: pipeline, isLast: index == viewModel.pipelines.count - 1)
                    }
                }
            }
        }
    }

    private func pipelineRow(pipeline: Pipeline, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pipeline.name).scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textPrimary)
                    Text(pipeline.type).scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                }
                Spacer()
                if pipeline.hasValves {
                    Button {
                        Task { await viewModel.loadValves(pipelineId: pipeline.id, urlIdx: viewModel.selectedServerIdx) }
                    } label: {
                        Image(systemName: viewModel.selectedPipelineId == pipeline.id ? "gearshape.fill" : "gearshape")
                            .scaledFont(size: 16)
                            .foregroundStyle(viewModel.selectedPipelineId == pipeline.id ? theme.brandPrimary : theme.textTertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    pipelineToDelete = pipeline
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash").scaledFont(size: 14).foregroundStyle(theme.error).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.sm)
            if !isLast { Divider().padding(.leading, Spacing.screenPadding) }
        }
    }

    // MARK: - Valves Section

    private var valvesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader(icon: "slider.horizontal.3", title: "Valves")

            if viewModel.isLoadingValves {
                SettingsSection {
                    HStack { Spacer(); ProgressView().controlSize(.regular).padding(.vertical, Spacing.lg); Spacer() }
                }
            } else if viewModel.valveProperties.isEmpty {
                SettingsSection {
                    Text("No valves").scaledFont(size: 14).foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                }
            } else {
                SettingsSection {
                    ForEach(Array(viewModel.valveProperties.enumerated()), id: \.element.key) { index, prop in
                        valveRow(key: prop.key, spec: prop.spec)
                        if index < viewModel.valveProperties.count - 1 {
                            Divider().padding(.leading, Spacing.md)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func valveRow(key: String, spec: [String: Any]) -> some View {
        let title = viewModel.valveTitle(key: key, spec: spec)
        let description = viewModel.valveDescription(spec: spec)
        let type = viewModel.valveType(spec: spec)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let desc = description {
                Text(title).scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textSecondary)
                if type == "boolean" {
                    HStack {
                        Text(desc).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                        Spacer()
                        Toggle("", isOn: viewModel.boolBinding(for: key)).labelsHidden().tint(theme.brandPrimary)
                    }
                } else if let options = viewModel.valveEnumOptions(spec: spec) {
                    let currentVal = viewModel.valves[key] as? String ?? options.first ?? ""
                    HStack {
                        Text(desc).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                        Spacer()
                        Menu {
                            ForEach(options, id: \.self) { opt in
                                Button { viewModel.valves[key] = opt } label: {
                                    HStack {
                                        Text(opt)
                                        if currentVal == opt { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(currentVal).scaledFont(size: 13)
                                Image(systemName: "chevron.up.chevron.down").scaledFont(size: 10)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                    }
                } else {
                    HStack {
                        Text(desc).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                        Spacer()
                        TextField("Value", text: viewModel.stringBinding(for: key))
                            .scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .frame(maxWidth: 180)
                    }
                }
            } else {
                if type == "boolean" {
                    HStack {
                        Text(title).scaledFont(size: 15).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Toggle("", isOn: viewModel.boolBinding(for: key)).labelsHidden().tint(theme.brandPrimary)
                    }
                } else {
                    Text(title).scaledFont(size: 14, weight: .medium).foregroundStyle(theme.textSecondary)
                    TextField("Value", text: viewModel.stringBinding(for: key))
                        .scaledFont(size: 15).foregroundStyle(theme.textPrimary)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    // MARK: - Floating Save Button

    private var floatingSaveButton: some View {
        Button {
            Task { await viewModel.saveValves(urlIdx: viewModel.selectedServerIdx) }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.xs) {
                if viewModel.isSavingValves {
                    ProgressView().controlSize(.small).tint(.white)
                } else if viewModel.valvesSaved {
                    Image(systemName: "checkmark.circle.fill").scaledFont(size: 14)
                    Text("Saved").scaledFont(size: 14, weight: .semibold)
                } else {
                    Image(systemName: "square.and.arrow.down").scaledFont(size: 14, weight: .semibold)
                    Text("Save").scaledFont(size: 14, weight: .semibold)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
            .background(viewModel.valvesSaved ? Color.green : theme.brandPrimary)
            .clipShape(Capsule())
            .shadow(color: (viewModel.valvesSaved ? Color.green : theme.brandPrimary).opacity(0.4), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSavingValves)
        .padding(.trailing, Spacing.screenPadding)
        .padding(.bottom, Spacing.lg)
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon).scaledFont(size: 13, weight: .semibold).foregroundStyle(theme.brandPrimary)
            Text(title.uppercased()).scaledFont(size: 12, weight: .medium).foregroundStyle(theme.textTertiary).tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.circle.fill").scaledFont(size: 12).foregroundStyle(theme.error)
            Text(message).scaledFont(size: 12).foregroundStyle(theme.error).lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func successBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "checkmark.circle.fill").scaledFont(size: 12).foregroundStyle(.green)
            Text(message).scaledFont(size: 12).foregroundStyle(.green)
            Spacer()
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
    }
}
