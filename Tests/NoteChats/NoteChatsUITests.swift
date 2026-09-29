import XCTest

@MainActor final class NoteChatsUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/" + path)!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }
    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func send() {
        let button = app.buttons.matching(NSPredicate(format: "label == 'Send message' AND enabled == true")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }
    func openNote(reset: Bool = true, appearance: String = "light", largeText: Bool = false, mainDraft: String? = nil) async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance,
                               "-openui.has_shown_onboarding", "YES"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Note Chat Demo'")).firstMatch.waitForExistence(timeout: 30), "Use only the isolated fixture")
        if let mainDraft {
            let input = app.textViews.firstMatch
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            input.typeText(mainDraft)
        }
        app.buttons["Menu"].tap(); app.buttons["More"].firstMatch.tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts["Paper Lanterns"].waitForExistence(timeout: 10))
        app.staticTexts["Paper Lanterns"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Notes"].waitForExistence(timeout: 10))
    }
    func testBefore() async throws {
        try await openNote()
        XCTAssertFalse(app.buttons["Chat about note"].exists)
        capture("before-note-editor")
        let result = try await state()
        XCTAssertEqual((result["requests"] as! [Any]).count, 0)
    }
    func testLinkedChat() async throws {
        try await openNote()
        XCTAssertTrue(app.buttons["Chat about note"].waitForExistence(timeout: 10))
        capture("after-note-editor")
        var result = try await state()
        XCTAssertEqual((result["requests"] as! [Any]).count, 0)
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'lightweight craft paper'")).firstMatch.waitForExistence(timeout: 10))
        capture("after-linked-conversation")
        app.buttons["Note chats"].tap()
        XCTAssertTrue(app.buttons["Paper choices"].waitForExistence(timeout: 10))
        capture("after-note-chat-history")
        app.navigationBars["Note chats"].buttons["New Chat"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        result = try await state()
        XCTAssertEqual(result["chat_count"] as? Int, 1, "An empty draft must not create a server chat")
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        let input = app.textViews.element(boundBy: app.textViews.count - 1)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        input.typeText("Shorten the checklist.")
        try await post("fail-create")
        send()
        XCTAssertTrue(app.staticTexts["Couldn’t create the note chat. Your message has not been sent. Please try again."].waitForExistence(timeout: 10))
        capture("after-creation-retry")
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
        XCTAssertEqual(input.value as? String, "Shorten the checklist.")
        send()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'checklist now has two steps'")).firstMatch.waitForExistence(timeout: 40))
        result = try await state()
        XCTAssertEqual(result["chat_count"] as? Int, 2)
        XCTAssertTrue((result["completions"] as! [[String: Any]]).allSatisfy { $0["valid"] as? Bool == true })
        capture("after-note-chat-answer")
        app.buttons["Note chats"].tap()
        XCTAssertTrue(app.navigationBars["Note chats"].buttons["Close"].waitForExistence(timeout: 10))
        app.navigationBars["Note chats"].buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["67 characters"].waitForExistence(timeout: 10))
        capture("after-updated-note")
        app.buttons["Edit"].tap()
        let editor = app.textViews.element(boundBy: app.textViews.count - 1)
        XCTAssertEqual(editor.value as? String, "# Folding checklist\n\n1. Fold a square sheet.\n2. Add a paper handle.")
        app.buttons["Preview"].tap()
        try await openNote(reset: false, appearance: "dark")
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        app.buttons["Note chats"].tap()
        XCTAssertTrue(app.buttons["New note chat"].waitForExistence(timeout: 10))
        app.buttons["New note chat"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'checklist now has two steps'")).firstMatch.waitForExistence(timeout: 10))
        capture("after-reopened-dark")
    }

    func testLinkRoutesOnlyToVisibleChat() async throws {
        try await openNote()
        try await post("link")
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        let paragraph = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant: Open the [folding guide]'")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        capture("link-placement")
        // The renderer exposes the paragraph as one accessibility element.
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.46)).tap()
        for _ in 0..<100 {
            if !(try await state()["downloads"] as! [String]).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500))
        let result = try await state()
        XCTAssertEqual((result["downloads"] as! [String]).count, 1)
    }

    func testHistoryRetryAndUnsavedNote() async throws {
        try await openNote()
        try await post("unsaved")
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.staticTexts["Save your note before opening its chat. The server does not have the current text yet."].waitForExistence(timeout: 10))
        let unchanged = try await state()
        XCTAssertEqual((unchanged["requests"] as! [Any]).count, 0)
        app.buttons["OK"].tap()
        try await post("reset")
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        try await post("fail-list")
        app.buttons["Note chats"].tap()
        XCTAssertTrue(app.staticTexts["Couldn’t load note chats. Please try again."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Paper choices"].exists)
        capture("after-history-retry")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts["Couldn’t load note chats. Please try again."].waitForNonExistence(timeout: 10))
    }

    func testDraftAndBackgroundCompletion() async throws {
        try await openNote(mainDraft: "Ordinary draft stays here.")
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        app.buttons["Note chats"].tap()
        app.navigationBars["Note chats"].buttons["New Chat"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        var input = app.textViews.element(boundBy: app.textViews.count - 1)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        input.typeText("Shorten the checklist.")
        app.buttons["Note chats"].tap()
        app.navigationBars["Note chats"].buttons["Close"].tap()
        app.buttons["Chat about note"].tap()
        app.buttons["Note chats"].tap()
        XCTAssertTrue(app.buttons["Resume draft"].waitForExistence(timeout: 10))
        app.buttons["Resume draft"].tap()
        input = app.textViews.element(boundBy: app.textViews.count - 1)
        XCTAssertEqual(input.value as? String, "Shorten the checklist.")
        try await post("hold-response")
        send()
        XCTAssertTrue(app.buttons["Stop Generating"].waitForExistence(timeout: 10))
        app.buttons["Note chats"].tap()
        app.navigationBars["Note chats"].buttons["Close"].tap()
        try await post("finish-response")
        XCTAssertTrue(app.staticTexts["67 characters"].waitForExistence(timeout: 15))
        capture("after-background-note-update")
        let result = try await state()
        XCTAssertEqual((result["completions"] as! [Any]).count, 1)
        app.navigationBars.buttons["Notes"].tap()
        app.navigationBars["Notes"].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Ordinary draft stays here.")
    }

    func testDeepLinkDoesNotReplaceNoteDraft() async throws {
        try await openNote()
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        var input = app.textViews.element(boundBy: app.textViews.count - 1)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        input.typeText("Note-only draft.")
        app.open(URL(string: "openui://new-chat?prompt=Ordinary%20draft.")!)
        XCTAssertTrue(app.buttons["Note chats"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        input = app.textViews.element(boundBy: app.textViews.count - 1)
        XCTAssertEqual(input.value as? String, "Ordinary draft.")
        app.buttons["Menu"].tap(); app.buttons["More"].firstMatch.tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts["Paper Lanterns"].waitForExistence(timeout: 10))
        app.staticTexts["Paper Lanterns"].tap()
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        input = app.textViews.element(boundBy: app.textViews.count - 1)
        XCTAssertEqual(input.value as? String, "Note-only draft.")
        let result = try await state()
        XCTAssertEqual((result["completions"] as! [Any]).count, 0)
    }

    func testLargeTextHistory() async throws {
        try await openNote(appearance: "dark", largeText: true)
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        app.buttons["Note chats"].tap()
        XCTAssertTrue(app.buttons["Paper choices"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Note chats"].buttons["Close"].isHittable)
        XCTAssertTrue(app.navigationBars["Note chats"].buttons["New Chat"].isHittable)
        capture("after-large-text-history")
    }

    func testBackgroundCompletionDoesNotOverwriteEditor() async throws {
        try await openNote()
        app.buttons["Chat about note"].tap()
        XCTAssertTrue(app.buttons["Note chats"].waitForExistence(timeout: 10))
        var input = app.textViews.element(boundBy: app.textViews.count - 1)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        input.typeText("Shorten the checklist.")
        try await post("hold-response")
        send()
        XCTAssertTrue(app.buttons["Stop Generating"].waitForExistence(timeout: 10))
        app.buttons["Note chats"].tap()
        app.navigationBars["Note chats"].buttons["Close"].tap()
        app.buttons["Edit"].tap()
        input = app.textViews.element(boundBy: app.textViews.count - 1)
        input.tap(); input.typeText(" Keep this wording.")
        let typed = input.value as? String
        XCTAssertTrue(typed?.contains("Keep this wording.") == true)
        try await Task.sleep(for: .seconds(2))
        try await post("finish-response")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(input.value as? String, typed, "Background note refresh must not replace text in the editor")
    }
}
