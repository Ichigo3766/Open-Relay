import XCTest

/// Run only on an isolated simulator connected to fixture.py.
@MainActor final class ModelEditorUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }

    func openEditor() async throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.buttons["Connect"].exists {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("http://127.0.0.1:18191")
            app.buttons["Connect"].tap()
        }
        if app.staticTexts["Version 0.0.0-model-fixture"].waitForExistence(timeout: 3) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
            if app.buttons["Skip"].waitForExistence(timeout: 3) { app.buttons["Skip"].tap() }
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Geometry Guide'")).firstMatch.waitForExistence(timeout: 15), "Synthetic fixture must be active")
        app.buttons["Menu"].tap()
        app.buttons["More"].tap()
        app.buttons["Workspace"].tap()
        XCTAssertTrue(app.navigationBars["Workspace"].waitForExistence(timeout: 10))
        let model = app.cells.staticTexts["Geometry Guide"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap()
        XCTAssertTrue(app.navigationBars["Edit Model"].waitForExistence(timeout: 10))
    }

    func captureSelections(_ name: String) {
        let skill = app.buttons["Outline Steps"]
        for _ in 0..<20 {
            if skill.exists && skill.isHittable { break }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(skill.isHittable)
        XCTAssertTrue(app.buttons["Copy Summary"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    func testBefore() async throws {
        try await openEditor()
        captureSelections("model-before")
    }

    func testSavePreservesConfiguration() async throws {
        try await openEditor()
        captureSelections("model-after")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Workspace"].waitForExistence(timeout: 15))
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let saved = try XCTUnwrap((state["saves"] as? [[String: Any]])?.last)
        let meta = try XCTUnwrap(saved["meta"] as? [String: Any])
        XCTAssertEqual(meta["actionIds"] as? [String], ["demo-action"])
        XCTAssertEqual(meta["skillIds"] as? [String], ["demo-skill"])
        XCTAssertEqual(meta["terminalId"] as? String, "demo-terminal")
        XCTAssertNotNil(meta["chat_variables_schema"])
        let params = try XCTUnwrap(saved["params"] as? [String: Any])
        XCTAssertEqual(params["custom_number"] as? Int, 4096)
        XCTAssertEqual(params["custom_flag"] as? Bool, true)
        XCTAssertEqual(params["custom_object"] as? [String: String], ["type": "json_object"])
    }
}
