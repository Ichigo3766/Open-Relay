import XCTest

@MainActor final class CalendarManagementUITests: XCTestCase {
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
    func start(reset: Bool = true, appearance: String = "light") async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        app.buttons["Menu"].tap(); app.buttons["More"].tap(); app.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["Month"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Month"].firstMatch.tap()
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func openManagement() {
        capture("after-calendar-menu")
        app.buttons["Manage Calendars"].tap()
        XCTAssertTrue(app.navigationBars["Calendars"].waitForExistence(timeout: 10))
    }
    func testBefore() async throws {
        try await start()
        XCTAssertFalse(app.buttons["Manage Calendars"].exists)
        capture("before-calendar-menu")
    }
    func testManagement() async throws {
        try await start(); openManagement()
        XCTAssertFalse(app.buttons["Actions for Scheduled Tasks"].exists)
        capture("after-calendar-list")
        app.buttons["Actions for Crafts"].tap()
        XCTAssertFalse(app.buttons["Delete Calendar"].exists)
        XCTAssertFalse(app.buttons["Make Default"].exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10))
        app.textFields["Name"].tap(); app.textFields["Name"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Paper Crafts")
        try await post("mode", ["fail": true])
        app.navigationBars["Edit Calendar"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'undergoing maintenance'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Name"].value as? String, "Paper Crafts")
        try await post("mode", ["fail": false])
        app.navigationBars["Edit Calendar"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Paper Crafts"].waitForExistence(timeout: 10))
        let renamed = try await state()
        let craft = (renamed["calendars"] as? [String: [String: Any]])?["crafts"]
        XCTAssertEqual((craft?["data"] as? [String: String])?["preserve"], "data")
        XCTAssertEqual((craft?["access_grants"] as? [Any])?.count, 1)
        XCTAssertEqual((renamed["writes"] as? [Any])?.count, 2)
        app.buttons["New Calendar"].tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10))
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("Paper Projects")
        capture("after-calendar-editor")
        app.navigationBars["New Calendar"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Actions for Paper Projects"].waitForExistence(timeout: 10))
        let created = try await state()
        let newCalendar = (created["calendars"] as? [String: [String: Any]])?.values.first { $0["name"] as? String == "Paper Projects" }
        XCTAssertEqual(newCalendar?["color"] as? String, "#3b82f6")
        app.buttons["Actions for Paper Projects"].tap()
        capture("after-calendar-actions")
        app.buttons["Make Default"].tap()
        let changed = try await state()
        XCTAssertEqual(((changed["calendars"] as? [String: [String: Any]])?["crafts"]?["is_default"]) as? Bool, false)
        app.buttons["Actions for Workshops"].tap(); app.buttons["Delete Calendar"].tap()
        capture("after-delete-confirmation")
        app.buttons["Delete Calendar"].tap()
        XCTAssertTrue(app.staticTexts["Workshops"].waitForNonExistence(timeout: 10))
        try await start(reset: false); openManagement()
        XCTAssertTrue(app.staticTexts["Paper Projects"].exists)
        XCTAssertFalse(app.staticTexts["Workshops"].exists)
        app.navigationBars["Calendars"].buttons["Close"].tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Paper Projects'")).firstMatch.waitForExistence(timeout: 10), "New events use the signed-in user's default, not a shared calendar's default")
    }
    func testCancel() async throws {
        try await start(appearance: "dark"); openManagement()
        app.buttons["New Calendar"].tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10))
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("Unsaved paper plans")
        capture("after-dark-editor")
        app.navigationBars["New Calendar"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["New Calendar"].waitForNonExistence(timeout: 10))
        let result = try await state()
        XCTAssertEqual((result["writes"] as? [Any])?.count, 0)
    }
    func testFailedActions() async throws {
        try await start(); openManagement()
        try await post("mode", ["fail": true])
        app.buttons["Actions for Workshops"].tap(); app.buttons["Make Default"].tap()
        XCTAssertTrue(app.alerts["Couldn’t update calendar"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        let unchanged = try await state()
        XCTAssertEqual(((unchanged["calendars"] as? [String: [String: Any]])?["crafts"]?["is_default"]) as? Bool, true)
        app.buttons["Actions for Workshops"].tap(); app.buttons["Delete Calendar"].tap()
        app.buttons["Delete Calendar"].tap()
        XCTAssertTrue(app.alerts["Couldn’t update calendar"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Workshops"].exists)
        let retained = try await state()
        XCTAssertEqual((retained["writes"] as? [Any])?.count, 2)
    }
}
