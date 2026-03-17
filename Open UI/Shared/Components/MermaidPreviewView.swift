import SwiftUI
import BeautifulMermaid

// MARK: - Mermaid Preview View

/// Renders mermaid diagram code as a native image using BeautifulMermaid.
///
/// ## Architecture
/// Follows the same pattern as `ChartPreviewView` and `HTMLPreviewView`:
/// - During streaming → shows as a syntax-highlighted code block
/// - After streaming → renders the diagram as a native `UIImage`
/// - On parse failure → gracefully falls back to code block view
///
/// ## Performance
/// - **Pure Swift rendering** — no WebView, no JavaScript
/// - **One-time render** via `.task` when the view appears
/// - **Cached** — rendered image is stored in `@State` so it survives
///   SwiftUI re-evaluations without re-rendering
/// - **Async** — rendering happens off the main thread
/// - **Memory efficient** — output is a single `UIImage` (~50-200KB)
///   vs. a WebView (~10-30MB)
struct MermaidPreviewView: View {
    let code: String

    init(code: String) {
        self.code = code
    }

    @SwiftUI.State private var renderedImage: UIImage?
    @SwiftUI.State private var renderError: String?
    @SwiftUI.State private var isRendering = true
    @SwiftUI.State private var codeCopied = false
    @SwiftUI.State private var showSource = false
    @SwiftUI.State private var showFullscreen = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // ── Header bar ──
            headerBar

            Divider()

            // ── Content area ──
            ZStack {
                if showSource {
                    sourceView
                        .transition(.opacity)
                } else {
                    diagramView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSource)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
        .task(id: "\(code)\(colorScheme)") {
            await renderDiagram()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Language label with icon
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .scaledFont(size: 10, weight: .semibold)
                Text("mermaid")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.secondary)

            Spacer()

            // Diagram/Source toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSource.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSource ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right")
                        .scaledFont(size: 11, weight: .medium)
                    Text(showSource ? "Diagram" : "Source")
                        .scaledFont(size: 12, weight: .medium)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Copy button
            Button {
                UIPasteboard.general.string = code
                Haptics.notify(.success)
                withAnimation(.spring()) { codeCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.spring()) { codeCopied = false }
                }
            } label: {
                Group {
                    if codeCopied {
                        Label("Copied", systemImage: "checkmark")
                            .transition(.opacity.combined(with: .scale))
                    } else {
                        Label("Copy", systemImage: "square.on.square")
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)

            // Fullscreen button (only when image is available)
            if renderedImage != nil {
                Button {
                    showFullscreen = true
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.3))
        .fullScreenCover(isPresented: $showFullscreen) {
            MermaidFullscreenView(
                code: code,
                image: renderedImage,
                theme: theme,
                colorScheme: colorScheme
            )
        }
    }

    // MARK: - Diagram View

    private var diagramView: some View {
        Group {
            if isRendering {
                // Loading state
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                    Text("Rendering diagram…")
                        .scaledFont(size: 12)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            } else if let image = renderedImage {
                // Success — show rendered diagram
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(12)
            } else if let error = renderError {
                // Error — show error message + fallback to source
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .scaledFont(size: 20)
                        .foregroundStyle(.orange)
                    Text("Diagram rendering failed")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .scaledFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }
        }
    }

    // MARK: - Source View

    private var sourceView: some View {
        HighlightedSourceView(code: code, language: "mermaid")
    }

    // MARK: - Source Preprocessing

    /// Sanitize mermaid source before rendering.
    ///
    /// The BeautifulMermaid library doesn't support:
    /// 1. `\n` escape sequences inside node labels — causes NSAttributedString to
    ///    measure only the first "line", producing undersized nodes and clipped text.
    /// 2. `**bold**` markdown inside labels — rendered literally as `**text**`.
    ///
    /// Strategy: scan each line and replace these patterns only inside the
    /// label portion of node definitions and edge declarations, leaving the
    /// structural mermaid syntax (arrows, IDs, etc.) intact.
    private func sanitizeSource(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let sanitized = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comment lines, directive lines, and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("%%") || trimmed.hasPrefix("%%{") {
                return line
            }
            var result = line
            // 1. Replace literal \n escape sequences inside labels with a space.
            result = result.replacingOccurrences(of: #"\n"#, with: " ")
            // 2. Strip **bold** markdown markers (replace **text** with text).
            result = result.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            // 3. Strip surrounding quotes from ["quoted label"] node syntax.
            //    BeautifulMermaid's parser captures the content literally including quotes,
            //    causing the node to display with quotes or fall back to showing the node ID.
            //    Convert: ID["label"] → ID[label]  and  ID("label") → ID(label)
            result = result.replacingOccurrences(of: #"\[\"([^\"]+)\"\]"#, with: "[$1]", options: .regularExpression)
            result = result.replacingOccurrences(of: #"\(\"([^\"]+)\"\)"#, with: "($1)", options: .regularExpression)
            return result
        }
        return sanitized.joined(separator: "\n")
    }

    // MARK: - Rendering

    private func renderDiagram() async {
        isRendering = true
        renderError = nil

        // Pick theme based on color scheme
        let diagramTheme: DiagramTheme = colorScheme == .dark
            ? .tokyoNight
            : .zincLight

        let processedCode = sanitizeSource(code)

        do {
            let image = try await Task.detached(priority: .userInitiated) {
                try MermaidRenderer.renderImage(
                    source: processedCode,
                    theme: diagramTheme,
                    scale: 2.0
                )
            }.value

            await MainActor.run {
                self.renderedImage = image
                self.isRendering = false
            }
        } catch {
            await MainActor.run {
                self.renderError = error.localizedDescription
                self.isRendering = false
            }
        }
    }
}

// MARK: - Mermaid Fullscreen View

/// Fullscreen presentation for viewing mermaid diagrams at full size.
private struct MermaidFullscreenView: View {
    let code: String
    let image: UIImage?
    let theme: AppTheme
    let colorScheme: ColorScheme

    @SwiftUI.State private var showSource = false
    @SwiftUI.State private var codeCopied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if showSource {
                    HighlightedSourceView(code: code, language: "mermaid", truncate: false, maxHeight: .infinity)
                        .transition(.opacity)
                } else if let image {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSource)
            .navigationTitle("Mermaid Diagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Diagram/Source toggle
                    Button {
                        withAnimation { showSource.toggle() }
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: showSource
                            ? "point.3.connected.trianglepath.dotted"
                            : "chevron.left.forwardslash.chevron.right")
                            .scaledFont(size: 14, weight: .medium)
                    }

                    // Copy
                    Button {
                        if showSource {
                            UIPasteboard.general.string = code
                        } else if let image {
                            UIPasteboard.general.image = image
                        }
                        Haptics.notify(.success)
                        withAnimation(.spring()) { codeCopied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation(.spring()) { codeCopied = false }
                        }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                            .scaledFont(size: 14, weight: .medium)
                    }

                    // Share image
                    if let image, !showSource {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Mermaid Diagram")) {
                            Image(systemName: "square.and.arrow.up")
                                .scaledFont(size: 14, weight: .medium)
                        }
                    }
                }
            }
        }
    }
}
