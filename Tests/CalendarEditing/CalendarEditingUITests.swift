import XCTest

@MainActor final class CalendarEditingUITests: XCTestCase {
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
        XCTAssertTrue(app.staticTexts["Paper workshop"].waitForExistence(timeout: 15))
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func replaceTitle(_ text: String) {
        let field = app.textFields["Title"]
        field.tap()
        let old = field.value as? String ?? ""
        if old != "Title" { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        field.typeText(text)
    }
    func testBefore() async throws {
        try await start()
        app.staticTexts["Paper workshop"].tap()
        XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Edit Event"].exists)
        capture("before-no-edit-action")
        app.buttons["Done"].tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 10))
        replaceTitle("Draft paper lantern")
        capture("before-create-form")
        try await post("mode", ["fail": true])
        app.buttons["Create"].tap()
        XCTAssertTrue(app.textFields["Title"].waitForNonExistence(timeout: 10), "Baseline loses the draft on failure")
        let result = try await state()
        XCTAssertEqual((result["writes"] as? [Any])?.count, 1)
        XCTAssertEqual((result["events"] as? [String: Any])?.count, 1)
    }
    func testEditSeries() async throws {
        try await start()
        let initial = try await state()
        let seriesStart = ((initial["events"] as? [String: [String: Any]])?["paper-series"]?["start_at"]) as? Int64
        app.staticTexts["Paper workshop"].tap()
        XCTAssertTrue(app.buttons["Edit Event"].waitForExistence(timeout: 10))
        try await post("mode", ["fail_fetch": true])
        app.buttons["Edit Event"].tap()
        XCTAssertTrue(app.alerts["Couldn’t open event"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        try await post("mode", ["fail_fetch": false])
        app.buttons["Edit Event"].tap()
        XCTAssertTrue(app.navigationBars["Edit Series"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Recurrence rule"].value as? String, "FREQ=WEEKLY;BYDAY=MO;COUNT=8")
        capture("after-series-editor")
        replaceTitle("Paper lantern workshop")
        try await post("mode", ["fail": true])
        app.navigationBars["Edit Series"].buttons["Save"].tap()
        XCTAssertTrue(app.alerts["Couldn’t save event"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(app.textFields["Title"].value as? String, "Paper lantern workshop")
        try await post("mode", ["fail": false])
        app.navigationBars["Edit Series"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Series"].waitForNonExistence(timeout: 10))
        let saved = try await state()
        let item = (saved["events"] as? [String: [String: Any]])?["paper-series"]
        XCTAssertEqual(item?["title"] as? String, "Paper lantern workshop")
        XCTAssertEqual(item?["start_at"] as? Int64, seriesStart, "Do not move series to the selected occurrence")
        XCTAssertEqual(item?["rrule"] as? String, "FREQ=WEEKLY;BYDAY=MO;COUNT=8")
        XCTAssertEqual((item?["meta"] as? [String: Any])?["external_marker"] as? String, "preserve")
        XCTAssertEqual((item?["attendees"] as? [Any])?.count, 1)
        XCTAssertEqual((saved["writes"] as? [Any])?.count, 2, "No automatic mutation retries")
        XCTAssertTrue(app.staticTexts["Paper lantern workshop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["None"].exists)
        capture("after-saved-event")
    }
    func testCreateRetry() async throws {
        try await start()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["New Event"].waitForExistence(timeout: 10))
        replaceTitle("Paper garland")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Repeat'")).firstMatch.tap()
        app.buttons["Weekly"].tap()
        try await post("mode", ["fail": true])
        app.navigationBars["New Event"].buttons["Save"].tap()
        XCTAssertTrue(app.alerts["Couldn’t save event"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(app.textFields["Title"].value as? String, "Paper garland")
        app.collectionViews.firstMatch.swipeDown()
        capture("after-create-form")
        try await post("mode", ["fail": false])
        app.navigationBars["New Event"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["New Event"].waitForNonExistence(timeout: 10))
        let saved = try await state()
        XCTAssertEqual((saved["events"] as? [String: Any])?.count, 2)
        XCTAssertEqual((((saved["writes"] as? [[String: Any]])?.last)?["body"] as? [String: Any])?["rrule"] as? String, "FREQ=WEEKLY")
    }
    func testCancel() async throws {
        try await start(appearance: "dark")
        app.staticTexts["Paper workshop"].tap()
        XCTAssertTrue(app.buttons["Edit Event"].waitForExistence(timeout: 10))
        app.buttons["Edit Event"].tap()
        XCTAssertTrue(app.navigationBars["Edit Series"].waitForExistence(timeout: 10))
        capture("after-dark-editor")
        replaceTitle("Unsaved paper draft")
        app.navigationBars["Edit Series"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Edit Series"].waitForNonExistence(timeout: 10))
        let result = try await state()
        XCTAssertEqual((result["writes"] as? [Any])?.count, 0)
        XCTAssertTrue(app.staticTexts["Paper workshop"].exists)
    }
}
