import XCTest

@MainActor final class NoteWriteAccessUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/" + path)!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }
    func updates() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["updates"] as! [[String: Any]]
    }
    func openNote(mode: String = "readonly", appearance: String = "light") async throws {
        app.terminate()
        try await post("_test/reset")
        if mode != "readonly" { try await post("_test/" + mode) }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notes Access Demo'")).firstMatch.waitForExistence(timeout: 30), "Use only the loopback fixture")
        app.buttons["Menu"].tap(); app.buttons["More"].tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts["Paper Lanterns"].waitForExistence(timeout: 10))
        app.staticTexts["Paper Lanterns"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Paper Lanterns"].waitForExistence(timeout: 10))
    }
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testBefore() async throws {
        try await openNote()
        XCTAssertTrue(app.buttons["Edit"].exists)
        XCTAssertTrue(app.buttons["AI Features"].exists)
        capture("before-read-only-note-offers-edits")
        app.buttons["Edit"].tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText(" test")
        for _ in 0..<40 {
            if !(try await updates()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let calls = try await updates()
        XCTAssertFalse(calls.isEmpty, "Baseline tries to save a known read-only note")
    }
    func testReadOnly() async throws {
        try await openNote()
        XCTAssertTrue(app.staticTexts["Read Only"].exists)
        for label in ["Edit", "AI Features", "Record audio", "Attach file"] {
            XCTAssertFalse(app.buttons[label].exists, label)
        }
        capture("after-read-only-light")
        app.swipeUp(); app.swipeDown()
        let calls = try await updates()
        XCTAssertTrue(calls.isEmpty)
        try await openNote(appearance: "dark")
        XCTAssertTrue(app.staticTexts["Read Only"].exists)
        capture("after-read-only-dark")
    }
    func testWriteAndLegacy() async throws {
        for mode in ["writable", "legacy"] {
            try await openNote(mode: mode)
            XCTAssertTrue(app.buttons["Edit"].exists)
            XCTAssertFalse(app.staticTexts["Read Only"].exists)
            app.buttons["Edit"].tap()
            let title = app.textFields["Title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.tap(); title.typeText(" test")
            for _ in 0..<40 {
                if !(try await updates()).isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let calls = try await updates()
            XCTAssertFalse(calls.isEmpty)
        }
    }
}
