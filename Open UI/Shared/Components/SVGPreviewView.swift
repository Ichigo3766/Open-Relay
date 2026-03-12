import SwiftUI
import SwiftDraw

// MARK: - SVG Preview View

/// Renders SVG code as a native rasterized image using SwiftDraw.
///
/// ## Architecture
/// Follows the same pattern as `MermaidPreviewView` and `ChartPreviewView`:
/// - Streaming → shows as a plain code block (skipped via StreamingMarkdownView OPT 4)
/// - After streaming → renders the SVG via SwiftDraw off the main thread
/// - On parse/render failure → gracefully falls back to highlighted source view
///
/// ## Performance
/// - **Pure Swift rendering** — no WebView, no JavaScript, no CoreGraphics overhead
/// - **One-time render** via `.task(id:)` triggered when the view appears
/// - **Async off main thread** — `Task.detached(priority: .userInitiated)` so the
///   rasterization never blocks the scroll view or keyboard
/// - **Cached in `@State`** — rendered `UIImage` survives SwiftUI re-evaluations
/// - **Re-renders on colorScheme change** — task id includes colorScheme so dark/light
///   mode switches get fresh renders
struct SVGPreviewView: View {
    let code: String

    @State private var renderedImage: UIImage?
    @State private var renderError: String?
    @State private var isRendering = true
    @State private var showSource = false
    @State private var codeCopied = false
    @State private var showFullscreen = false

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
                    svgView
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
        // Re-render whenever the SVG source or color scheme changes
        .task(id: "\(code.hashValue)-\(colorScheme)") {
            await renderSVG()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Language label with icon
            HStack(spacing: 5) {
                Image(systemName: "skew")
                    .font(.system(size: 10, weight: .semibold))
                Text("svg")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.secondary)

            Spacer()

            // Image/Source toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSource.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSource ? "skew" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .medium))
                    Text(showSource ? "Image" : "Source")
                        .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)

            // Fullscreen button — only shown when render succeeded
            if renderedImage != nil {
                Button {
                    showFullscreen = true
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.3))
        .fullScreenCover(isPresented: $showFullscreen) {
            SVGFullscreenView(code: code, image: renderedImage)
        }
    }

    // MARK: - SVG Render View

    private var svgView: some View {
        Group {
            if isRendering {
                // Loading state — matches MermaidPreviewView style
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                    Text("Rendering SVG…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            } else if let image = renderedImage {
                // Success — display rasterized SVG
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(12)
            } else if let error = renderError {
                // Error — show brief message and fall back to source automatically
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    Text("SVG rendering failed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.system(size: 11))
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
        HighlightedSourceView(code: code, language: "xml")
    }

    // MARK: - Rendering

    /// Rasterizes the SVG string off the main thread using SwiftDraw.
    /// SwiftDraw's `SVG(string:)` init + `rasterize()` are both pure Swift
    /// with no UIKit main-thread requirement, so this is safe in a detached task.
    private func renderSVG() async {
        isRendering = true
        renderError = nil
        renderedImage = nil

        let svgCode = code

        let result = await Task.detached(priority: .userInitiated) { () -> Result<UIImage, SVGRenderError> in
            let data = Data(svgCode.utf8)
            guard let svg = SVG(data: data) else {
                return .failure(.parseFailure)
            }
            let uiImage = svg.rasterize()
            return .success(uiImage)
        }.value

        switch result {
        case .success(let image):
            self.renderedImage = image
            self.isRendering = false
        case .failure(let error):
            self.renderError = error.localizedDescription
            self.isRendering = false
        }
    }
}

// MARK: - SVG Render Error

private enum SVGRenderError: LocalizedError {
    case parseFailure
    var errorDescription: String? { "Invalid or unsupported SVG" }
}

// MARK: - SVG Fullscreen View

/// Fullscreen presentation for viewing SVG diagrams at full resolution.
/// Supports pinch-to-zoom via `ZoomableImageView`, source toggle, copy, and share.
struct SVGFullscreenView: View {
    let code: String
    let image: UIImage?

    @State private var showSource = false
    @State private var codeCopied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if showSource {
                    HighlightedSourceView(
                        code: code,
                        language: "xml",
                        truncate: false,
                        maxHeight: .infinity
                    )
                    .transition(.opacity)
                } else if let image {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.opacity)
                } else {
                    // Shouldn't happen, but guard against nil image
                    HighlightedSourceView(
                        code: code,
                        language: "xml",
                        truncate: false,
                        maxHeight: .infinity
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSource)
            .navigationTitle("SVG")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Image / Source toggle
                    Button {
                        withAnimation { showSource.toggle() }
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: showSource ? "skew" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    }

                    // Copy SVG source or rendered image
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
                            .font(.system(size: 14, weight: .medium))
                    }

                    // Share rendered image
                    if let image, !showSource {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview("SVG Image")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                }
            }
        }
    }
}
