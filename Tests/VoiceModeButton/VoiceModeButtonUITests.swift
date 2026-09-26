import XCTest

final class VoiceModeButtonUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    private var toggle: XCUIElement { app.switches["Show Voice Mode Button"] }
    private var voice: XCUIElement { app.buttons["Voice call"] }
    private var webPill: XCUIElement { app.buttons.matching(NSPredicate(format: "label CONTAINS 'Web'")).firstMatch }
    private var options: [String] = []
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLight() { exercise(theme: "light") }
    func testDark() { exercise(theme: "dark") }

    func testQuickButtons() {
        options = ["--qa-pills"]
        launch(reset: true)
        XCTAssertTrue(webPill.exists)
        assertComposer(voiceShown: true)
        shot("quick-enabled")
        launch(settings: true)
        setVoice(false)
        closeSettings()
        assertComposer(voiceShown: false)
        XCTAssertTrue(webPill.exists)
        shot("quick-disabled")
        checkTyping()
        launch()
        assertComposer(voiceShown: false)
        XCTAssertTrue(webPill.exists)
    }

    func testServerCallPermissionIsRespected() {
        options = ["--qa-call-denied"]
        launch(settings: true, reset: true)
        XCTAssertEqual(toggle.value as? String, "1")
        setVoice(false)
        setVoice(true)
        closeSettings()
        assertComposer(voiceShown: false)
    }

    func testDictationPermissionIsIndependent() {
        options = ["--qa-stt-denied"]
        launch(reset: true)
        assertComposer(voiceShown: true, dictationShown: false)
        launch(settings: true)
        setVoice(false)
        closeSettings()
        assertComposer(voiceShown: false, dictationShown: false)
        checkTyping()
    }

    private func exercise(theme: String) {
        _ = request("/qa/reset", post: true)
        launch(theme: theme, reset: true)
        assertComposer(voiceShown: true)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        shot("\(theme)-enabled")

        launch(theme: theme, settings: true)
        XCTAssertEqual(toggle.value as? String, "1", "Preserve the default behavior")
        shot("\(theme)-settings-enabled")
        setVoice(false)
        shot("\(theme)-settings-disabled")
        closeSettings()
        assertComposer(voiceShown: false)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        shot("\(theme)-disabled")
        checkTyping()

        // Relaunch with no preference override: verify actual saved state.
        launch(theme: theme)
        assertComposer(voiceShown: false)
        launch(theme: theme, settings: true)
        XCTAssertEqual(toggle.value as? String, "0")
        setVoice(true)
        closeSettings()
        assertComposer(voiceShown: true)
        launch(theme: theme)
        assertComposer(voiceShown: true)
        XCTAssertEqual(request("/qa/state")["writes"] as? Int, 0,
                       "Changing button visibility must not write server settings or create a chat")
    }

    private func launch(theme: String = "light", settings: Bool = false, reset: Bool = false) {
        app.terminate()
        app.launchArguments = ["-openui.appearance.mode", theme, "-last_active_conversation_id", "",
                               "-AppleLanguages", "(en)"] + options
        if settings { app.launchArguments.append("--qa-settings") }
        if reset { app.launchArguments.append("--qa-reset") }
        app.launch()
        if settings {
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
            let behavior = app.buttons["Chat Behavior"]
            for _ in 0..<4 where !behavior.isHittable { app.swipeUp() }
            behavior.tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 30))
        }
    }

    private func assertComposer(voiceShown: Bool, dictationShown: Bool = true) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.voice.exists == voiceShown }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        if !voiceShown {
            XCTAssertTrue(app.buttons["Send message"].exists)
            XCTAssertFalse(app.buttons["Send message"].isEnabled)
        }
        XCTAssertEqual(app.buttons["Start dictation"].exists, dictationShown)
        XCTAssertTrue(app.buttons["Attachments & tools"].exists)
    }

    private func setVoice(_ enabled: Bool) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.toggle.value as? String == (enabled ? "1" : "0") },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func closeSettings() {
        app.navigationBars["Chat Settings"].buttons.firstMatch.tap()
        app.navigationBars["Settings"].buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 10))
    }

    private func checkTyping() {
        let input = app.textViews.firstMatch
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let draft = "Paper kite"
        // Let each keyboard event settle before testing the composer controls.
        for character in draft { input.typeText(String(character)) }
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send message"].isEnabled)
        XCTAssertFalse(voice.exists)
        for _ in draft { input.typeText(XCUIKeyboardKey.delete.rawValue) }
        XCTAssertEqual(input.value as? String, "")
        XCTAssertTrue(app.buttons["Send message"].exists)
        XCTAssertFalse(app.buttons["Send message"].isEnabled)
        XCTAssertFalse(voice.exists, "Clearing the draft must not bring back a hidden voice button")
        input.typeText(" ")
        XCTAssertFalse(app.buttons["Send message"].isEnabled, "Whitespace alone is not a message")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
    }

    private func shot(_ name: String) {
        let settled = expectation(description: "Settle transition")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func request(_ path: String, post: Bool = false) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18196" + path)!)
        if post { request.httpMethod = "POST" }
        let ready = expectation(description: path)
        var result: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, _, error in
            XCTAssertNil(error)
            result = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
            ready.fulfill()
        }.resume()
        wait(for: [ready], timeout: 5)
        return result
    }
}
