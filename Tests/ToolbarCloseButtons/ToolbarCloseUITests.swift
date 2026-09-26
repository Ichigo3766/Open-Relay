import XCTest

/// A disposable simulator with only the loopback fixture, never a real library.
final class ToolbarCloseUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    private let screens = ["archived", "shared", "notes", "automations", "memories",
                           "workspace", "channels", "channel-members", "dm-settings", "pinned-messages",
                           "account-picker", "admin", "edit-user", "user-chats", "integration-access",
                           "voice-settings", "voice-note", "prompt-history", "app-update", "combined-update",
                           "server-switcher", "server-sheet", "ipad-admin", "ipad-memories", "ipad-notes"]
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLight() { captureSheets("light", range: 0..<22) }
    func testDark() { captureSheets("dark", range: 0..<22) }
    func testTabletLight() { captureSheets("light", range: 22..<25) }
    func testTabletDark() { captureSheets("dark", range: 22..<25) }

    private func launch(_ appearance: String, start: Int = 0) {
        app.launchArguments = ["--close-gallery", "-close-gallery-start", String(start),
                               "-openui.appearance.mode", appearance,
                               "-last_active_conversation_id", ""]
        app.launch()
        XCTAssertTrue(app.buttons["Open next sheet"].waitForExistence(timeout: 30))
    }

    private func captureSheets(_ appearance: String, range: Range<Int>) {
        launch(appearance, start: range.lowerBound)
        for index in range {
            XCTAssertEqual(app.staticTexts["gallery-screen"].label, screens[index])
            app.buttons["Open next sheet"].tap()
            let close = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 15), screens[index])
            XCTAssertTrue(close.isHittable, screens[index])
            settle()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(appearance)-\(screens[index])"
            shot.lifetime = .keepAlways
            add(shot)
            close.tap()
            XCTAssertTrue(app.buttons["Open next sheet"].waitForExistence(timeout: 10), screens[index])
            XCTAssertTrue(app.buttons["Open next sheet"].isHittable, screens[index])
        }
    }

    func testRealSidebarDismissal() {
        launch("dark")
        app.buttons["Open app sidebar"].tap()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 15))
        for title in ["Archived Chats", "Shared Chats", "Notes", "Automations", "Memories", "Workspace", "Admin Console"] {
            if !app.buttons["Server Settings"].isHittable { app.buttons["Menu"].tap() }
            let menus = app.buttons.matching(identifier: "More")
            XCTAssertGreaterThanOrEqual(menus.count, 2)
            let menu = title.contains("Chats") ? menus.element(boundBy: 0) : menus.element(boundBy: menus.count - 1)
            menu.tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
            app.buttons[title].tap()
            let close = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 15))
            close.tap()
            XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        }
    }

    private func settle() {
        let settled = expectation(description: "Sheet settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }
}
