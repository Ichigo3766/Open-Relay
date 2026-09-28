import XCTest

@MainActor final class NotePinsUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/" + path)!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }
    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func openNotes(reset: Bool = true) async throws {
        app.terminate()
        if reset { try await post("_test/reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Note Pins Demo'")).firstMatch.waitForExistence(timeout: 30), "Connect only to the synthetic fixture first")
        app.buttons["Menu"].tap(); app.buttons["More"].tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Paper Stars"].waitForExistence(timeout: 10))
    }
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func toggle(_ label: String) {
        app.staticTexts["Paper Stars"].press(forDuration: 1)
        XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5))
        app.buttons[label].tap()
    }
    func testBefore() async throws {
        try await openNotes()
        XCTAssertFalse(app.staticTexts["Pinned"].exists)
        capture("before-server-pin-ignored")
    }
    func testPinRoundTrip() async throws {
        try await openNotes()
        XCTAssertTrue(app.staticTexts["Pinned"].exists)
        capture("after-server-pin")
        toggle("Unpin")
        for _ in 0..<20 {
            if try await state()["pinned"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let unpinned = try await state()
        XCTAssertEqual(unpinned["pinned"] as? Bool, false)
        XCTAssertEqual(unpinned["calls"] as? Int, 1)
        try await openNotes(reset: false)
        XCTAssertFalse(app.staticTexts["Pinned"].exists)
        toggle("Pin")
        XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 10))
        let pinned = try await state()
        XCTAssertEqual(pinned["pinned"] as? Bool, true)
        XCTAssertEqual(pinned["calls"] as? Int, 2)
        try await post("_test/fail")
        toggle("Unpin")
        XCTAssertTrue(app.alerts["Could Not Update Note"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Pinned"].exists)
        let failed = try await state()
        XCTAssertEqual(failed["pinned"] as? Bool, true)
        XCTAssertEqual(failed["calls"] as? Int, 3, "No automatic retries for a toggle")
    }
}
