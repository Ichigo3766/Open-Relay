import XCTest

final class RecoveryUITests: XCTestCase {
    func testMenuDoesNotCoverRecoveryBar() {
        let app = XCUIApplication()
        app.launch()
        if !app.buttons["Retry transcription"].exists {
            app.buttons["Record synthetic audio"].tap()
            app.buttons["Stop dictation"].tap()
        }
        XCTAssertTrue(app.buttons["Retry transcription"].waitForExistence(timeout: 8))
        let barTop = app.otherElements["dictation-recovery-bar"].frame.minY
        app.buttons["Recording recovery options"].tap()
        capture("menu-position")
        assertMenuAboveBar(app, top: barTop)
        app.buttons["Discard Recording"].tap()
    }

    func testFailureMenuRetryAndRestoredDraft() {
        recoveryFlow(light: false)
    }

    func testLightModeRecovery() {
        recoveryFlow(light: true)
    }

    private func recoveryFlow(light: Bool) {
        let app = XCUIApplication()
        if light { app.launchArguments = ["--light-mode"] }
        app.launch()
        if app.buttons["Recording recovery options"].exists {
            app.buttons["Recording recovery options"].tap()
            app.buttons["Discard Recording"].tap()
        }
        app.buttons["Record synthetic audio"].tap()
        capture("recording")
        app.buttons["Stop dictation"].tap()
        capture("processing")
        XCTAssertTrue(app.buttons["Retry transcription"].waitForExistence(timeout: 8))
        capture("failed")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Retry transcription"].waitForExistence(timeout: 5))
        capture("recovered-after-relaunch")
        let barTop = app.otherElements["dictation-recovery-bar"].frame.minY
        app.buttons["Recording recovery options"].tap()
        capture("recovery-menu")
        XCTAssertTrue(app.buttons["Save / Share Audio…"].exists)
        XCTAssertTrue(app.buttons["Transcribe on Device"].exists)
        assertMenuAboveBar(app, top: barTop)
        app.buttons["Save / Share Audio…"].tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 15))
        capture("export")
        let dismiss = app.buttons["Close"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dismiss)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["Retry transcription"].exists, "Cancelled export must preserve recovery")
        app.buttons["Recording recovery options"].tap()
        app.buttons["Transcribe on Device"].tap()
        XCTAssertTrue(app.buttons["Retry transcription"].waitForExistence(timeout: 8))
        app.buttons["Retry transcription"].tap()
        capture("retrying")
        XCTAssertTrue(app.staticTexts["draft"].waitForExistence(timeout: 5))
        let delivered = NSPredicate(format: "label CONTAINS %@", "Fold the paper kite")
        expectation(for: delivered, evaluatedWith: app.staticTexts["draft"])
        waitForExpectations(timeout: 8)
        capture("success")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["draft"].label.contains("Fold the paper kite"))
        XCTAssertFalse(app.buttons["Retry transcription"].exists)
    }

    func testLargeTypeRecoveryLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--large-type"]
        app.launch()
        if app.buttons["Recording recovery options"].exists {
            app.buttons["Recording recovery options"].tap()
            app.buttons["Discard Recording"].tap()
        }
        app.buttons["Record synthetic audio"].tap()
        app.buttons["Stop dictation"].tap()
        XCTAssertTrue(app.buttons["Retry transcription"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Retry transcription"].isHittable)
        XCTAssertTrue(app.buttons["Recording recovery options"].isHittable)
        capture("large-type-recovery")
        let barTop = app.otherElements["dictation-recovery-bar"].frame.minY
        app.buttons["Recording recovery options"].tap()
        capture("large-type-menu")
        assertMenuAboveBar(app, top: barTop)
        app.buttons["Discard Recording"].tap()
        XCTAssertTrue(app.buttons["Record synthetic audio"].isEnabled)
    }

    private func assertMenuAboveBar(_ app: XCUIApplication, top: CGFloat) {
        for title in ["Save / Share Audio…", "Transcribe on Device", "Discard Recording"] {
            XCTAssertLessThan(app.buttons[title].frame.maxY, top,
                              "The native menu must not cover the recovery bar")
        }
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.5) // Let native presentation animations settle for evidence.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
