import XCTest

@MainActor final class ConsentUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")

    override func setUpWithError() throws { continueAfterFailure = false }

    func replies() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["replies"] as? [[String: Any]] ?? []
    }

    func start(_ scenario: String = "consent") async throws {
        app.terminate()
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/reset")!)
        reset.httpMethod = "POST"
        reset.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reset.httpBody = try JSONSerialization.data(withJSONObject: ["scenario": scenario])
        _ = try await URLSession.shared.data(for: reset)
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.buttons["Connect"].exists {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("http://127.0.0.1:18191")
            app.buttons["Connect"].tap()
        }
        if app.staticTexts["Version 0.0.0-consent-fixture"].waitForExistence(timeout: 3) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tool Consent Demo'")).firstMatch.waitForExistence(timeout: 30))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("Please run the synthetic tool.")
        app.buttons["Send message"].tap()
    }

    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testBefore() async throws {
        try await start()
        for _ in 0..<30 {
            if !(try await replies()).isEmpty { break }
            try await Task.sleep(for: .seconds(1))
        }
        let received = try await replies()
        XCTAssertEqual(received.first?["value"] as? Bool, true, "Baseline auto-approves without a tap")
        XCTAssertFalse(app.navigationBars["Run the demo tool?"].exists)
        capture("before-auto-approved")
    }

    func testConsent() async throws {
        try await start()
        XCTAssertTrue(app.navigationBars["Run the demo tool?"].waitForExistence(timeout: 30))
        let before = try await replies()
        XCTAssertTrue(before.isEmpty)
        capture("after-confirmation")
        app.buttons["Confirm"].tap()
        XCTAssertTrue(app.navigationBars["Name the paper sky"].waitForExistence(timeout: 15))
        capture("after-input")
        app.buttons["Confirm"].tap()
        for _ in 0..<20 {
            if try await replies().count == 2 { break }
            try await Task.sleep(for: .seconds(1))
        }
        let received = try await replies()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0]["value"] as? Bool, true)
        XCTAssertEqual(received[1]["value"] as? String, "Paper sky")
        XCTAssertTrue(app.staticTexts["Demo tool finished"].waitForExistence(timeout: 5))
        capture("after-notification")
    }

    func testCancel() async throws {
        try await start()
        XCTAssertTrue(app.navigationBars["Run the demo tool?"].waitForExistence(timeout: 30))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Name the paper sky"].waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        for _ in 0..<20 {
            if try await replies().count == 2 { break }
            try await Task.sleep(for: .seconds(1))
        }
        let received = try await replies()
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0["value"] as? Bool == false })
    }

    func resolves() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["resolves"] as? [[String: Any]] ?? []
    }

    func selectBlue() {
        XCTAssertTrue(app.staticTexts["Which paper color?"].waitForExistence(timeout: 30))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'A blue sky'")).firstMatch.tap()
    }

    func testAskUserBefore() async throws {
        try await start("ask")
        selectBlue()
        for _ in 0..<20 {
            if !(try await resolves()).isEmpty { break }
            try await Task.sleep(for: .seconds(1))
        }
        let calls = try await resolves(), responses = try await replies()
        XCTAssertEqual(calls.first?["call_id"] as? String, "")
        XCTAssertTrue(responses.isEmpty, "Baseline never answers the waiting live callback")
        capture("ask-before-unanswered")
    }

    func testAskUser() async throws {
        try await start("ask")
        XCTAssertTrue(app.staticTexts["Which paper color?"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.textFields["Type your answer"].exists, "Question disables Other even when global default permits it")
        capture("ask-question")
        selectBlue()
        for _ in 0..<20 {
            if !(try await replies()).isEmpty { break }
            try await Task.sleep(for: .seconds(1))
        }
        let responses = try await replies(), calls = try await resolves()
        let answer = responses.first?["value"] as? [String: Any]
        XCTAssertEqual(answer?["status"] as? String, "answered")
        let option = (answer?["answers"] as? [String: Any])?["color"] as? [String: Any]
        XCTAssertEqual(option?["label"] as? String, "Blue")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'The synthetic tool received your answer.'")).firstMatch.waitForExistence(timeout: 15))
        capture("ask-after-answered")
    }

    func testSavedAskUserRetry() async throws {
        try await start("saved")
        selectBlue()
        XCTAssertTrue(app.staticTexts["Could not send your response. Please try again."].waitForExistence(timeout: 20))
        capture("ask-saved-retry")
        app.buttons["Submit answers"].tap()
        for _ in 0..<20 {
            if try await resolves().count == 2 { break }
            try await Task.sleep(for: .seconds(1))
        }
        let calls = try await resolves()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0["call_id"] as? String == "demo-call" })
        XCTAssertEqual(calls[0] as NSDictionary, calls[1] as NSDictionary, "Retry preserves the selected answer")
        XCTAssertTrue(app.staticTexts["Which paper color?"].waitForNonExistence(timeout: 10))
    }
}
