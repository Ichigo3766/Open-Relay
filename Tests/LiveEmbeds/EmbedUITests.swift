import XCTest

@MainActor final class EmbedUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }
    func start(reset: Bool = true) async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30), "Connect only to the synthetic fixture first")
        app.buttons["Menu"].tap()
        let chat = app.buttons["Synthetic embed preview"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'The preview appears below.'")).firstMatch.waitForExistence(timeout: 10))
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func heading(_ text: String) -> XCUIElement { app.webViews.staticTexts[text].firstMatch }
    func testBefore() async throws {
        try await start()
        try await post("embed")
        XCTAssertFalse(heading("Paper star preview").waitForExistence(timeout: 4))
        capture("before-live-embed-ignored")
    }
    func testEmbeds() async throws {
        try await start()
        try await post("embed")
        XCTAssertTrue(heading("Paper star preview").waitForExistence(timeout: 10))
        capture("after-live-embed")
        try await post("embed", ["type": "embeds", "title": "Paper moon preview"])
        XCTAssertTrue(heading("Paper moon preview").waitForExistence(timeout: 10))
        XCTAssertFalse(heading("Paper star preview").exists)
        try await start(reset: false)
        XCTAssertTrue(heading("Paper moon preview").waitForExistence(timeout: 10))
        try await post("embed", ["clear": true])
        XCTAssertTrue(heading("Paper moon preview").waitForNonExistence(timeout: 10))
        let input = app.textViews.firstMatch
        input.tap(); input.typeText("Show another synthetic preview."); app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Stop Generating"].waitForExistence(timeout: 10))
        try await post("embed", ["title": "Live craft preview"])
        XCTAssertTrue(heading("Live craft preview").waitForExistence(timeout: 10))
        try await post("finish")
        XCTAssertTrue(app.buttons["Stop Generating"].waitForNonExistence(timeout: 10))
        try await post("embed", ["title": "Finished craft preview"])
        // This event targets the just-completed message, after streaming teardown.
        XCTAssertTrue(heading("Finished craft preview").waitForExistence(timeout: 10))
    }
}
