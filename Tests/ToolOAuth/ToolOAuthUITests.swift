import XCTest

@MainActor final class ToolOAuthUITests: XCTestCase {
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
    func start(dark: Bool = false) async throws {
        app.terminate(); try await post("reset")
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", dark ? "dark" : "light", "-quickPills", "server:mcp:paper"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["Paper folding"].waitForExistence(timeout: 15))
        app.buttons["Paper folding"].tap()
        XCTAssertTrue(app.buttons["Attachments & tools"].waitForExistence(timeout: 10))
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func openTools() {
        app.buttons["Attachments & tools"].tap()
        XCTAssertTrue(app.staticTexts["Paper Tools"].waitForExistence(timeout: 15))
    }
    func testBefore() async throws {
        try await start(); openTools()
        XCTAssertFalse(app.staticTexts["Connect"].exists)
        capture("before-tools")
        app.switches["Paper Tools"].tap()
        XCTAssertFalse(app.navigationBars["Connect Tool"].exists)
    }
    func testConnect() async throws {
        try await start(); openTools()
        XCTAssertTrue(app.staticTexts["Connect"].waitForExistence(timeout: 10))
        capture("after-tools")
        app.switches["Paper Tools"].tap()
        XCTAssertTrue(app.navigationBars["Connect Tool"].waitForExistence(timeout: 10))
        capture("after-connection")
        app.buttons["Check Connection"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This tool is not connected'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Connect in Browser"].tap()
        XCTAssertTrue(app.webViews.buttons["Sign in to Demo"].waitForExistence(timeout: 20))
        app.webViews.buttons["Sign in to Demo"].tap()
        XCTAssertTrue(app.webViews.links["Allow Paper Tools"].waitForExistence(timeout: 20))
        capture("after-provider")
        app.webViews.links["Allow Paper Tools"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Authorization complete"].waitForExistence(timeout: 20))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connected. Close this screen'")).firstMatch.waitForExistence(timeout: 15))
        capture("after-connected")
        let result = try await state()
        XCTAssertEqual(result["connected"] as? Bool, true)
        XCTAssertEqual(result["leaked_headers"] as? Bool, false)
        XCTAssertGreaterThan(result["provider_requests"] as? Int ?? 0, 0)
        app.navigationBars["Connect Tool"].buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Paper Tools"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Connect"].exists)
    }
    func testDraftGate() async throws {
        try await start()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText("Explain another fold.")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.navigationBars["Connect Tool"].waitForExistence(timeout: 15))
        let blocked = try await state()
        XCTAssertEqual(blocked["completions"] as? Int, 0)
        app.navigationBars["Connect Tool"].buttons["Close"].tap()
        XCTAssertEqual(editor.value as? String, "Explain another fold.")
        try await post("mode", ["connected": true])
        app.buttons["Send message"].tap()
        for _ in 0..<30 {
            let result = try await state()
            if result["completions"] as? Int == 1 {
                XCTAssertEqual(result["last_tools"] as? [String], ["server:mcp:paper"])
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Fold the corners inward.'")).firstMatch.waitForExistence(timeout: 15))
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Connected retry did not send")
    }
    func testWithoutTool() async throws {
        try await start(dark: true)
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText("Explain another fold.")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.navigationBars["Connect Tool"].waitForExistence(timeout: 15))
        capture("after-dark-choice")
        app.buttons["Use Without This Tool"].tap()
        XCTAssertEqual(editor.value as? String, "Explain another fold.")
        app.buttons["Send message"].tap()
        for _ in 0..<30 {
            let result = try await state()
            if result["completions"] as? Int == 1 {
                XCTAssertEqual(result["last_tools"] as? [String], [])
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Fold the corners inward.'")).firstMatch.waitForExistence(timeout: 15))
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Declining the tool did not allow sending")
    }
    func testFailedCheckAndQuickPill() async throws {
        try await start(); openTools()
        app.switches["Paper Tools"].tap()
        XCTAssertTrue(app.navigationBars["Connect Tool"].waitForExistence(timeout: 10))
        try await post("mode", ["fail": true])
        app.buttons["Check Connection"].tap()
        XCTAssertTrue(app.staticTexts["Couldn’t check the connection. Try again."].waitForExistence(timeout: 15))
        try await post("mode", ["fail": false])
        app.buttons["Check Connection"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This tool is not connected'")).firstMatch.waitForExistence(timeout: 15))
        app.navigationBars["Connect Tool"].buttons["Close"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["Paper Tools"].waitForExistence(timeout: 10))
        app.buttons["Paper Tools"].tap()
        XCTAssertTrue(app.navigationBars["Connect Tool"].waitForExistence(timeout: 10))
        let result = try await state()
        XCTAssertEqual(result["completions"] as? Int, 0)
        XCTAssertEqual(result["browser_requests"] as? Int, 0)
    }
}
