import XCTest

@MainActor final class SearchConsentUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    let question = "Find information about paper stars."
    override func setUpWithError() throws { continueAfterFailure = false }

    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func requests() async throws -> [[String: Any]] { try await state()["requests"] as? [[String: Any]] ?? [] }

    func start(required: Bool = true) async throws {
        app.terminate()
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/reset")!)
        reset.httpMethod = "POST"; reset.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reset.httpBody = try JSONSerialization.data(withJSONObject: ["required": required])
        _ = try await URLSession.shared.data(for: reset)
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.buttons["Connect"].exists {
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("http://127.0.0.1:18191")
            app.buttons["Connect"].tap()
        }
        if app.staticTexts["Version 0.0.0-search-fixture"].waitForExistence(timeout: 3) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Search Consent Demo'")).firstMatch.waitForExistence(timeout: 30))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText(question)
        app.buttons["Send message"].tap()
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func waitForRequest() async throws -> [[String: Any]] {
        for _ in 0..<20 {
            if !(try await requests()).isEmpty { break }
            try await Task.sleep(for: .seconds(1))
        }
        return try await requests()
    }

    func testBefore() async throws {
        try await start()
        let sent = try await waitForRequest()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual((sent[0]["features"] as? [String: Any])?["web_search"] as? Bool, true)
        XCTAssertFalse(app.alerts["Use Web Search?"].exists)
        capture("before-no-consent")
    }
    func testConsent() async throws {
        try await start()
        XCTAssertTrue(app.alerts["Use Web Search?"].waitForExistence(timeout: 20))
        let before = try await state()
        XCTAssertTrue((before["requests"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(before["chats"] as? Int, 0, "No chat is created before consent")
        XCTAssertTrue(app.staticTexts["This demo sends a search query to the configured provider. Continue?"].exists)
        capture("after-confirmation")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(app.textViews.firstMatch.value as? String, question, "Cancel preserves the draft")
        let cancelled = try await requests()
        XCTAssertTrue(cancelled.isEmpty)
        capture("after-cancel")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.alerts["Use Web Search?"].waitForExistence(timeout: 10))
        app.alerts.buttons["Continue"].tap()
        let sent = try await waitForRequest()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual((sent[0]["features"] as? [String: Any])?["web_search"] as? Bool, true)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'The synthetic search request was received.'")).firstMatch.waitForExistence(timeout: 10))
        capture("after-approved")
    }
    func testDisabledPolicy() async throws {
        try await start(required: false)
        let sent = try await waitForRequest()
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(app.alerts["Use Web Search?"].exists)
    }
}
