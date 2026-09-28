import XCTest

@MainActor final class NotesUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }

    func openSearch() async throws {
        app.terminate()
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notes Search Demo'")).firstMatch.waitForExistence(timeout: 30), "Connect only to the synthetic fixture before testing")
        app.buttons["Menu"].tap()
        app.buttons["More"].tap()
        app.buttons["Notes"].tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap(); search.typeText("paper")
    }

    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testBefore() async throws {
        try await openSearch()
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(app.staticTexts["Paper Star 1"].exists)
        capture("before-search")
    }

    func testSearch() async throws {
        try await openSearch()
        XCTAssertTrue(app.staticTexts["Paper Star 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Paper Star 2"].exists)
        XCTAssertFalse(app.staticTexts["Paper Star 3"].exists)
        capture("after-search")
        app.buttons["Load More"].tap()
        XCTAssertTrue(app.staticTexts["Paper Star 3"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Load More"].exists)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        let calls = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(calls.map { $0["page"] as? Int }, [1, 2])
        XCTAssertTrue(calls.allSatisfy { $0["query"] as? String == "paper" })
        capture("after-next-page")
    }
}
