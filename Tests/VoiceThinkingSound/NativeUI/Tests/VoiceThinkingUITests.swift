import XCTest
@MainActor final class VoiceThinkingUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "org.example.voice-thinking.preview")
    override func tearDown() { app.terminate() }
    func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func setToggle(_ toggle: XCUIElement, to value: String) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
    }
    func test01SettingsOffThenOn() {
        app.launchEnvironment["RESET_VOICE_SETTINGS"] = "1"
        app.launch()
        let toggle = app.switches["Thinking Sound"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        capture("thinking-sound-default-off")
        setToggle(toggle, to: "1")
        XCTAssertEqual(toggle.value as? String, "1")
        capture("thinking-sound-enabled")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Call Mode'")).firstMatch.tap()
        app.buttons["Realtime"].tap()
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(toggle.value as? String, "1")
        capture("thinking-sound-realtime")
    }
    func test02PreferencePersists() {
        app.launch()
        let toggle = app.switches["Thinking Sound"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.value as? String == "0" { setToggle(toggle, to: "1") }
        app.terminate(); app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        setToggle(toggle, to: "0")
        app.terminate(); app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
    }
    func test03AudioPreview() {
        app.launch()
        XCTAssertTrue(app.buttons["Audio preview"].waitForExistence(timeout: 10))
        app.buttons["Audio preview"].tap()
        XCTAssertTrue(app.buttons["Thinking"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        app.buttons["Thinking"].tap()
        capture("thinking-sound-preview")
        Thread.sleep(forTimeInterval: 6)
        app.buttons["Speaking"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["Thinking"].tap()
        Thread.sleep(forTimeInterval: 3)
        app.buttons["Paused"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["Ended"].tap()
    }
}
