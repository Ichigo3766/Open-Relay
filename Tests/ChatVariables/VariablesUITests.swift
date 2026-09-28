import XCTest

@MainActor final class VariablesUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/" + path)!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
    }
    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func start(reset: Bool = true, chat: Bool = true) async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light", "-temporaryChatDefault", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30), "Connect only to the synthetic fixture first")
        if chat {
            app.buttons["Menu"].tap()
            let row = app.buttons["Synthetic craft planning"]
            XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        }
    }
    func controls() {
        XCTAssertTrue(app.buttons["More chat actions"].waitForExistence(timeout: 10)); app.buttons["More chat actions"].tap()
        app.buttons["Chat Settings"].tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 10))
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func send(_ text: String) {
        let input = app.textViews.firstMatch
        input.tap(); input.typeText(text); app.buttons["Send message"].tap()
    }
    func waitForCompletions(_ count: Int) async throws -> [String: Any] {
        for _ in 0..<100 {
            let result = try await state()
            if (result["completions"] as? [Any])?.count == count { return result }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Expected synthetic completion request")
        return try await state()
    }
    func testBefore() async throws {
        try await start(); controls()
        XCTAssertFalse(app.buttons["Chat Variables"].exists)
        capture("before-no-chat-variables")
        app.navigationBars["Controls"].buttons["Cancel"].tap()
        send("Plan a synthetic paper craft.")
        XCTAssertFalse(app.navigationBars["Chat Variables"].waitForExistence(timeout: 3))
        let result = try await state()
        XCTAssertEqual((result["completions"] as? [Any])?.count, 1)
        XCTAssertEqual(result["writes"] as? Int, 0)
    }
    func testSavedVariables() async throws {
        try await start()
        send("Plan a synthetic paper craft.")
        XCTAssertTrue(app.navigationBars["Chat Variables"].waitForExistence(timeout: 10))
        let initial = try await state()
        XCTAssertEqual((initial["completions"] as? [Any])?.count, 0)
        let topic = app.textFields["Craft Topic"]
        topic.tap(); topic.typeText("Paper stars")
        capture("after-required-variables")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 5))
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.75)
        try await post("mode", ["fail": true])
        app.navigationBars["Chat Variables"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["The server is undergoing maintenance. Please try again later."].waitForExistence(timeout: 10))
        XCTAssertEqual(topic.value as? String, "Paper stars")
        try await post("mode", ["fail": false])
        app.navigationBars["Chat Variables"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Chat Variables"].waitForNonExistence(timeout: 10))
        let saved = try await state()
        let values = ((saved["chats"] as? [String: [String: Any]])?["synthetic-variables"]?["variables"]) as? [String: Any]
        XCTAssertEqual(values?["topic"] as? String, "Paper stars")
        XCTAssertEqual(values?["copies"] as? Int, 3)
        XCTAssertEqual(values?["scale"] as? Double, 0.75, "Fractional range values must not be truncated")
        XCTAssertEqual(values?["include_title"] as? Bool, false)
        XCTAssertNotNil(values?["other_model"])
        XCTAssertEqual((saved["completions"] as? [Any])?.count, 0, "Saving must not send")
        app.buttons["Send message"].tap()
        let completion = try await waitForCompletions(1)
        XCTAssertNil((completion["completions"] as? [[String: Any]])?.first?["chat_variables"], "Saved chat uses server values")
        XCTAssertTrue(app.buttons["Stop Generating"].waitForNonExistence(timeout: 20))
        try await start(reset: false); controls()
        app.buttons["Chat Variables"].tap()
        XCTAssertTrue(app.navigationBars["Chat Variables"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Craft Topic"].value as? String, "Paper stars")
        capture("after-reopened-variables")
        app.navigationBars["Chat Variables"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 10))
        capture("after-native-controls")
    }
    func testNewChatVariables() async throws {
        try await start(chat: false)
        send("Describe a synthetic folded kite.")
        XCTAssertTrue(app.navigationBars["Chat Variables"].waitForExistence(timeout: 10))
        app.textFields["Craft Topic"].tap(); app.textFields["Craft Topic"].typeText("Folded kite")
        app.navigationBars["Chat Variables"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Chat Variables"].waitForNonExistence(timeout: 10))
        try await post("mode", ["fail_create": true])
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["The server is undergoing maintenance. Please try again later."].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Describe a synthetic folded kite.")
        let failed = try await state(); XCTAssertEqual((failed["completions"] as? [Any])?.count, 0)
        try await post("mode", ["fail_create": false])
        app.buttons["Send message"].tap()
        _ = try await waitForCompletions(1)
        XCTAssertTrue(app.buttons["Stop Generating"].waitForNonExistence(timeout: 20))
        let saved = try await state()
        XCTAssertEqual(((saved["creates"] as? [[String: Any]])?.last?["variables"] as? [String: Any])?["topic"] as? String, "Folded kite")
    }
    func testTemporaryVariables() async throws {
        try await start(chat: false)
        app.buttons["More chat actions"].tap()
        app.buttons["Turn On Temporary Chat"].tap()
        send("Describe a temporary paper craft.")
        XCTAssertTrue(app.navigationBars["Chat Variables"].waitForExistence(timeout: 10))
        app.textFields["Craft Topic"].tap(); app.textFields["Craft Topic"].typeText("Paper lantern")
        app.navigationBars["Chat Variables"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Chat Variables"].waitForNonExistence(timeout: 10))
        app.buttons["Send message"].tap()
        let sent = try await waitForCompletions(1)
        XCTAssertEqual((sent["creates"] as? [Any])?.count, 0)
        XCTAssertEqual(sent["writes"] as? Int, 0)
        XCTAssertEqual(((sent["completions"] as? [[String: Any]])?.first?["chat_variables"] as? [String: Any])?["topic"] as? String, "Paper lantern")
        XCTAssertTrue(app.buttons["Stop Generating"].waitForNonExistence(timeout: 20))
        app.buttons["More chat actions"].tap()
        app.buttons["Save as permanent chat"].tap()
        var promoted = try await state()
        for _ in 0..<100 where (promoted["creates"] as? [Any])?.isEmpty == true {
            try await Task.sleep(for: .milliseconds(100))
            promoted = try await state()
        }
        XCTAssertEqual(((promoted["creates"] as? [[String: Any]])?.first?["variables"] as? [String: Any])?["topic"] as? String, "Paper lantern")
    }
}
