import XCTest

@MainActor final class ToolbarConsistencyUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }

    func launch(_ appearance: String) {
        app.terminate()
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Toolbar Demo'")).firstMatch.waitForExistence(timeout: 30), "Sign in only to the loopback fixture before running")
    }

    func tap(_ name: String) {
        let element = app.buttons[name].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 8), name)
        for _ in 0..<6 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, name)
        element.tap()
    }

    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func checkEditor(_ title: String, name: String) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars.buttons["Cancel"].isHittable)
        XCTAssertTrue(app.navigationBars.buttons["Save"].exists)
        capture(name)
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars[title].exists)
    }

    func testSettingsLight() { settings("light") }
    func testSettingsDark() { settings("dark") }
    func settings(_ appearance: String) {
        launch(appearance)
        tap("Menu"); tap("More"); tap("Settings"); tap("Chat Behavior"); tap("Message Actions")
        tap("messageAction.addShortcut")
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        checkEditor("Add Shortcut Action", name: "shortcut-" + appearance)
    }

    func testWorkspaceLight() { workspace("light") }
    func testWorkspaceDark() { workspace("dark") }
    func workspace(_ appearance: String) {
        launch(appearance)
        tap("Menu"); tap("More"); tap("Workspace")
        capture("workspace-inventory-" + appearance)
        tap("New Model")
        checkEditor("New Model", name: "model-" + appearance)
    }

    func testSaveAndDiscardSemantics() {
        let actionName = "Demo Action " + UUID().uuidString.prefix(6)
        launch("light")
        tap("Menu"); tap("More"); tap("Settings"); tap("Chat Behavior"); tap("Message Actions")
        tap("messageAction.addShortcut")
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        app.textFields["shortcutAction.name"].tap()
        app.textFields["shortcutAction.name"].typeText(actionName)
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        app.textFields["shortcutAction.shortcutName"].tap()
        app.textFields["shortcutAction.shortcutName"].typeText("Demo Shortcut")
        XCTAssertTrue(app.navigationBars.buttons["Save"].isEnabled)
        app.navigationBars.buttons["Save"].tap()
        let savedAction = app.staticTexts[actionName].firstMatch
        XCTAssertTrue(savedAction.waitForExistence(timeout: 5))
        savedAction.tap()
        XCTAssertTrue(app.navigationBars["Edit Shortcut Action"].waitForExistence(timeout: 5))
        tap("Delete Action")
        XCTAssertFalse(app.navigationBars["Edit Shortcut Action"].exists)
        XCTAssertFalse(savedAction.exists)

        launch("light")
        tap("Menu"); tap("More"); tap("Workspace"); tap("New Model")
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled)
        app.textFields["e.g. AWS Chatbot"].tap()
        app.textFields["e.g. AWS Chatbot"].typeText("Demo Model")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard"].waitForExistence(timeout: 5))
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["New Model"].waitForNonExistence(timeout: 5))
    }

    func testDefaultsLight() { defaults("light") }
    func testDefaultsDark() { defaults("dark") }
    func defaults(_ appearance: String) {
        launch(appearance)
        tap("Menu"); tap("More"); tap("My Defaults")
        checkEditor("My Defaults", name: "defaults-" + appearance)
    }

    func testAdminLight() { admin("light") }
    func testAdminDark() { admin("dark") }
    func admin(_ appearance: String) {
        launch(appearance)
        tap("Menu"); tap("More"); tap("Admin Console")
        tap("person.badge.plus")
        XCTAssertTrue(app.navigationBars["Add User"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["Add"].isEnabled)
        capture("add-user-" + appearance)
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["Add User"].exists)
    }
}
