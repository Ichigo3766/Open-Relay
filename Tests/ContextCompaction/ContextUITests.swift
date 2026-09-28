import XCTest

@MainActor final class ContextUITests: XCTestCase {
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
    func start(reset: Bool = true) async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30), "Connect only to the synthetic fixture first")
        app.buttons["Menu"].tap()
        let chat = app.buttons["Paper star planning"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
        XCTAssertTrue(app.buttons["More chat actions"].waitForExistence(timeout: 10)); app.buttons["More chat actions"].tap()
        app.buttons["Chat Settings"].tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 10))
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testBefore() async throws {
        try await start()
        XCTAssertFalse(app.buttons["Compact context"].exists)
        capture("before-no-context-controls")
    }
    func testContext() async throws {
        try await start()
        XCTAssertTrue(app.staticTexts["Estimated tokens, 6,000"].waitForExistence(timeout: 10))
        capture("after-context-usage")
        app.buttons["Compact context"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.last!.tap()
        let cancelled = try await state(); XCTAssertEqual(cancelled["posts"] as? Int, 0)
        app.buttons["Compact context"].tap()
        app.sheets["Compact conversation context?"].buttons["Compact context"].tap()
        XCTAssertTrue(app.staticTexts["Context compacted. Original messages are unchanged."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Estimated tokens, 2,000"].exists)
        capture("after-context-compacted")
        let done = try await state(); XCTAssertEqual(done["posts"] as? Int, 1)
        XCTAssertEqual(done["checkpoint"] as? String, "The synthetic plan uses five paper sheets.")
        try await post("mode", ["fail": true])
        app.buttons["Compact context"].tap(); app.sheets["Compact conversation context?"].buttons["Compact context"].tap()
        XCTAssertTrue(app.buttons["Refresh context"].waitForExistence(timeout: 10))
        app.buttons["Refresh context"].tap()
        XCTAssertTrue(app.buttons["Compact context"].waitForExistence(timeout: 10))
        let failed = try await state(); XCTAssertEqual(failed["posts"] as? Int, 2)
        try await start(reset: false)
        XCTAssertTrue(app.staticTexts["Estimated tokens, 2,000"].exists)
        try await post("mode", ["enabled": false])
        try await start(reset: false)
        XCTAssertFalse(app.buttons["Compact context"].exists)
    }
}
