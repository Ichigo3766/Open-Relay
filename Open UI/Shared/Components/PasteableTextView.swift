import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Pasteable Text View

/// A UITextView wrapper that intercepts paste operations to detect images and files
/// on the clipboard, converting them into `ChatAttachment` objects.
///
/// Standard SwiftUI `TextField` / `TextEditor` don't expose paste events,
/// so we drop to UIKit to override `paste(_:)` on a custom UITextView subclass.
struct PasteableTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: UIFont
    var placeholderFont: UIFont?
    var textColor: UIColor
    var placeholderColor: UIColor
    var tintColor: UIColor
    var isEnabled: Bool
    var onPasteAttachments: (([ChatAttachment]) -> Void)?
    var onSubmit: (() -> Void)?

    /// Called when the user types `#` at a word boundary. The parameter is
    /// the filter query text after the `#` (may be empty on initial trigger).
    var onHashTrigger: ((String) -> Void)?

    /// Called when the `#` context is dismissed (e.g., cursor moved away,
    /// backspace deleted the `#`, or whitespace ended the token).
    var onHashDismiss: (() -> Void)?

    /// Called when the user types `@` at a word boundary. The parameter is
    /// the filter query text after the `@` (may be empty on initial trigger).
    var onAtTrigger: ((String) -> Void)?

    /// Called when the `@` context is dismissed (e.g., cursor moved away,
    /// backspace deleted the `@`, or whitespace ended the token).
    var onAtDismiss: (() -> Void)?

    /// Called when the user types `/` at a word boundary. The parameter is
    /// the filter query text after the `/` (may be empty on initial trigger).
    var onSlashTrigger: ((String) -> Void)?

    /// Called when the `/` context is dismissed (e.g., cursor moved away,
    /// backspace deleted the `/`, or whitespace ended the token).
    var onSlashDismiss: (() -> Void)?

    /// Called when the user types `$` at a word boundary. The parameter is
    /// the filter query text after the `$` (may be empty on initial trigger).
    var onDollarTrigger: ((String) -> Void)?

    /// Called when the `$` context is dismissed (e.g., cursor moved away,
    /// backspace deleted the `$`, or whitespace ended the token).
    var onDollarDismiss: (() -> Void)?

    /// Whether pressing Return sends the message (vs inserting a newline).
    var sendOnReturn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PasteInterceptingTextView {
        let textView = PasteInterceptingTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        textView.clipsToBounds = true
        // Start with scrolling OFF so the view sizes to its content.
        // We toggle it on in updateUIView when content exceeds max height.
        textView.isScrollEnabled = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)

        // Wire the paste callback
        textView.onPasteAttachments = { [weak textView] attachments in
            guard let textView else { return }
            // Dispatch to main to stay in sync with SwiftUI
            DispatchQueue.main.async {
                context.coordinator.parent.onPasteAttachments?(attachments)
                // Trigger a text update in case paste also included text
                context.coordinator.parent.text = textView.text
            }
        }

        textView.onReturnKey = {
            context.coordinator.parent.onSubmit?()
        }
        textView.sendOnReturn = sendOnReturn
        textView.returnKeyType = sendOnReturn ? .send : .default

        // Placeholder
        textView.placeholderLabel.text = placeholder
        textView.placeholderLabel.font = placeholderFont ?? font
        textView.placeholderLabel.textColor = placeholderColor
        textView.placeholderLabel.isHidden = !text.isEmpty

        return textView
    }

    func updateUIView(_ textView: PasteInterceptingTextView, context: Context) {
        // Sync coordinator parent so onSubmit / onPasteAttachments always capture
        // the latest struct values (fixes stale-closure "Send on Enter" bug).
        context.coordinator.parent = self

        // SwiftUI calls this on every composer re-render (including mid-scroll, e.g.
        // from the press-feedback or expand gestures). Re-assigning font/colors makes
        // UITextView re-layout its text and scroll the caret back into view, which
        // yanks the user to the bottom while they scroll. So only write what changed,
        // and never disturb the scroll position when the text itself is unchanged.
        let userIsScrolling = textView.isTracking || textView.isDragging || textView.isDecelerating
        let savedOffset = textView.contentOffset
        var textChanged = false

        // Only update text if it actually changed (avoids cursor jump)
        if textView.text != text {
            textView.text = text
            textChanged = true
        }
        if textView.isEditable != isEnabled { textView.isEditable = isEnabled }
        if !textView.isSelectable { textView.isSelectable = true }
        if textView.font != font { textView.font = font }
        if !Self.sameColor(textView.textColor, textColor, in: textView) { textView.textColor = textColor }
        if !Self.sameColor(textView.tintColor, tintColor, in: textView) { textView.tintColor = tintColor }

        let placeholderLabel = textView.placeholderLabel
        if placeholderLabel.isHidden != !text.isEmpty { placeholderLabel.isHidden = !text.isEmpty }
        if placeholderLabel.text != placeholder { placeholderLabel.text = placeholder }
        let resolvedPlaceholderFont = placeholderFont ?? font
        if placeholderLabel.font != resolvedPlaceholderFont { placeholderLabel.font = resolvedPlaceholderFont }
        if !Self.sameColor(placeholderLabel.textColor, placeholderColor, in: textView) {
            placeholderLabel.textColor = placeholderColor
        }
        let newReturnKeyType: UIReturnKeyType = sendOnReturn ? .send : .default
        if textView.returnKeyType != newReturnKeyType {
            textView.returnKeyType = newReturnKeyType
            textView.reloadInputViews()
        }
        textView.sendOnReturn = sendOnReturn

        // Re-assign closures so they always capture the latest parent state.
        // Without this, stale closures from makeUIView are called when
        // onPasteAttachments or onSubmit capture different state.
        textView.onPasteAttachments = { [weak textView] attachments in
            guard let textView else { return }
            DispatchQueue.main.async {
                context.coordinator.parent.onPasteAttachments?(attachments)
                context.coordinator.parent.text = textView.text
            }
        }
        textView.onReturnKey = {
            context.coordinator.parent.onSubmit?()
        }

        // Recalculate sizing: toggle scroll when content exceeds max height.
        // Skipped while the user is scrolling an unchanged draft so the view stays put.
        if textChanged || !userIsScrolling {
            PasteableTextView.recalculateHeight(textView)
        }

        // Keep the user's reading position when nothing about the text changed.
        if !textChanged, textView.isScrollEnabled, textView.contentOffset != savedOffset {
            textView.setContentOffset(savedOffset, animated: false)
        }
    }

    /// Compares colors by their resolved values — `UIColor(Color)` creates a new
    /// instance each render, so identity/`isEqual` alone would always differ.
    private static func sameColor(_ current: UIColor?, _ new: UIColor, in view: UIView) -> Bool {
        guard let current else { return false }
        if current.isEqual(new) { return true }
        let traits = view.traitCollection
        return current.resolvedColor(with: traits).cgColor == new.resolvedColor(with: traits).cgColor
    }

    /// Recalculates the text view height and toggles scrolling appropriately.
    /// When content fits, scrolling is OFF so intrinsicContentSize drives layout.
    /// When content overflows, scrolling is ON so the user can scroll within the fixed frame.
    static func recalculateHeight(_ textView: PasteInterceptingTextView) {
        let maxHeight = textView.maxContentHeight
        let fittingSize = textView.sizeThatFits(CGSize(
            width: textView.frame.width > 0 ? textView.frame.width : UIScreen.main.bounds.width - 100,
            height: .greatestFiniteMagnitude
        ))
        let shouldScroll = fittingSize.height > maxHeight
        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
        }
        // Only invalidate when the reported height actually changes — a redundant
        // invalidation re-lays out the view and can reset its scroll position.
        let height = min(fittingSize.height, maxHeight)
        if textView.lastReportedHeight != height {
            textView.lastReportedHeight = height
            textView.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteableTextView

        init(parent: PasteableTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if let ptv = textView as? PasteInterceptingTextView {
                ptv.placeholderLabel.isHidden = !textView.text.isEmpty
                // Recalculate height as user types so the view grows/shrinks
                PasteableTextView.recalculateHeight(ptv)
            }

            detectTriggers(in: textView)
        }

        private func detectTriggers(in textView: UITextView) {
            guard parent.onHashTrigger != nil || parent.onAtTrigger != nil
                || parent.onSlashTrigger != nil || parent.onDollarTrigger != nil else { return }
            let token = textView.selectedTextRange.flatMap { selection in
                ComposerToken(text: textView.text ?? "", utf16Offset:
                    textView.offset(from: textView.beginningOfDocument, to: selection.start))
            }
            notifyTrigger("#", token, parent.onHashTrigger, parent.onHashDismiss)
            notifyTrigger("@", token, parent.onAtTrigger, parent.onAtDismiss)
            notifyTrigger("/", token, parent.onSlashTrigger, parent.onSlashDismiss)
            notifyTrigger("$", token, parent.onDollarTrigger, parent.onDollarDismiss)
        }

        private func notifyTrigger(_ symbol: Character, _ token: ComposerToken?,
                                   _ trigger: ((String) -> Void)?, _ dismiss: (() -> Void)?) {
            guard let trigger else { return }
            if let token, token.symbol == symbol { trigger(token.query) }
            else { dismiss?() }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if let ptv = textView as? PasteInterceptingTextView {
                ptv.placeholderLabel.isHidden = !textView.text.isEmpty
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if let ptv = textView as? PasteInterceptingTextView {
                ptv.placeholderLabel.isHidden = !textView.text.isEmpty
            }
        }
    }
}

// MARK: - Paste-Intercepting UITextView

/// Custom UITextView subclass that overrides `paste(_:)` to detect images
/// and files on the system pasteboard before falling through to normal text paste.
final class PasteInterceptingTextView: UITextView {

    /// Called when pasted content contains images or files.
    var onPasteAttachments: (([ChatAttachment]) -> Void)?

    /// Called when the user presses Return and `sendOnReturn` is true.
    var onReturnKey: (() -> Void)?

    /// Whether Return key sends the message instead of inserting a newline.
    var sendOnReturn: Bool = true

    /// Observer for the widget "focus input" notification so we can call
    /// `becomeFirstResponder()` directly on the UIKit text view.
    /// SwiftUI's `@FocusState` does NOT drive focus for UIViewRepresentable
    /// views, so this is the only reliable way to show the keyboard
    /// programmatically (e.g. after opening the app from a widget deep link).
    private var focusObserver: NSObjectProtocol?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupFocusObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFocusObserver()
    }

    private func setupFocusObserver() {
        focusObserver = NotificationCenter.default.addObserver(
            forName: .chatInputFieldRequestFocus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.becomeFirstResponder()
        }
    }

    deinit {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
        }
    }

    /// Placeholder label shown when the text view is empty.
    lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        // Anchor to the viewport so the placeholder cannot redefine contentSize.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            label.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor),
            label.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
        ])
        return label
    }()

    /// Last height reported via `intrinsicContentSize`, used to skip redundant invalidations.
    var lastReportedHeight: CGFloat = -1

    /// Maximum content height (~8 lines).
    var maxContentHeight: CGFloat {
        (font?.lineHeight ?? 20) * 8 + textContainerInset.top + textContainerInset.bottom
    }

    /// Returns intrinsic size capped at maxContentHeight.
    /// When isScrollEnabled is false, UITextView reports its full content height
    /// as intrinsic — we cap it so the view never grows past 8 lines.
    override var intrinsicContentSize: CGSize {
        let fittingSize = sizeThatFits(CGSize(
            width: frame.width > 0 ? frame.width : UIScreen.main.bounds.width - 100,
            height: .greatestFiniteMagnitude
        ))
        let height = min(fittingSize.height, maxContentHeight)
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    // MARK: - Paste Override

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        var pastedAttachments: [ChatAttachment] = []

        // 1. Check for images (PNG, JPEG, TIFF, GIF, HEIC, WebP)
        if let images = pb.images, !images.isEmpty {
            for (index, image) in images.enumerated() {
                let data = resizedJPEGData(for: image)
                let attachment = ChatAttachment(
                    type: .image,
                    name: "Pasted_Image_\(Int(Date.now.timeIntervalSince1970))_\(index).jpg",
                    thumbnail: Image(uiImage: image),
                    data: data
                )
                pastedAttachments.append(attachment)
            }
        } else if pb.hasImages, let image = pb.image {
            // Single image fallback
            let data = resizedJPEGData(for: image)
            let attachment = ChatAttachment(
                type: .image,
                name: "Pasted_Image_\(Int(Date.now.timeIntervalSince1970)).jpg",
                thumbnail: Image(uiImage: image),
                data: data
            )
            pastedAttachments.append(attachment)
        }

        // 2. Check for file URLs (e.g., files copied from Files.app)
        if let urls = pb.urls {
            for url in urls where url.isFileURL {
                if let data = try? Data(contentsOf: url) {
                    let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
                    if isImage {
                        // Only add as image if we didn't already get it from pb.images
                        if pastedAttachments.isEmpty {
                            let thumbnail: Image? = UIImage(data: data).map { Image(uiImage: $0) }
                            let attachment = ChatAttachment(
                                type: .image,
                                name: url.lastPathComponent,
                                thumbnail: thumbnail,
                                data: data
                            )
                            pastedAttachments.append(attachment)
                        }
                    } else {
                        let attachment = ChatAttachment(
                            type: .file,
                            name: url.lastPathComponent,
                            thumbnail: nil,
                            data: data
                        )
                        pastedAttachments.append(attachment)
                    }
                }
            }
        }

        // 3. Check for raw image data in specific UTTypes (PNG/JPEG data without UIImage)
        if pastedAttachments.isEmpty {
            for typeId in [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier, UTType.tiff.identifier] {
                if let data = pb.data(forPasteboardType: typeId), let uiImage = UIImage(data: data) {
                    let attachment = ChatAttachment(
                        type: .image,
                        name: "Pasted_Image_\(Int(Date.now.timeIntervalSince1970)).jpg",
                        thumbnail: Image(uiImage: uiImage),
                        data: resizedJPEGData(for: uiImage)
                    )
                    pastedAttachments.append(attachment)
                    break // Only need one
                }
            }
        }

        // Deliver attachments if we found any
        if !pastedAttachments.isEmpty {
            onPasteAttachments?(pastedAttachments)

            // If the pasteboard ALSO has text, paste it normally
            if pb.hasStrings {
                super.paste(sender)
            }
            return
        }

        // No attachments detected — fall through to normal text paste
        super.paste(sender)
    }

    // MARK: - Shift Key Tracking

    private var isShiftHeld = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = true
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = false
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = false
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - Return Key Handling

    override func insertText(_ text: String) {
        if text == "\n" && sendOnReturn {
            if isShiftHeld {
                super.insertText(text)
            } else {
                onReturnKey?()
            }
            return
        }
        super.insertText(text)
    }

    // MARK: - Can Paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // Always allow paste — we handle images, files, AND text
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: - Helpers

    /// Downsamples an image to ≤ 2 MP and encodes as JPEG.
    /// Delegates to `FileAttachmentService.downsampleForUpload` which
    /// guarantees the output stays under the API's 5 MB image limit.
    private func resizedJPEGData(for image: UIImage) -> Data? {
        let data = FileAttachmentService.downsampleForUpload(image: image)
        return data.isEmpty ? nil : data
    }
}
