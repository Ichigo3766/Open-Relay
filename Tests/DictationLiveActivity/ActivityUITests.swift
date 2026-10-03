import XCTest

final class ActivityUITests: XCTestCase {
    @MainActor private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func showActivity(_ system: XCUIApplication) {
        let top = system.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01))
        top.press(forDuration: 0.1, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8)))
        for title in ["Always Allow", "Allow"] {
            if system.buttons[title].waitForExistence(timeout: 2) { system.buttons[title].tap() }
        }
    }

    @MainActor private func returnToApp(_ app: XCUIApplication, _ system: XCUIApplication) {
        let label = system.staticTexts["Microphone dictation"].exists ? "Microphone dictation" : "Open Open Relay to check"
        system.staticTexts[label].tap()
        app.activate()
        sleep(1)
    }

    @MainActor func testNativeActivity() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["Start five-minute sample"].tap()
        XCTAssertTrue(app.staticTexts["Sample active"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        sleep(2)
        capture("Dynamic Island — recording")
        // Opening Notification Center exposes the actual system-rendered activity.
        showActivity(system)
        sleep(3)
        capture("Lock screen — recording")
        XCTAssertTrue(system.staticTexts["Microphone dictation"].waitForExistence(timeout: 10), system.debugDescription)
        let timer = system.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[3-5]:[0-9]{2}")).firstMatch
        XCTAssertTrue(timer.exists, "Native timer must be visible")
        let firstTime = timer.label
        sleep(3)
        XCTAssertNotEqual(timer.label, firstTime, "Native timer must advance without app updates")
        returnToApp(app, system)
        app.buttons["Make sample stale"].tap()
        XCTAssertTrue(app.staticTexts["Stale sample scheduled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Updated activities: 1"].exists, app.debugDescription)
        XCUIDevice.shared.press(.home)
        showActivity(system)
        // iOS controls when isStale redraws; the timer itself must stop at the deadline.
        XCTAssertTrue(timer.waitForExistence(timeout: 10))
        capture("Lock screen — expired liveness timer")
        let pausedTime = timer.label
        sleep(3)
        XCTAssertEqual(timer.label, pausedTime, "Stale activity must not keep counting")
        returnToApp(app, system)
        app.buttons["Stop sample"].tap()
        XCTAssertTrue(app.staticTexts["Sample stopped"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        showActivity(system)
        XCTAssertFalse(system.staticTexts["Open Open Relay to check"].exists)
        XCTAssertFalse(system.staticTexts["Microphone dictation"].exists)
    }
}
