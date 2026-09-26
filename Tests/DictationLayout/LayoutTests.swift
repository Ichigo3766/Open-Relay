import XCTest
import SwiftUI
@testable import DictationLayoutQA

@MainActor final class LayoutTests: XCTestCase {
    private var window: UIWindow!
    private var state: FixtureState!

    override func setUp() async throws {
        state = FixtureState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: ReproComposer(state: state))
        window.makeKeyAndVisible()
        await settle()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
        state = nil
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
    }

    private func textView(in view: UIView? = nil) -> PasteInterceptingTextView? {
        let view = view ?? window!
        if let result = view as? PasteInterceptingTextView { return result }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func verifyTranscript(_ label: String) async throws {
        let textView = try XCTUnwrap(textView())
        let fitted = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        print("LAYOUT \(label): bounds=\(textView.bounds.size), fit=\(fitted), content=\(textView.contentSize), scroll=\(textView.isScrollEnabled), chars=\(textView.text.count)")
        XCTAssertEqual(textView.text, state.text)
        XCTAssertGreaterThanOrEqual(textView.contentSize.height, fitted - 1,
                                    "All inserted text must be reachable before an edit forces layout")
        XCTAssertEqual(textView.bounds.height, min(fitted, textView.maxContentHeight), accuracy: 1)
        if fitted > textView.bounds.height { XCTAssertTrue(textView.isScrollEnabled) }
        textView.scrollRangeToVisible(NSRange(location: textView.text.utf16.count - 1, length: 1))
        await settle()
        let tail = textView.caretRect(for: textView.endOfDocument)
        print("TAIL \(label): caret=\(tail), bounds=\(textView.bounds)")
        XCTAssertLessThanOrEqual(tail.maxY, textView.bounds.maxY + 1)
        XCTAssertGreaterThanOrEqual(tail.minY, textView.bounds.minY - 1)
    }

    func testLongTranscriptIntoExistingComposer() async throws {
        state.text = FixtureState.transcript
        await settle()
        try await verifyTranscript("existing")
    }

    func testLongTranscriptAfterProcessing() async throws {
        state.processing = true
        await settle()
        state.text = FixtureState.transcript
        state.processing = false
        await settle()
        try await verifyTranscript("recreated")
    }

    func testRecreatedComposerThenDelete() async throws {
        state.processing = true
        await settle()
        state.text = FixtureState.transcript
        state.processing = false
        await settle()
        try await verifyTranscript("before editing")
        let input = try XCTUnwrap(textView())
        input.becomeFirstResponder()
        input.selectedRange = NSRange(location: input.text.utf16.count, length: 0)
        input.deleteBackward()
        await settle()
        XCTAssertEqual(state.text, String(FixtureState.transcript.dropLast()))
        try await verifyTranscript("after deleting")
    }

    func testAppendToExistingDraft() async throws {
        state.text = "A draft before dictation."
        await settle()
        state.processing = true
        await settle()
        state.text += " " + FixtureState.transcript
        state.processing = false
        await settle()
        try await verifyTranscript("appended transcript")
    }

    func testLongTranscriptsAcrossWidths() async throws {
        for width: CGFloat in [230, 360, 600] {
            state.processing = true
            state.width = width
            await settle()
            state.text = String(repeating: FixtureState.transcript, count: 4)
            state.processing = false
            await settle()
            try await verifyTranscript("long transcript at width \(width)")
        }
    }

    func testPlaceholderAfterClearing() async throws {
        state.text = FixtureState.transcript
        await settle()
        state.text = ""
        await settle()
        let input = try XCTUnwrap(textView())
        XCTAssertFalse(input.placeholderLabel.isHidden)
        XCTAssertEqual(input.placeholderLabel.frame.width, input.bounds.width, accuracy: 1)
        XCTAssertFalse(input.isScrollEnabled)
        XCTAssertLessThanOrEqual(input.bounds.height, (input.font?.lineHeight ?? 20) + 1)
    }
}
