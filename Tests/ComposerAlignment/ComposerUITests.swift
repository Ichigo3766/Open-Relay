import XCTest

/// Run only in a disposable simulator signed in to the loopback fixture.
final class ComposerUITests: XCTestCase {
    let relay = XCUIApplication(bundleIdentifier: "com.openui.openui")
    let draft = "Cut the paper.\nFold the corners.\nAdd yellow stars.\nAttach a blue handle."
    var controlScale: CGFloat { name.contains("LargeUI") ? 1.3 : name.contains("SmallUI") ? 0.85 : 1 }

    override func setUpWithError() throws {
        continueAfterFailure = false
        UserDefaults.standard.set(true, forKey: "DisableDiagnosticScreenRecordings")
        XCUIDevice.shared.orientation = .portrait
        relay.launchArguments = ["-sendOnEnter", "NO", "-quickPills", "",
                                 "-openui.accessibility.uiScale", "\(controlScale)",
                                 "-openui.appearance.mode", name.contains("Dark") ? "dark" : "light"]
        relay.launch()
        if !relay.buttons["Menu"].waitForExistence(timeout: 3) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = springboard.buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 2) { deny.tap() }
            if relay.buttons["Connect"].exists {
                relay.textFields.firstMatch.tap()
                relay.textFields.firstMatch.typeText("http://127.0.0.1:18087")
                relay.buttons["Connect"].tap()
            }
            let email = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch
            if email.waitForExistence(timeout: 10) { email.tap() }
            if relay.buttons["Sign in"].exists {
                Thread.sleep(forTimeInterval: 2)
                relay.textFields.firstMatch.tap()
                relay.textFields.firstMatch.typeText("demo@example.test")
                relay.secureTextFields.firstMatch.tap()
                relay.secureTextFields.firstMatch.typeText("synthetic")
                relay.buttons["Sign in"].tap()
                if relay.buttons["Skip"].waitForExistence(timeout: 10) { relay.buttons["Skip"].tap() }
            }
        }
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 30))
        relay.open(URL(string: "openui://chat/02d642ed-d5ee-4270-b8f1-e4f271987f90")!)
        let fixtureAnswer = relay.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Assistant:' AND label CONTAINS %@",
            "Make a paper lantern with a blue handle and yellow stars.")).firstMatch
        XCTAssertTrue(fixtureAnswer.waitForExistence(timeout: 15), "Only run against the invented fixture conversation")
    }

    var editor: XCUIElement { relay.textViews.firstMatch }

    func enter(_ text: String) {
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        if !relay.keyboards.firstMatch.waitForExistence(timeout: 3) { editor.tap() }
        XCTAssertTrue(relay.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText(text)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(editor.value as? String, text)
    }

    func capture(_ suffix: String) {
        let attachment = XCTAttachment(screenshot: relay.screenshot())
        attachment.name = (name.contains("Dark") ? "dark-" : "light-") + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertTwoRows(trailing: String = "Send message", file: StaticString = #filePath, line: UInt = #line) {
        let plus = relay.buttons["Attachments & tools"]
        let last = relay.buttons[trailing]
        // Compare visible edges: the bare plus glyph is about 12 points wide,
        // inside its 28-point container; the trailing circle is 26 points wide.
        XCTAssertEqual(editor.frame.minX, plus.frame.midX - 6 * controlScale, accuracy: 1, file: file, line: line)
        XCTAssertEqual(editor.frame.maxX, last.frame.midX + 13 * controlScale, accuracy: 1, file: file, line: line)
        XCTAssertEqual(plus.frame.midX - 6 * controlScale,
                       relay.frame.width - last.frame.midX - 13 * controlScale,
                       accuracy: 1, "Visible left and right insets should match", file: file, line: line)
        let labels = ["Attachments & tools", "Start dictation", trailing]
        for label in labels {
            let button = relay.buttons[label]
            XCTAssertTrue(button.exists, file: file, line: line)
            XCTAssertTrue(button.isHittable, file: file, line: line)
            // iOS 18 exposes the clear buttons' glyph bounds, while iOS 26
            // exposes their full circular containers. Both share the same center.
            let diameter: CGFloat = (label == "Attachments & tools" ? 28 : 26) * controlScale
            let controlTop = button.frame.midY - diameter / 2
            XCTAssertGreaterThanOrEqual(controlTop, editor.frame.maxY + 6,
                                        "\(label) should be below the text", file: file, line: line)
            XCTAssertEqual(button.frame.midY, plus.frame.midY, accuracy: 2,
                           "Controls should share one row", file: file, line: line)
        }
    }

    func testLightMultilineUsesSeparateRows() {
        enter(draft)
        capture("multiline")
        assertTwoRows()
    }

    func testDarkMultilineUsesSeparateRows() {
        enter(draft)
        capture("multiline")
        assertTwoRows()
    }

    func testLongScrollableDraftKeepsControlsBelowText() {
        enter(Array(repeating: "Fold a paper lantern.", count: 14).joined(separator: "\n"))
        assertTwoRows()
        let before = relay.buttons["Send message"].frame
        editor.swipeDown()
        assertTwoRows()
        XCTAssertEqual(relay.buttons["Send message"].frame.minY, before.minY, accuracy: 2)
    }

    func testWrappedDraftUsesFullWidth() {
        enter("Fold a sheet of blue paper into a lantern, decorate its sides with yellow stars, and attach a small handle so it can hang beside the window.")
        XCTAssertGreaterThan(editor.frame.height, 40)
        assertTwoRows()
    }

    func testMultilineWhitespaceKeepsVoiceBelowText() {
        enter("\n\n\n")
        XCTAssertFalse(relay.buttons["Send message"].exists)
        assertTwoRows(trailing: "Voice call")
    }

    func testSingleLineAndEmptyControlsRemainUsable() {
        let voice = relay.buttons["Voice call"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        assertTwoRows(trailing: "Voice call")
        capture("empty")
        enter("One paper lantern.")
        capture("single-line")
        XCTAssertTrue(relay.buttons["Send message"].isHittable)
        assertTwoRows()
        XCTAssertFalse(relay.buttons["Voice call"].exists)
    }

    func testDarkSingleLineUsesSeparateRows() {
        enter("One paper lantern.")
        capture("single-line")
        assertTwoRows()
    }

    func testLargeUIControlsRemainUsable() {
        enter("One paper lantern.")
        assertTwoRows()
    }

    func testSmallUIControlsRemainUsable() {
        enter("One paper lantern.")
        assertTwoRows()
    }

    func testExpandedComposerKeepsControlsBelowText() {
        enter(draft)
        let collapsedText = editor.frame
        let collapsedControls = relay.buttons["Send message"].frame
        let top = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -4))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: -150)))
        Thread.sleep(forTimeInterval: 0.5)
        // The text keeps its intrinsic height within the taller composer frame.
        XCTAssertLessThan(editor.frame.minY, collapsedText.minY - 100)
        capture("expanded")
        assertTwoRows()
        XCTAssertEqual(relay.buttons["Send message"].frame.midY, collapsedControls.midY, accuracy: 2)
    }
}
