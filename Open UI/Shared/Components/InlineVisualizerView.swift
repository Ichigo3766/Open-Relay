import SwiftUI
import WebKit

// MARK: - Notification

extension Notification.Name {
    /// Posted by `InlineVisualizerView` when the user taps "Send prompt".
    /// userInfo key `"text"` contains the prompt string.
    static let vizSendPrompt = Notification.Name("vizSendPrompt")
}

// MARK: - InlineVisualizerView

/// Renders HTML/SVG visualization content extracted from `@@@VIZ-START` / `@@@VIZ-END` markers.
///
/// Uses `StreamingWebPreview` (the same engine as the HTML code-block preview) for
/// rock-solid rendering. During streaming, incremental DOM updates are applied via
/// `reconcileContent`; when the VIZ block closes, `finalizeContent` executes all
/// inline scripts (Chart.js, D3, etc.) and reports the final height.
struct InlineVisualizerView: View {
    /// The raw HTML/SVG content to render (between the VIZ markers).
    let content: String
    /// Whether the content is still being streamed (partial content).
    var isStreaming: Bool = false

    @State private var webViewHeight: CGFloat = 1
    @State private var showFullscreen = false
    @State private var codeCopied = false

    @Environment(\.colorScheme) private var colorScheme

    private let maxHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            LazyStreamingWebPreview(
                content: content,
                mode: .html,
                isStreaming: isStreaming,
                isDark: colorScheme == .dark,
                height: $webViewHeight
            )
            .frame(height: min(max(webViewHeight, 1), maxHeight))
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
        .fullScreenCover(isPresented: $showFullscreen) {
            VizFullscreenView(content: content, colorScheme: colorScheme)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Label("Visualization", systemImage: "chart.xyaxis.line")
                .font(.system(.caption, design: .default))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Spacer()

            if isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
            }

            // Copy button
            Button {
                UIPasteboard.general.string = content
                Haptics.notify(.success)
                withAnimation(.spring()) { codeCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.spring()) { codeCopied = false }
                }
            } label: {
                Image(systemName: codeCopied ? "checkmark" : "square.on.square")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy visualization HTML")

            // Fullscreen button
            if !isStreaming {
                Button {
                    showFullscreen = true
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View fullscreen")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.3))
    }
}

// MARK: - Fullscreen Visualizer

private struct VizFullscreenView: View {
    let content: String
    let colorScheme: ColorScheme

    @State private var webViewHeight: CGFloat = 1000
    @State private var codeCopied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StreamingWebPreview(
                content: content,
                mode: .html,
                isStreaming: false,
                isDark: colorScheme == .dark,
                height: $webViewHeight
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Visualization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = content
                        Haptics.notify(.success)
                        withAnimation(.spring()) { codeCopied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation(.spring()) { codeCopied = false }
                        }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark" : "square.on.square")
                    }
                }
            }
        }
    }
}
