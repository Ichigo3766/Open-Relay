import XCTest

@MainActor final class ChannelWebhooksUITests: XCTestCase {
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
    func start() async throws {
        app.terminate(); try await post("reset")
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.staticTexts["Paper Crafts"].waitForExistence(timeout: 15))
        app.staticTexts["Paper Crafts"].tap()
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testBefore() async throws {
        try await start()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.textFields["Channel Name"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Webhooks"].exists)
        capture("before-channel-settings")
    }
    func openWebhooks() {
        XCTAssertTrue(app.buttons["Channel Actions"].waitForExistence(timeout: 10))
        app.buttons["Channel Actions"].tap()
        capture("after-channel-actions")
        app.buttons["Webhooks"].tap()
        XCTAssertTrue(app.navigationBars["Webhooks"].waitForExistence(timeout: 10))
    }
    func testManagement() async throws {
        try await start(); openWebhooks()
        XCTAssertTrue(app.staticTexts["Paper Bot"].waitForExistence(timeout: 10))
        capture("after-webhooks")
        app.buttons["Actions for Paper Bot"].tap()
        capture("after-webhook-actions")
        app.buttons["Copy Webhook URL"].tap()
        XCTAssertTrue(app.alerts["Webhook URL Copied"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        let untouched = try await state()
        XCTAssertEqual((untouched["writes"] as? [Any])?.count, 0)
        app.buttons["Actions for Paper Bot"].tap(); app.buttons["Rename"].tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10))
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Paper Bot".count) + "Craft Updates")
        try await post("mode", ["fail": true])
        app.navigationBars["Rename Webhook"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'undergoing maintenance'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Name"].value as? String, "Craft Updates")
        try await post("mode", ["fail": false])
        app.navigationBars["Rename Webhook"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Craft Updates"].waitForExistence(timeout: 10))
        let renamed = try await state()
        let hook = (renamed["hooks"] as? [String: [String: Any]])?["paper-hook"]
        XCTAssertEqual(hook?["profile_image_url"] as? String, "data:image/png;base64,c3ludGhldGlj")
        XCTAssertEqual((renamed["writes"] as? [Any])?.count, 2)
        app.buttons["Add Webhook"].tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10))
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("Paper Notices")
        capture("after-native-editor")
        app.navigationBars["New Webhook"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Paper Notices"].waitForExistence(timeout: 10))
        app.buttons["Actions for Craft Updates"].tap(); app.buttons["Delete Webhook"].tap()
        app.buttons["Delete Webhook"].tap()
        XCTAssertTrue(app.staticTexts["Craft Updates"].waitForNonExistence(timeout: 10))
        let deleted = try await state()
        XCTAssertEqual((deleted["hooks"] as? [String: Any])?.count, 1)
        capture("after-created")
    }
    func testPermissionRetry() async throws {
        try await start()
        try await post("mode", ["denied": true])
        openWebhooks()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Add Webhook"].isEnabled)
        XCTAssertFalse(app.staticTexts["Paper Bot"].exists)
        try await post("mode", ["denied": false])
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts["Paper Bot"].waitForExistence(timeout: 10))
    }
}
