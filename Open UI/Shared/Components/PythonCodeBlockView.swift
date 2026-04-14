import SwiftUI
import MarkdownView

// MARK: - Python Code Block View

/// Renders a Python code block with a "Run" button and an inline output panel.
///
/// The code is displayed using `MarkdownView` (same engine as all other code blocks)
/// which provides full syntax highlighting via HighlightSwift. Pressing "Run"
/// executes the code locally via `PythonExecutionService` (Pyodide/WASM) and shows
/// stdout, stderr, and any matplotlib figures inline — no server round-trip required.
///
/// The first run downloads Pyodide (~10 MB, cached afterwards).
struct PythonCodeBlockView: View {

    let code: String

    // MARK: - Execution State

    enum RunState: Equatable {
        case idle
        case loading        // Pyodide engine loading
        case running        // Code executing
        case done(result: PythonExecutionResult)

        static func == (lhs: RunState, rhs: RunState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.running, .running): return true
            case (.done, .done): return true
            default: return false
            }
        }
    }

    @State private var runState: RunState = .idle
    @State private var codeCopied = false
    @State private var showFullCode = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityScale) private var accessibilityScale

    private static let baseBodyFontSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize

    private var scaledTheme: MarkdownTheme {
        let scale = accessibilityScale.scale(for: .content)
        var t = MarkdownTheme.default
        if abs(scale - 1.0) > 0.01 {
            t.align(to: Self.baseBodyFontSize * scale)
        }
        return t
    }

    // The markdown string that produces a syntax-highlighted Python block
    private var markdownCodeBlock: String {
        "```python\n\(code)\n```"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Header bar ──────────────────────────────────────────────────
            headerBar

            // ── Code body (MarkdownView handles syntax highlighting) ─────────
            MarkdownView(markdownCodeBlock, theme: scaledTheme).codeBarHidden(true)

            // ── Output panel (shown after run) ──────────────────────────────
            if case .loading = runState {
                loadingPanel
            } else if case .running = runState {
                runningPanel
            } else if case .done(let result) = runState {
                outputPanel(result: result)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .sheet(isPresented: $showFullCode) {
            FullCodeView(code: code, language: "python")
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Language label
            Label("python", systemImage: "chevron.left.forwardslash.chevron.right")
                .labelStyle(.titleOnly)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Spacer()

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
                Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Fullscreen button
            Button {
                showFullCode = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Run button
            runButton
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var runButton: some View {
        let isActive = runState == .loading || runState == .running

        Button {
            guard !isActive else { return }
            runCode()
        } label: {
            HStack(spacing: 5) {
                if isActive {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .scaledFont(size: 10, weight: .bold)
                }
                Text(isActive ? "Running…" : "Run")
                    .scaledFont(size: 12, weight: .semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.gray : Color.accentColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    // MARK: - Status Panels

    private var loadingPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
            Text("Loading Python runtime…")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private var runningPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
            Text("Executing…")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Output Panel

    @ViewBuilder
    private func outputPanel(result: PythonExecutionResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .overlay(Color.primary.opacity(0.08))

            // Output header
            HStack(spacing: 6) {
                Image(systemName: result.status == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(result.status == .success ? .green : .red)
                Text("Output")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                // Re-run button
                Button {
                    runCode()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))

            Divider()
                .overlay(Color.primary.opacity(0.08))

            // stdout
            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView(.vertical) {
                    Text(result.stdout)
                        .scaledFont(size: 12, design: .monospaced)
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .background(Color(.secondarySystemBackground))
            }

            // stderr
            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                    .overlay(Color.primary.opacity(0.06))
                ScrollView(.vertical) {
                    Text(result.stderr)
                        .scaledFont(size: 12, design: .monospaced)
                        .foregroundStyle(.red)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .background(Color(.secondarySystemBackground))
            }

            // matplotlib images
            if !result.images.isEmpty {
                Divider()
                    .overlay(Color.primary.opacity(0.06))
                VStack(spacing: 8) {
                    ForEach(Array(result.images.enumerated()), id: \.offset) { _, b64 in
                        if let data = Data(base64Encoded: b64),
                           let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contextMenu {
                                    Button {
                                        UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
                                        Haptics.notify(.success)
                                    } label: {
                                        Label("Save to Photos", systemImage: "photo")
                                    }
                                    Button {
                                        UIPasteboard.general.image = uiImage
                                        Haptics.notify(.success)
                                    } label: {
                                        Label("Copy Image", systemImage: "doc.on.doc")
                                    }
                                }
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
            }

            // Empty output
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               result.images.isEmpty {
                HStack {
                    Text("(no output)")
                        .scaledFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .italic()
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
            }
        }
    }

    // MARK: - Run Action

    private func runCode() {
        let service = PythonExecutionService.shared

        // Set state based on current engine state
        switch service.engineState {
        case .notLoaded, .loading:
            runState = .loading
        case .ready:
            runState = .running
        case .error:
            runState = .running // Will immediately return an error result
        }

        service.execute(code: code) { result in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.runState = .done(result: result)
                }
                if result.status == .success {
                    Haptics.notify(.success)
                } else {
                    Haptics.notify(.error)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Python Code Block") {
    ScrollView {
        VStack(spacing: 16) {
            PythonCodeBlockView(code: """
                import math

                def fibonacci(n):
                    if n <= 1:
                        return n
                    return fibonacci(n-1) + fibonacci(n-2)

                for i in range(10):
                    print(f"fib({i}) = {fibonacci(i)}")
                """)

            PythonCodeBlockView(code: """
                import numpy as np
                import matplotlib.pyplot as plt

                x = np.linspace(0, 2 * np.pi, 100)
                y = np.sin(x)

                plt.figure(figsize=(8, 4))
                plt.plot(x, y, 'b-', linewidth=2)
                plt.title('Sine Wave')
                plt.grid(True)
                plt.show()
                """)
        }
        .padding()
    }
    .themed()
}
