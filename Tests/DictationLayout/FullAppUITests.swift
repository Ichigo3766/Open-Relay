import XCTest

final class FullAppUITests: XCTestCase {
    func testLongDictation() { exercise(theme: "light") }
    func testLongDictationDark() { exercise(theme: "dark") }
    func testDictationWithKeyboardOpen() { exercise(theme: "light", keyboard: true) }

    private func exercise(theme: String, keyboard: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
        app.launchArguments = ["-openui.appearance.mode", theme, "-last_active_conversation_id", "",
                               "-AppleLanguages", "(en)"]
        app.launch()
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 30))
        if keyboard {
            app.textViews.firstMatch.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        }
        mic.tap()
        let stop = app.buttons["Stop dictation"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue((input.value as? String)?.hasSuffix("END OF TRANSCRIPT.") == true)
        shot("\(theme)-01-transcript-arrived")
        for _ in 0..<6 { input.swipeUp() }
        shot("\(theme)-02-after-scrolling")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        shot("\(theme)-03-before-deleting")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        shot("\(theme)-04-after-deleting")
    }

    private func shot(_ name: String) {
        let ready = expectation(description: "Settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
