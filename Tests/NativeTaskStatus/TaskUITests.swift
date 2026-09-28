import XCTest

@MainActor final class TaskUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }

    func request(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/\(path)")!)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func start() async throws {
        app.terminate()
        _ = try await request("reset", [:])
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", "light"]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.buttons["Connect"].exists {
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("http://127.0.0.1:18191")
            app.buttons["Connect"].tap()
        }
        if app.staticTexts["Version 0.0.0-task-fixture"].waitForExistence(timeout: 3) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30)); app.buttons["Menu"].tap()
        let chat = app.buttons["Synthetic task list"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
        let panel = app.buttons.matching(NSPredicate(format: "label CONTAINS '0 of 2 tasks completed'")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 15)); panel.tap()
    }

    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testBefore() async throws {
        try await start()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fold paper'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        if !app.staticTexts["In Progress"].waitForExistence(timeout: 2) { row.tap() }
        XCTAssertTrue(app.staticTexts["In Progress"].waitForExistence(timeout: 10))
        let state = try await request("state")
        XCTAssertEqual((state["tasks"] as! [[String: Any]])[0]["status"] as? String, "pending")
        XCTAssertFalse((state["writes"] as! [Any]).isEmpty)
        capture("before-unsaved-progress")
    }

    func testNativeTasks() async throws {
        try await start()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fold paper'")).firstMatch.exists)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Fold paper'")).firstMatch
        XCTAssertTrue(row.exists); row.tap(); row.tap()
        XCTAssertTrue(app.staticTexts["0 of 2 tasks completed"].exists)
        let state = try await request("state")
        XCTAssertTrue((state["writes"] as! [Any]).isEmpty)
        capture("after-read-only-progress")
        _ = try await request("tasks", ["tasks": [["id": "paper", "content": "Fold paper", "status": "completed"], ["id": "sky", "content": "Color the paper sky", "status": "pending"]]])
        XCTAssertTrue(app.staticTexts["1 of 2 tasks completed"].waitForExistence(timeout: 10))
        capture("after-server-update")
        let input = app.textViews.firstMatch
        input.tap(); input.typeText("Start synthetic task."); app.buttons["Send message"].tap()
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Fold paper' AND value == 'in progress'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        _ = try await request("finish", [:])
        _ = try await request("tasks", ["tasks": []])
        XCTAssertTrue(app.staticTexts["0 of 2 tasks completed"].waitForNonExistence(timeout: 10))
    }
}
