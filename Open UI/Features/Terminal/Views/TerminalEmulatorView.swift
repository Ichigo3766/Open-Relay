import SwiftUI
import UIKit
import SwiftTerm

/// SwiftTerm view with pinch-to-zoom. Resizing to cols/rows is handled by
/// SwiftTerm itself on layout and reported through `sizeChanged`.
final class TerminalHostView: TerminalView {
    var onPinch: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    /// Reports keyboard focus changes (become/resign first responder).
    var onFocusChange: ((Bool) -> Void)?
    var isReadOnly = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        onPinch?(recognizer.scale, recognizer.state)
        if recognizer.state == .changed { recognizer.scale = 1 }
    }

    override var canBecomeFirstResponder: Bool { isReadOnly ? false : super.canBecomeFirstResponder }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// Bridges one SwiftTerm emulator into SwiftUI.
///
/// - `.shell` — interactive; keystrokes go to the WebSocket, custom key bar.
/// - `.process(id)` — read-only output of a model-run command.
struct TerminalEmulatorView: UIViewRepresentable {
    enum Source: Equatable { case shell, process(String) }

    let source: Source
    let shell: TerminalShellViewModel
    let processes: TerminalProcessesViewModel
    let palette: TerminalThemeOption.Palette
    @Binding var fontSize: Double

    func makeUIView(context: Context) -> TerminalHostView {
        let view = TerminalHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = true
        view.allowMouseReporting = false
        view.applyAppearance(palette, fontSize: fontSize)
        context.coordinator.appliedPalette = palette.background
        context.coordinator.appliedFont = fontSize
        view.onPinch = { [weak coordinator = context.coordinator] scale, state in
            coordinator?.pinch(scale: scale, state: state)
        }
        switch source {
        case .shell:
            let keyBar = TerminalKeyBar(terminalView: view)
            keyBar.onPaste = { [weak shell] in
                if let text = UIPasteboard.general.string { shell?.paste(text) }
            }
            view.inputAccessoryView = keyBar
            shell.terminalView = view
            view.onFocusChange = { [weak shell] focused in
                guard let shell, shell.isKeyboardFocused != focused else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    shell.isKeyboardFocused = focused
                }
            }
        case .process(let id):
            view.isReadOnly = true
            view.inputAccessoryView = nil
            processes.attach(view, to: id)
        }
        return view
    }

    func updateUIView(_ view: TerminalHostView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.appliedPalette != palette.background || context.coordinator.appliedFont != fontSize {
            view.applyAppearance(palette, fontSize: fontSize)
            context.coordinator.appliedPalette = palette.background
            context.coordinator.appliedFont = fontSize
        }
        if case .shell = source, shell.terminalView !== view { shell.terminalView = view }
    }

    static func dismantleUIView(_ view: TerminalHostView, coordinator: Coordinator) {
        view.onFocusChange = nil
        if case .shell = coordinator.parent.source {
            let shell = coordinator.parent.shell
            DispatchQueue.main.async { shell.isKeyboardFocused = false }
        }
        if case .shell = coordinator.parent.source, coordinator.parent.shell.terminalView === view {
            coordinator.parent.shell.terminalView = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: TerminalEmulatorView
        var appliedPalette: UIColor?
        var appliedFont: Double = 0
        private var pinchAccumulator: CGFloat = 1

        init(parent: TerminalEmulatorView) { self.parent = parent }

        func pinch(scale: CGFloat, state: UIGestureRecognizer.State) {
            switch state {
            case .began: pinchAccumulator = 1
            case .changed:
                pinchAccumulator *= scale
                guard abs(pinchAccumulator - 1) > 0.08 else { return }
                let step: Double = pinchAccumulator > 1 ? 1 : -1
                pinchAccumulator = 1
                let next = min(TerminalPreferences.fontRange.upperBound,
                               max(TerminalPreferences.fontRange.lowerBound, parent.fontSize + step))
                if next != parent.fontSize {
                    parent.fontSize = next
                    Haptics.selection()
                }
            default: break
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard case .shell = parent.source else { return }
            parent.shell.handleKeyboard(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard case .shell = parent.source else { return }
            parent.shell.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            guard case .shell = parent.source else { return }
            parent.shell.setTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: TerminalView) { Haptics.notify(.warning) }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
                Haptics.notify(.success)
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string.map { Data($0.utf8) }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
