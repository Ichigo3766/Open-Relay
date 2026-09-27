import XCTest

/// Run only against fixture.py in a disposable, synthetic-only simulator.
final class SidebarHeaderUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-last_active_conversation_id", ""]
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var newChat: XCUIElement {
        app.buttons.matching(identifier: "New Chat").allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY }!
    }

    func testHeaderAlignment() {
        app.open(URL(string: "openui://chat/synthetic-sidebar")!)
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        let model = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo Model'")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 20))
        capture("chat-header")
        let centerY = menu.frame.midY
        XCTAssertEqual(newChat.frame.midY, centerY, accuracy: 1)
        XCTAssertEqual(model.frame.midY, centerY, accuracy: 1)

        for iteration in 0..<3 {
            menu.tap()
            let search = app.buttons["Search library"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.5)
            if iteration == 0 { capture("sidebar-header") }
            for name in ["Server Settings", "Chat actions", "Search library"] {
                let button = app.buttons[name]
                XCTAssertTrue(button.isHittable)
                print("Header alignment: \(name), chat center=\(centerY), sidebar center=\(button.frame.midY)")
                XCTAssertEqual(button.frame.midY, centerY, accuracy: 1, "\(name) must align with the chat header")
            }
            // The exposed page dismisses the drawer without selecting a chat.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertTrue(menu.isHittable)
            XCTAssertFalse(search.isHittable)
            XCTAssertEqual(menu.frame.midY, centerY, accuracy: 1)
        }

        menu.tap()
        app.buttons["Chat actions"].tap()
        XCTAssertTrue(app.buttons["Archived Chats"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        app.buttons["Search library"].tap()
        XCTAssertTrue(app.textFields["library-search-field"].waitForExistence(timeout: 5))
        app.buttons["Close search"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        newChat.tap()
        XCTAssertEqual(menu.frame.midY, centerY, accuracy: 1)
        menu.tap()
        let search = app.buttons["Search library"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.frame.midY, centerY, accuracy: 1)
        capture("new-chat-sidebar")
    }
}
