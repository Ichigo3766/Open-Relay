import XCTest

@MainActor final class NoteDraftsUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    let original = "Fold a square sheet. Add a paper handle."
    let extra = "Keep the blue square. "
    let failure = "Couldn’t save to the server. Your changes are saved on this device."
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
    func writes() async throws -> Int {
        (try await state()["requests"] as! [[String: String]]).filter { $0["method"] == "POST" }.count
    }
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func openNote(reset: Bool = true, appearance: String = "light", large: Bool = false) async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance,
                               "-openui.has_shown_onboarding", "YES"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        app.buttons["Menu"].tap(); app.buttons["More"].firstMatch.tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts["Paper Shapes"].waitForExistence(timeout: 10), "Use only the loopback fixture")
        app.staticTexts["Paper Shapes"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Notes"].waitForExistence(timeout: 10))
        if reset, app.buttons["Retry"].exists {
            // Clean up an interrupted earlier fixture test through the real UI.
            app.buttons["Discard"].tap()
            app.buttons["Discard Local Changes"].tap()
            XCTAssertTrue(app.buttons["Retry"].waitForNonExistence(timeout: 10))
        }
    }
    var editor: XCUIElement { app.textViews.element(boundBy: app.textViews.count - 1) }
    func edit() -> String {
        app.buttons["Edit"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText(extra)
        let entered = editor.value as! String
        XCTAssertTrue(entered.contains("blue square"))
        return entered
    }
    func readText() -> String {
        app.buttons["Edit"].tap()
        let text = editor.value as? String ?? ""
        app.buttons["Preview"].tap()
        return text
    }
    func reopen() {
        app.navigationBars.buttons["Notes"].tap()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Paper Shapes"].waitForExistence(timeout: 10))
        app.staticTexts["Paper Shapes"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
    }
    func testBefore() async throws {
        try await openNote()
        _ = edit()
        for _ in 0..<100 {
            if try await writes() > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(4))
        app.buttons["Preview"].tap()
        capture("before-failed-save")
        reopen()
        XCTAssertEqual(readText(), original)
        capture("before-reopened-edit-lost")
    }
    func testRecovery() async throws {
        try await openNote()
        let edited = edit()
        XCTAssertTrue(app.staticTexts[failure].waitForExistence(timeout: 15))
        app.buttons["Preview"].tap()
        capture("after-failed-save")
        let failedWrites = try await writes()
        XCTAssertEqual(failedWrites, 1, "A failed save must not be retried automatically")
        reopen()
        XCTAssertEqual(readText(), edited)
        try await openNote(reset: false, appearance: "dark")
        XCTAssertEqual(readText(), edited)
        XCTAssertTrue(app.buttons["Retry"].exists)
        capture("after-relaunch-recovered")
        try await Task.sleep(for: .seconds(2))
        let reopenedWrites = try await writes()
        XCTAssertEqual(reopenedWrites, failedWrites, "Reopening must not resubmit")
        try await post("succeed")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForNonExistence(timeout: 10))
        let saved = try await state()
        XCTAssertEqual(saved["content"] as? String, edited)
        capture("after-synced")
        try await openNote(reset: false)
        XCTAssertEqual(readText(), edited)
        XCTAssertFalse(app.buttons["Retry"].exists)
    }
    func testConflictAndShare() async throws {
        try await openNote()
        let edited = edit()
        XCTAssertTrue(app.staticTexts[failure].waitForExistence(timeout: 15))
        app.buttons["Preview"].tap()
        try await post("conflict")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts["The server note has changed. Copy your saved text before reloading the server version."].waitForExistence(timeout: 10))
        capture("after-conflict")
        let beforeShare = try await writes()
        app.buttons["Share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        capture("after-native-share")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForNonExistence(timeout: 10))
        let afterShare = try await writes()
        XCTAssertEqual(afterShare, beforeShare)
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.buttons["Discard Local Changes"].waitForExistence(timeout: 10))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap() }
        XCTAssertTrue(app.buttons["Discard Local Changes"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(readText(), edited)
        app.buttons["Discard"].tap()
        app.buttons["Discard Local Changes"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(readText(), "Use a paper strip instead.")
    }
    func testLargeText() async throws {
        try await openNote()
        _ = edit()
        XCTAssertTrue(app.staticTexts[failure].waitForExistence(timeout: 15))
        try await openNote(reset: false, large: true)
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertGreaterThan(app.buttons["Share"].frame.minY, app.buttons["Retry"].frame.maxY)
        XCTAssertGreaterThan(app.buttons["Discard"].frame.minY, app.buttons["Share"].frame.maxY)
        capture("after-large-text")
        try await post("succeed")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForNonExistence(timeout: 10))
    }
    func testFormattingSurvivesReopen() async throws {
        try await openNote()
        app.buttons["Edit"].tap()
        app.buttons["B"].tap()
        XCTAssertTrue(app.staticTexts[failure].waitForExistence(timeout: 15))
        app.buttons["Preview"].tap()
        reopen()
        XCTAssertEqual(readText(), original + "**text**")
        try await post("succeed")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForNonExistence(timeout: 10))
    }
    func testTypingDuringFailedSaveDoesNotRetry() async throws {
        try await openNote()
        try await post("hold-update")
        _ = edit()
        for _ in 0..<100 {
            if try await writes() == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        editor.typeText(" More.")
        let entered = editor.value as! String
        try await post("release-update")
        XCTAssertTrue(app.staticTexts[failure].waitForExistence(timeout: 10))
        try await Task.sleep(for: .seconds(2))
        let attempts = try await writes()
        XCTAssertEqual(attempts, 1, "A previously scheduled autosave cannot retry a failed request")
        app.buttons["Preview"].tap()
        reopen()
        XCTAssertEqual(readText(), entered)
        try await post("succeed")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForNonExistence(timeout: 10))
        let saved = try await state()
        XCTAssertEqual(saved["content"] as? String, entered)
    }
    func testTypingDuringSuccessfulSaveKeepsNewestText() async throws {
        try await openNote()
        try await post("succeed")
        try await post("hold-update")
        _ = edit()
        for _ in 0..<100 {
            if try await writes() == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        editor.typeText(" More.")
        let entered = editor.value as! String
        try await post("release-update")
        for _ in 0..<100 {
            if try await state()["content"] as? String == entered { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let saved = try await state()
        XCTAssertEqual(saved["content"] as? String, entered)
        let attempts = try await writes()
        XCTAssertEqual(attempts, 2, "Each of the two edited revisions is saved once")
        try await openNote(reset: false)
        XCTAssertEqual(readText(), entered)
        XCTAssertFalse(app.buttons["Retry"].exists)
    }
}
