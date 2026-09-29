import XCTest

@MainActor final class CalendarRSVPUITests: XCTestCase {
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
    func start(reset: Bool = true, appearance: String = "light", largeText: Bool = false) async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        app.buttons["Menu"].tap(); app.buttons["More"].tap(); app.buttons["Calendar"].tap()
        XCTAssertTrue(app.staticTexts["Paper workshop"].waitForExistence(timeout: 15))
        app.staticTexts["Paper workshop"].tap()
        XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 10))
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func response(_ expected: String) {
        let button = app.buttons["Your Response"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: button)
        waitForExpectations(timeout: 10)
    }
    func choose(_ label: String) {
        app.buttons["Your Response"].tap()
        app.buttons[label].tap()
    }
    func testBefore() async throws {
        try await start()
        XCTAssertFalse(app.buttons["Your Response"].exists)
        capture("before-no-rsvp")
    }
    func testResponsesAndRelaunch() async throws {
        try await start(); response("Not Responded")
        capture("after-invitation")
        app.buttons["Your Response"].tap(); capture("after-response-menu")
        app.buttons["Accepted"].tap(); response("Accepted")
        capture("after-accepted")
        try await start(reset: false, appearance: "dark"); response("Accepted")
        capture("after-dark-reopened")
        choose("Maybe"); response("Maybe")
        choose("Declined"); response("Declined")
        choose("Not Responded"); response("Not Responded")
        let saved = try await state()
        let writes = saved["writes"] as! [[String: Any]]
        XCTAssertEqual(writes.count, 4)
        XCTAssertTrue(writes.allSatisfy { $0["path"] as? String == "/api/v1/calendars/events/paper-series/rsvp" })
        let attendees = ((saved["events"] as! [String: [String: Any]])["paper-series"]!["attendees"] as! [[String: Any]])
        XCTAssertEqual(attendees[1]["status"] as? String, "declined")
        app.navigationBars["Event"].buttons["Close"].tap()
        app.staticTexts["Open craft room"].tap()
        XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Your Response"].exists)
    }
    func testFailureRetryAndPending() async throws {
        try await start(); response("Not Responded")
        try await post("mode", ["fail": true])
        choose("Accepted")
        XCTAssertTrue(app.alerts["Couldn’t save response"].waitForExistence(timeout: 10))
        capture("after-failed-response")
        app.alerts.buttons["OK"].tap(); response("Not Responded")
        try await post("mode", ["fail": false, "delay": 2])
        choose("Accepted")
        XCTAssertFalse(app.buttons["Your Response"].isEnabled)
        response("Accepted")
        let saved = try await state()
        XCTAssertEqual((saved["writes"] as? [Any])?.count, 2)
        try await post("mode", ["delay": 0, "malformed": true])
        choose("Declined")
        XCTAssertTrue(app.alerts["Couldn’t save response"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap(); response("Accepted")
    }
    func testLargeText() async throws {
        try await start(largeText: true)
        response("Not Responded")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        let button = app.buttons["Your Response"]
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThan(button.frame.minY, app.navigationBars["Event"].frame.maxY)
        XCTAssertLessThan(button.frame.maxY, app.frame.maxY)
        capture("after-large-text")
        choose("Accepted"); response("Accepted")
    }
}
