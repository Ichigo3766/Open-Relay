import XCTest

@MainActor final class PDFUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func start() async throws {
        app.terminate()
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30), "Connect only to the synthetic fixture first")
        app.buttons["Menu"].tap()
        let chat = app.buttons["Paper craft guide"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.press(forDuration: 1.2)
        app.buttons["Download"].tap()
        XCTAssertTrue(app.buttons["PDF document (.pdf)"].waitForExistence(timeout: 5))
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/reset")!)
        app.buttons["PDF document (.pdf)"].tap()
    }
    func requests() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return (try JSONSerialization.jsonObject(with: data) as! [String: [String]])["requests"]!
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testBefore() async throws {
        try await start()
        XCTAssertTrue(app.alerts["Export Failed"].waitForExistence(timeout: 15))
        capture("before-pdf-export-fails")
        let paths = try await requests()
        XCTAssertTrue(paths.contains("POST /api/v1/utils/pdf"))
        XCTAssertEqual(paths.filter { $0 == "GET /api/v1/chats/synthetic-pdf" }.count, 2)
    }
    func testExport() async throws {
        try await start()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["Export Failed"].exists)
        capture("after-pdf-share")
        let paths = try await requests()
        XCTAssertFalse(paths.contains("POST /api/v1/utils/pdf"))
        XCTAssertEqual(paths.filter { $0 == "GET /api/v1/chats/synthetic-pdf" }.count, 1)
        XCTAssertFalse(paths.contains { $0.contains("/files/") })
        app.cells["Markup"].tap()
        XCTAssertTrue(app.staticTexts["Paper craft guide"].waitForExistence(timeout: 10))
        capture("after-pdf-preview")
    }
}
