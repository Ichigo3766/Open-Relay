import XCTest
import SwiftUI
@testable import DictationCaretQA

@MainActor final class CaretTests: XCTestCase {
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
        try? await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
    }

    private func input(in view: UIView? = nil) -> PasteInterceptingTextView? {
        let view = view ?? window!
        if let input = view as? PasteInterceptingTextView { return input }
        return view.subviews.lazy.compactMap { self.input(in: $0) }.first
    }

    private func deliver(_ transcript: String) async throws -> PasteInterceptingTextView {
        state.processing = true
        await settle()
        XCTAssertNil(input(), "Dictation removes the editor before delivering text")
        state.text = state.text.isEmpty ? transcript : state.text + " " + transcript
        state.processing = false
        await settle()
        return try XCTUnwrap(input())
    }

    private func assertAtEnd(_ editor: PasteInterceptingTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(editor.text, state.text, file: file, line: line)
        XCTAssertEqual(editor.selectedRange, NSRange(location: state.text.utf16.count, length: 0), file: file, line: line)
        let caret = editor.caretRect(for: editor.endOfDocument)
        print("Caret: selection=\(editor.selectedRange), end=\(state.text.utf16.count), caret=\(caret), viewport=\(editor.bounds)")
        print("Geometry: content=\(editor.contentSize), inset=\(editor.adjustedContentInset), trailing=\(editor.text.suffix(50).debugDescription)")
        XCTAssertGreaterThanOrEqual(caret.minY, editor.bounds.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(caret.maxY, editor.bounds.maxY + 1.01, file: file, line: line)
    }

    func testShortDictationCursorAtEnd() async throws {
        let editor = try await deliver("A short synthetic transcript.")
        assertAtEnd(editor)
    }

    func testLongDictationCursorAndTailVisibleWithoutTapOrScroll() async throws {
        let editor = try await deliver(FixtureState.transcript)
        assertAtEnd(editor)
        XCTAssertFalse(editor.isFirstResponder, "Dictation must not force the keyboard open")
        editor.becomeFirstResponder()
        editor.insertText(" More.")
        await settle()
        XCTAssertTrue(state.text.hasSuffix("🌟 More."), "Continued typing must append after the transcript")
    }

    func testAppendAfterExistingUnicodeDraft() async throws {
        state.text = "Draft 🧑🏽‍🚀 café."
        await settle()
        let editor = try await deliver(FixtureState.transcript)
        assertAtEnd(editor)
        XCTAssertTrue(state.text.hasPrefix("Draft 🧑🏽‍🚀 café. Step 1:"))
    }

    func testLongDictationAcrossWidths() async throws {
        for width: CGFloat in [230, 360, 600] {
            state.text = ""
            state.width = width
            let editor = try await deliver(FixtureState.transcript)
            assertAtEnd(editor)
        }
    }

    func testProgrammaticUpdateToMountedComposer() async throws {
        let editor = try XCTUnwrap(input())
        state.text = FixtureState.transcript
        await settle()
        XCTAssertTrue(input() === editor)
        assertAtEnd(editor)
        state.text += " Another ending."
        await settle()
        assertAtEnd(editor)
    }

    func testMultilineTranscriptWithTrailingNewline() async throws {
        let editor = try await deliver(String(repeating: "A paper star.\n", count: 40))
        assertAtEnd(editor)
    }

    func testUnchangedDraftKeepsSelectionAndScroll() async throws {
        let editor = try await deliver(FixtureState.transcript)
        editor.selectedRange = NSRange(location: 10, length: 5)
        editor.setContentOffset(.zero, animated: false)
        let offset = editor.contentOffset
        state.alternateTint.toggle()
        await settle()
        XCTAssertEqual(editor.selectedRange, NSRange(location: 10, length: 5))
        XCTAssertEqual(editor.contentOffset.y, offset.y, accuracy: 1)
    }

    func testNormalTypingInMiddleDoesNotJumpToEnd() async throws {
        let editor = try await deliver("First last.")
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: 6, length: 0)
        editor.insertText("middle ")
        await settle()
        XCTAssertEqual(state.text, "First middle last.")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 13, length: 0))
    }

    func testEmptyComposerHasZeroSelectionAndPlaceholder() async throws {
        let editor = try XCTUnwrap(input())
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertFalse(editor.placeholderLabel.isHidden)
    }

    func testNoBlankSpaceBelowLongTranscript() async throws {
        let editor = try await deliver(FixtureState.transcript)
        assertAtEnd(editor)
        let caret = editor.caretRect(for: editor.endOfDocument)
        XCTAssertLessThanOrEqual(editor.contentSize.height - caret.maxY, editor.font!.lineHeight)
        XCTAssertLessThanOrEqual(editor.bounds.maxY - caret.maxY, editor.font!.lineHeight)
    }

    func testFocusedTextDoesNotMoveOffEnd() async throws {
        let editor = try await deliver(FixtureState.transcript)
        editor.becomeFirstResponder()
        await settle()
        assertAtEnd(editor)
        editor.insertText("END")
        await settle()
        XCTAssertEqual(editor.text, FixtureState.transcript + "END")
        assertAtEnd(editor)
        editor.resignFirstResponder()
        await settle()
        assertAtEnd(editor)
    }

    func testTranscriptLengthSweep() async throws {
        for count in [1, 2, 3, 4, 5, 6, 7, 8, 10, 20, 50] {
            for width: CGFloat in [230, 360, 398, 600] {
                state.text = ""
                state.width = width
                let text = String(repeating: "The blue kite floats above the garden. ", count: count).trimmingCharacters(in: .whitespaces)
                let editor = try await deliver(text)
                assertAtEnd(editor)
                let caret = editor.caretRect(for: editor.endOfDocument)
                XCTAssertLessThanOrEqual(editor.bounds.maxY - caret.maxY, editor.font!.lineHeight,
                                         "Unexpected blank rows: repeats=\(count), width=\(width)")
            }
        }
    }

    func testShortWordWrappingAtPhoneWidth() async throws {
        let text = String(repeating: "kite ", count: 65).trimmingCharacters(in: .whitespaces)
        let editor = try await deliver(text)
        assertAtEnd(editor)
        let caret = editor.caretRect(for: editor.endOfDocument)
        XCTAssertLessThanOrEqual(editor.bounds.maxY - caret.maxY, editor.font!.lineHeight)
        let expectedHeight = min(editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height, editor.maxContentHeight)
        XCTAssertEqual(editor.bounds.height, expectedHeight, accuracy: 1, "The editor must fit its actual wrapping width, without blank rows")
    }

    func testMediumDictationNaturalHeight() async throws {
        for count in [3, 4, 5, 6, 7] {
            state.width = 382
            let text = String(repeating: "Blue kites glide above the garden. ", count: count).trimmingCharacters(in: .whitespaces)
            let editor = try await deliver(text)
            assertAtEnd(editor)
            let expectedHeight = min(editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height, editor.maxContentHeight)
            XCTAssertEqual(editor.bounds.height, expectedHeight, accuracy: 1, "Count \(count): no blank rows")
        }
    }
}
