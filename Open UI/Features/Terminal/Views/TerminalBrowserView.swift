import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook
import PhotosUI

// MARK: - Terminal Browser View

/// The terminal side panel: a file browser on top and the shell/process dock
/// below. Shared by iPhone (slide-over) and iPad (trailing column).
struct TerminalBrowserView: View {
    @Bindable var viewModel: TerminalBrowserViewModel
    var onDismiss: () -> Void
    /// Panel surface colour. Defaults to the app background; the iPhone page-card
    /// layout passes the sidebar colour so the panel matches the sidebar.
    var background: SwiftUI.Color? = nil

    @Environment(\.theme) var theme

    // Sheets & dialogs
    @State var showFilePicker = false
    @State var showFolderPicker = false
    @State var showPhotoPicker = false
    @State var photoItems: [PhotosPickerItem] = []
    @State var quickLookURL: URL?
    @State var shareURL: URL?
    @State var heldFile: DownloadedTerminalFile?
    @State var openedFile: TerminalFileItem?
    @State var confirmDelete: [String] = []
    @State var renaming: TerminalFileItem?
    @State var renameText = ""
    @State var creating: CreateKind?
    @State var createText = ""
    @State var moving: [String] = []
    @State var compareSource: TerminalFileItem?
    @State var comparePair: ComparePair?
    @State var previewPort: TerminalListeningPort?
    /// Line to scroll to when opening a file from a content search match.
    @State var openedLine: Int?

    // Layout
    @State private var isTerminalFullscreen = false
    @AppStorage(TerminalPreferences.heightKey) private var dockFraction: Double = 0.45
    @State private var dragStartFraction: Double?
    @FocusState var searchFocused: Bool

    enum CreateKind: String, Identifiable { case folder, file; var id: String { rawValue } }
    struct ComparePair: Identifiable { let original: TerminalFileItem; let revised: TerminalFileItem; var id: String { original.path + revised.path } }

    var body: some View {
        applySheets(mainContent)
    }

    /// iPad: while the shell has the keyboard, the file browser folds away so the
    /// shell gets every point above the keyboard (the panel itself now follows the
    /// keyboard safe area instead of being drawn under it).
    private var shellTakesOver: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && viewModel.shell.isKeyboardFocused
            && viewModel.isTerminalExpanded
            && !viewModel.requiresSavedChat
    }

    private var mainContent: some View {
        GeometryReader { geo in
            let compactShell = isTerminalFullscreen || shellTakesOver
            VStack(spacing: 0) {
                if !compactShell {
                    header
                    if viewModel.requiresSavedChat {
                        savedChatPlaceholder
                    } else {
                        browserBody
                    }
                }
                if (viewModel.isTerminalExpanded || isTerminalFullscreen) && !viewModel.requiresSavedChat {
                    if !compactShell { resizeHandle(totalHeight: geo.size.height) }
                    TerminalDockView(viewModel: viewModel, isFullscreen: isTerminalFullscreen) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { isTerminalFullscreen.toggle() }
                        Haptics.play(.light)
                    }
                    .frame(height: compactShell ? nil : dockHeight(total: geo.size.height))
                    .frame(maxHeight: compactShell ? .infinity : nil)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !compactShell && !viewModel.requiresSavedChat {
                    dockToggleBar
                }
            }
            .overlay(alignment: .top) { bannerView.padding(.top, compactShell ? 44 : 52) }
        }
        .background(background ?? theme.background)
        .onChange(of: viewModel.isTerminalExpanded) { _, expanded in
            if expanded { viewModel.shell.panelDidAppear() } else { isTerminalFullscreen = false }
        }
        .onChange(of: viewModel.pendingOpenFile) { _, file in
            guard let file else { return }
            viewModel.pendingOpenFile = nil
            open(file)
        }
        .onAppear {
            // A display_file event may have arrived before the panel existed.
            if let file = viewModel.pendingOpenFile {
                viewModel.pendingOpenFile = nil
                open(file)
            }
        }
        .onChange(of: viewModel.searchQuery) { _, _ in viewModel.searchQueryChanged() }
        .task { await viewModel.bootstrap() }
    }

    private func dockHeight(total: CGFloat) -> CGFloat {
        let clamped = min(0.8, max(0.22, dockFraction))
        return max(180, total * clamped)
    }

    // MARK: Resize handle

    private func resizeHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(theme.cardBorder.opacity(0.35)).frame(height: 0.5)
            Capsule().fill(theme.textTertiary.opacity(0.5)).frame(width: 36, height: 5)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .background(theme.surfaceContainer.opacity(0.6))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragStartFraction == nil { dragStartFraction = min(0.8, max(0.22, dockFraction)) }
                    let start = dragStartFraction ?? dockFraction
                    dockFraction = min(0.8, max(0.22, start - Double(value.translation.height / max(1, totalHeight))))
                }
                .onEnded { value in
                    dragStartFraction = nil
                    // Snap to comfortable detents; a strong upward fling goes fullscreen.
                    if value.predictedEndTranslation.height < -totalHeight * 0.5 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { isTerminalFullscreen = true }
                    } else {
                        let detents: [Double] = [0.3, 0.45, 0.62, 0.8]
                        let target = detents.min { abs($0 - dockFraction) < abs($1 - dockFraction) } ?? 0.45
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dockFraction = target }
                    }
                    Haptics.selection()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize terminal")
        .accessibilityAdjustableAction { direction in
            dockFraction = min(0.8, max(0.22, dockFraction + (direction == .increment ? 0.1 : -0.1)))
        }
    }

    // MARK: Dock toggle

    private var dockToggleBar: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { viewModel.isTerminalExpanded.toggle() }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal").scaledFont(size: 13, weight: .semibold)
                Text("Terminal").scaledFont(size: 13, weight: .semibold)
                statusDot
                if viewModel.processes.runningCount > 0 {
                    Text("\(viewModel.processes.runningCount) running")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.surfaceContainerHighest, in: Capsule())
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .scaledFont(size: 11, weight: .bold)
                    .rotationEffect(.degrees(viewModel.isTerminalExpanded ? 180 : 0))
            }
            .foregroundStyle(viewModel.isTerminalExpanded ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(theme.surfaceContainer.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isTerminalExpanded ? "Hide Terminal" : "Show Terminal")
    }

    @ViewBuilder
    private var statusDot: some View {
        switch viewModel.shell.state {
        case .connected: Circle().fill(.green).frame(width: 6, height: 6)
        case .connecting, .reconnecting: ProgressView().controlSize(.mini)
        case .failed: Circle().fill(theme.error).frame(width: 6, height: 6)
        default: EmptyView()
        }
    }

    private var savedChatPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "terminal").scaledFont(size: 28).foregroundStyle(theme.textTertiary)
            Text("Start the chat to use this terminal").scaledFont(size: 15, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text("\(viewModel.serverName) gives each chat its own workspace. Send a message and your files will appear here.")
                .scaledFont(size: 13).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
