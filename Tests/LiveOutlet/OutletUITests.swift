import XCTest

@MainActor final class OutletUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/" + path)!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
    }
    func text(_ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }
    func start(reset: Bool = true) async throws {
        app.terminate()
        if reset { try await post("reset") }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30), "Connect only to the synthetic fixture first")
        app.buttons["Menu"].tap()
        let chat = app.buttons["Synthetic paper colors"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testBefore() async throws {
        try await start()
        XCTAssertTrue(text("Use red paper.").waitForExistence(timeout: 10))
        try await post("correct")
        XCTAssertFalse(text("Use tan paper.").waitForExistence(timeout: 4))
        XCTAssertTrue(text("Use red paper.").exists)
        capture("before-outlet-ignored")
        try await start(reset: false)
        XCTAssertTrue(text("Use red paper.").waitForExistence(timeout: 10))
    }
    func testOutlet() async throws {
        try await start()
        XCTAssertTrue(text("Use red paper.").waitForExistence(timeout: 10))
        try await post("correct")
        XCTAssertTrue(text("Use tan paper.").waitForExistence(timeout: 10))
        XCTAssertFalse(text("Use red paper.").exists)
        capture("after-outlet-corrected")
        try await post("wrong-chat")
        XCTAssertFalse(text("Wrong chat correction.").waitForExistence(timeout: 2))
        try await start(reset: false)
        XCTAssertTrue(text("Use tan paper.").waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        input.tap(); input.typeText("Plan another paper craft."); app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Stop Generating"].waitForExistence(timeout: 10))
        try await post("finish")
        XCTAssertTrue(text("The corrected craft uses blue paper.").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Stop Generating"].waitForNonExistence(timeout: 10))
        capture("after-outlet-finishing-tail")
        try await post("correct", ["text": "The final craft uses gold paper."])
        XCTAssertTrue(text("The final craft uses gold paper.").waitForExistence(timeout: 10))
        try await start(reset: false)
        XCTAssertTrue(text("The final craft uses gold paper.").waitForExistence(timeout: 10))
    }
}
