import UIKit
import SwiftTerm

/// Keyboard accessory row for the terminal: modifiers, arrows and the
/// symbols that are awkward to reach on the iOS keyboard.
///
/// Keys are plain views (not `UIControl`s). One tap recognizer and one
/// long-press recognizer on the scroll view decide which key was hit, so a
/// horizontal swipe always scrolls the bar instead of pressing a key.
///
/// - `ctrl` / `alt` are sticky for the next key (tap again to cancel) and
///   drive SwiftTerm's own modifier state so typed letters are translated.
/// - Arrow keys honour application-cursor mode (vim, less, tmux…) and repeat
///   while held.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback, UIGestureRecognizerDelegate {

    weak var terminalView: TerminalView?
    var onPaste: (() -> Void)?

    private let scrollView = KeyBarScrollView()
    private let stack = UIStackView()
    private var keyViews: [KeyCapView] = []
    private var ctrlKey: KeyCapView?
    private var altKey: KeyCapView?
    private var repeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    var enableInputClicksWhenVisible: Bool { true }

    private enum Key {
        case text(String, send: String)
        case symbol(String, accessibility: String, send: KeyAction)
        case ctrl, alt
    }

    enum KeyAction { case bytes([UInt8]), arrowUp, arrowDown, arrowLeft, arrowRight, paste, dismiss, ctrl, alt }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Metrics.current.barHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModifierKeys() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewMetaModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModifierKeys() }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.current.barHeight)
    }

    /// Sizes for the bar and its keys. iPad gets larger keys and labels.
    struct Metrics {
        let barHeight: CGFloat
        let keyHeight: CGFloat
        let minKeyWidth: CGFloat
        let keyCornerRadius: CGFloat
        let labelSize: CGFloat
        let symbolSize: CGFloat
        let keyPadding: CGFloat
        let wordKeyPadding: CGFloat
        let keySpacing: CGFloat

        @MainActor static var current: Metrics {
            UIDevice.current.userInterfaceIdiom == .pad
                ? Metrics(barHeight: 56, keyHeight: 40, minKeyWidth: 46, keyCornerRadius: 9,
                          labelSize: 16, symbolSize: 16, keyPadding: 14, wordKeyPadding: 12, keySpacing: 8)
                : Metrics(barHeight: 46, keyHeight: 34, minKeyWidth: 38, keyCornerRadius: 8,
                          labelSize: 15, symbolSize: 14, keyPadding: 12, wordKeyPadding: 10, keySpacing: 6)
        }
    }

    /// Solid backdrop so the keys stay legible even when the bar floats over the
    /// terminal/chat (iPad, iOS 26 floating accessory bar, hardware keyboard).
    private func makeBackdrop() -> UIVisualEffectView {
        // Subviews of a UIVisualEffectView must go into its `contentView`;
        // adding them to the effect view itself throws an assertion (crash).
        let backdrop: UIVisualEffectView
        if #available(iOS 26.0, *) {
            backdrop = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        let content = backdrop.contentView

        // A tint layer keeps the bar opaque enough for contrast on any content.
        let tint = UIView()
        tint.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.12, alpha: 0.72)
                : UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 0.78)
        }
        tint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tint)

        // Hairline separating the bar from the terminal above.
        let hairline = UIView()
        hairline.backgroundColor = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hairline)

        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tint.topAnchor.constraint(equalTo: content.topAnchor),
            tint.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: content.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
        return backdrop
    }

    private var keys: [Key] {
        [
            .text("esc", send: "\u{1B}"),
            .text("tab", send: "\t"),
            .ctrl, .alt,
            .symbol("arrow.left", accessibility: "Left", send: .arrowLeft),
            .symbol("arrow.up", accessibility: "Up", send: .arrowUp),
            .symbol("arrow.down", accessibility: "Down", send: .arrowDown),
            .symbol("arrow.right", accessibility: "Right", send: .arrowRight),
            .text("^C", send: "\u{03}"),
            .text("|", send: "|"), .text("~", send: "~"), .text("/", send: "/"), .text("-", send: "-"),
            .text("_", send: "_"), .text("*", send: "*"), .text("&", send: "&"), .text("$", send: "$"),
            .text("\"", send: "\""), .text("'", send: "'"), .text("`", send: "`"),
            .text("<", send: "<"), .text(">", send: ">"), .text("[", send: "["), .text("]", send: "]"),
            .text("{", send: "{"), .text("}", send: "}"), .text("\\", send: "\\"), .text("=", send: "="),
            .text("^D", send: "\u{04}"), .text("^Z", send: "\u{1A}"), .text("^L", send: "\u{0C}"), .text("^R", send: "\u{12}"),
            .text("home", send: "\u{1B}[H"), .text("end", send: "\u{1B}[F"),
            .text("pgup", send: "\u{1B}[5~"), .text("pgdn", send: "\u{1B}[6~"),
            .symbol("doc.on.clipboard", accessibility: "Paste", send: .paste)
        ]
    }

    private func build() {
        backgroundColor = .clear
        let backdrop = makeBackdrop()
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.onBeginScroll = { [weak self] in self?.cancelPress() }
        // The edge fade lives on a stationary container, so it never lags the scroll.
        let fadeContainer = KeyBarFadeContainer()
        fadeContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.onEdgesChanged = { [weak fadeContainer] canLeft, canRight in
            fadeContainer?.setEdges(canLeft: canLeft, canRight: canRight)
        }
        addSubview(fadeContainer)
        fadeContainer.addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = Metrics.current.keySpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false // touches are resolved by the recognizers below
        scrollView.addSubview(stack)

        let dismiss = UIButton(configuration: Self.dismissConfiguration())
        dismiss.accessibilityLabel = "Hide Keyboard"
        dismiss.addAction(UIAction { [weak self] _ in self?.perform(.dismiss) }, for: .touchUpInside)
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dismiss)

        let divider = UIView()
        divider.backgroundColor = UIColor.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            fadeContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            fadeContainer.topAnchor.constraint(equalTo: topAnchor),
            fadeContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            fadeContainer.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: fadeContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: fadeContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: fadeContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: fadeContainer.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            divider.heightAnchor.constraint(equalToConstant: 22),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),
            dismiss.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.heightAnchor.constraint(equalToConstant: Metrics.current.keyHeight),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        for key in keys {
            let view: KeyCapView
            switch key {
            case .text(let title, let send):
                view = KeyCapView(title: title, symbol: nil, action: .bytes(Array(send.utf8)))
                view.accessibilityLabel = accessibilityName(title)
            case .symbol(let symbol, let label, let action):
                view = KeyCapView(title: nil, symbol: symbol, action: action)
                view.accessibilityLabel = label
                switch action {
                case .arrowUp, .arrowDown, .arrowLeft, .arrowRight: view.repeats = true
                default: break
                }
            case .ctrl:
                view = KeyCapView(title: "ctrl", symbol: nil, action: .ctrl)
                view.accessibilityLabel = "Control"
                ctrlKey = view
            case .alt:
                view = KeyCapView(title: "alt", symbol: nil, action: .alt)
                view.accessibilityLabel = "Option"
                altKey = view
            }
            view.onAccessibilityActivate = { [weak self] action in self?.fire(action) }
            keyViews.append(view)
            stack.addArrangedSubview(view)
        }

        // Touch-down highlight + tap + hold-to-repeat, all yielding to scrolling.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 10
        press.cancelsTouchesInView = false
        press.delegate = self
        scrollView.addGestureRecognizer(press)
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
    }

    // MARK: Touch handling

    private var pressedKey: KeyCapView?
    private var didRepeat = false
    private var holdTimer: Timer?
    private var highlightTimer: Timer?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func key(at recognizer: UIGestureRecognizer) -> KeyCapView? {
        let point = recognizer.location(in: stack)
        // Generous hit area: nearest key horizontally within its slot.
        return keyViews.first { $0.frame.insetBy(dx: -3, dy: -8).contains(point) }
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard let key = key(at: recognizer) else { return }
            pressedKey = key
            didRepeat = false
            // Delay the visual highlight slightly: a swipe cancels before it shows,
            // so scrolling never makes keys twitch. Taps still flash on release.
            highlightTimer?.invalidate()
            let highlight = Timer(timeInterval: 0.06, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pressedKey === key else { return }
                    key.setPressed(true, animated: true)
                }
            }
            RunLoop.main.add(highlight, forMode: .common)
            highlightTimer = highlight
            if key.repeats {
                holdTimer?.invalidate()
                let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startRepeating() }
                }
                RunLoop.main.add(timer, forMode: .common)
                holdTimer = timer
            }
        case .ended:
            guard let key = pressedKey else { return }
            let repeated = didRepeat
            let wasHighlighted = key.isPressed
            cancelPress()
            if !repeated {
                fire(key.action)
                // Quick tap that ended before the highlight appeared: flash it briefly.
                if !wasHighlighted { key.flash() }
            }
        case .cancelled, .failed:
            cancelPress()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed { cancelPress() }
    }

    private func startRepeating() {
        guard let key = pressedKey else { return }
        didRepeat = true
        key.setPressed(true, animated: true)
        fire(key.action)
        endRepeat()
        let timer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = self.pressedKey else { return }
                self.perform(key.action, click: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func cancelPress() {
        holdTimer?.invalidate(); holdTimer = nil
        highlightTimer?.invalidate(); highlightTimer = nil
        endRepeat()
        pressedKey?.setPressed(false, animated: true)
        pressedKey = nil
    }

    private func fire(_ action: KeyAction) {
        switch action {
        case .ctrl: toggleCtrl()
        case .alt: toggleAlt()
        default: perform(action)
        }
    }

    private static func dismissConfiguration() -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
        }
        config.baseForegroundColor = UIColor.label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.image = UIImage(systemName: "keyboard.chevron.compact.down",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.current.symbolSize, weight: .semibold))
        return config
    }

    private func accessibilityName(_ title: String) -> String {
        switch title {
        case "esc": "Escape"
        case "tab": "Tab"
        case "^C": "Control C"
        case "^D": "Control D"
        case "^Z": "Control Z"
        case "^L": "Control L"
        case "^R": "Control R"
        case "pgup": "Page Up"
        case "pgdn": "Page Down"
        default: title
        }
    }

    // MARK: Actions

    private func toggleCtrl() {
        guard let terminalView else { return }
        terminalView.controlModifier.toggle()
        UIDevice.current.playInputClick()
        updateModifierKeys()
    }

    private func toggleAlt() {
        guard let terminalView else { return }
        terminalView.metaModifier.toggle()
        UIDevice.current.playInputClick()
        updateModifierKeys()
    }

    private func updateModifierKeys() {
        ctrlKey?.isLatched = terminalView?.controlModifier == true
        altKey?.isLatched = terminalView?.metaModifier == true
    }

    private func endRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    func perform(_ action: KeyAction, click: Bool = true) {
        guard let terminalView else { return }
        if click { UIDevice.current.playInputClick() }
        let app = terminalView.getTerminal().applicationCursor
        switch action {
        case .bytes(let bytes):
            var bytes = bytes
            // Apply a pending ctrl to single printable characters (e.g. ctrl + "[").
            if terminalView.controlModifier, bytes.count == 1, let c = bytes.first, c >= 0x40, c < 0x7F {
                bytes = [c & 0x1F]
                terminalView.controlModifier = false
            }
            if terminalView.metaModifier {
                bytes.insert(0x1B, at: 0)
                terminalView.metaModifier = false
            }
            terminalView.send(data: bytes[...])
        case .arrowUp: terminalView.send(data: (app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)[...])
        case .arrowDown: terminalView.send(data: (app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)[...])
        case .arrowLeft: terminalView.send(data: (app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)[...])
        case .arrowRight: terminalView.send(data: (app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)[...])
        case .paste: onPaste?()
        case .ctrl: toggleCtrl(); return
        case .alt: toggleAlt(); return
        case .dismiss:
            endRepeat()
            _ = terminalView.resignFirstResponder()
        }
        updateModifierKeys()
    }
}

/// A single key on the bar. Purely visual — touches are handled by the bar.
/// Styled like a system keyboard key: solid cap, hairline bottom shadow,
/// high-contrast label, brand tint when a modifier is latched.
final class KeyCapView: UIView {
    let action: TerminalKeyBar.KeyAction
    var repeats = false
    var onAccessibilityActivate: ((TerminalKeyBar.KeyAction) -> Void)?
    private let label = UILabel()
    private let imageView = UIImageView()

    private(set) var isPressed = false
    var isLatched = false { didSet { if isLatched != oldValue { updateAppearance() } } }

    /// Animates the press state on/off (no snapping while scrolling or tapping).
    func setPressed(_ pressed: Bool, animated: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        guard animated else { updateAppearance(); return }
        UIView.animate(withDuration: pressed ? 0.08 : 0.16, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.updateAppearance()
        }
    }

    /// Brief highlight for a quick tap that released before the delayed highlight.
    func flash() {
        setPressed(true, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.setPressed(false, animated: true)
        }
    }

    init(title: String?, symbol: String?, action: TerminalKeyBar.KeyAction) {
        self.action = action
        super.init(frame: .zero)
        let metrics = TerminalKeyBar.Metrics.current
        layer.cornerRadius = metrics.keyCornerRadius
        layer.cornerCurve = .continuous
        // Key-cap depth: a crisp 1pt shadow below each key (like the system keyboard).
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 0.3
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        translatesAutoresizingMaskIntoConstraints = false

        let content: UIView
        if let title {
            label.text = title
            label.font = UIFont.monospacedSystemFont(ofSize: metrics.labelSize, weight: .semibold)
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = false
            content = label
        } else {
            imageView.image = UIImage(systemName: symbol ?? "questionmark",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: metrics.symbolSize, weight: .semibold))
            imageView.contentMode = .center
            content = imageView
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyCapView, _) in
            self.updateAppearance()
        }
        let padding: CGFloat = (title?.count ?? 0) > 2 ? metrics.wordKeyPadding : metrics.keyPadding
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: metrics.keyHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: metrics.minKeyWidth),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: title == nil ? metrics.keyPadding : padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(title == nil ? metrics.keyPadding : padding)),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateAppearance()
    }

    private var shadowPathSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // Explicit shadow path (no offscreen shadow pass); rebuilt only on real size changes.
        guard bounds.size != shadowPathSize else { return }
        shadowPathSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        CATransaction.commit()
    }

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate?(action)
        return true
    }

    /// Solid key cap colours matching the system keyboard (white / graphite).
    private static let capColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1)
            : UIColor.white
    }
    private static let pressedCapColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.30, alpha: 1)
            : UIColor(white: 0.80, alpha: 1)
    }

    private func updateAppearance() {
        let background: UIColor = isLatched ? tintColor : (isPressed ? Self.pressedCapColor : Self.capColor)
        let foreground: UIColor = isLatched ? .white : .label
        backgroundColor = background
        label.textColor = foreground
        imageView.tintColor = foreground
        let isDark = traitCollection.userInterfaceStyle == .dark
        layer.shadowOpacity = isPressed ? 0 : (isDark ? 0.45 : 0.28)
        transform = isPressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
        accessibilityTraits = isLatched ? [.keyboardKey, .selected] : .keyboardKey
    }
}

/// Horizontal scroller for the key bar. `UIScrollView` refuses to cancel
/// touches on `UIControl`s by default, so once the bar is full of buttons a
/// swipe that starts on a key never scrolls. Allowing cancellation for
/// controls makes every drag scroll while taps stay instant.
final class KeyBarScrollView: UIScrollView, UIScrollViewDelegate {
    var onBeginScroll: (() -> Void)?
    /// Reports whether there are more keys off-screen to the left / right.
    var onEdgesChanged: ((_ canLeft: Bool, _ canRight: Bool) -> Void)?
    private var lastEdges: (Bool, Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only bounce when there's actually something to scroll to.
        let scrollable = contentSize.width > bounds.width + 1
        if alwaysBounceHorizontal != scrollable { alwaysBounceHorizontal = scrollable }
        reportEdges()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportEdges()
    }

    /// Notifies only when an edge's state flips — never per scroll frame.
    private func reportEdges() {
        let canLeft = contentOffset.x > 1
        let canRight = contentOffset.x + bounds.width < contentSize.width - 1
        if let lastEdges, lastEdges == (canLeft, canRight) { return }
        lastEdges = (canLeft, canRight)
        onEdgesChanged?(canLeft, canRight)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onBeginScroll?()
    }
}

/// Stationary container that owns the edge-fade mask for the key scroller.
///
/// The mask used to live on the scroll view itself and was re-framed on every
/// scroll frame. CALayer properties animate implicitly (~0.25s), so the mask
/// trailed behind the content and hid keys mid-swipe. Here the mask is attached
/// to a view that never moves, is only re-framed on real size changes, and all
/// updates run with implicit animations disabled.
final class KeyBarFadeContainer: UIView {
    private let fade = CAGradientLayer()
    private var canLeft = false
    private var canRight = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
        applyFade()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard fade.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.locations = Self.locations(for: bounds.width)
        CATransaction.commit()
    }

    func setEdges(canLeft: Bool, canRight: Bool) {
        guard canLeft != self.canLeft || canRight != self.canRight else { return }
        self.canLeft = canLeft
        self.canRight = canRight
        applyFade()
    }

    private func applyFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.colors = [UIColor.black.withAlphaComponent(canLeft ? 0 : 1).cgColor, UIColor.black.cgColor,
                       UIColor.black.cgColor, UIColor.black.withAlphaComponent(canRight ? 0 : 1).cgColor]
        fade.locations = Self.locations(for: bounds.width)
        CATransaction.commit()
    }

    private static func locations(for width: CGFloat) -> [NSNumber] {
        let edge = min(0.08, 16 / max(width, 1))
        return [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
    }
}
