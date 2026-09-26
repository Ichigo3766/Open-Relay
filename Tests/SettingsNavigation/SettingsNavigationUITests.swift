import XCTest

/// Run only against prepare_qa.py's synthetic-only app copy.
final class SettingsNavigationUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBeforeLight() { capture("light", baseline: true) }
    func testBeforeDark() { capture("dark", baseline: true) }
    func testAfterLight() { capture("light", baseline: false) }
    func testAfterDark() { capture("dark", baseline: false) }

    // The identical sequence on both builds provides real-time video evidence.
    func testDemo() {
        launch("dark", language: "en-GB")
        print("SETTINGS_VIDEO_READY")
        let recording = expectation(description: "Start simulator recording after launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { recording.fulfill() }
        wait(for: [recording], timeout: 12)
        open("Default Model")
        XCTAssertTrue(app.buttons["Calm"].waitForExistence(timeout: 10))
        app.buttons["Orbit"].tap()
        shot("demo-model")
        back("Default Model")
        open("Language")
        shot("demo-language")
        app.swipeUp()
        app.swipeDown()
        back("Language")
    }

    private func launch(_ theme: String = "light", language: String? = nil, preserveLanguage: Bool = false) {
        _ = request("/qa/reset", method: "POST")
        app.launchArguments = ["-openui.appearance.mode", theme, "-last_active_conversation_id", "",
                               "-AppleLanguages", "(en)"]
        if let language { app.launchArguments += ["--qa-language", language] }
        if preserveLanguage { app.launchArguments += ["--qa-preserve-language"] }
        app.launch()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 30))
        app.buttons["Open Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    private func open(_ title: String) {
        let button = app.buttons[title]
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, title)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in button.isEnabled }, object: nil)], timeout: 15), .completed)
        button.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }

    private func back(_ title: String) {
        app.navigationBars[title].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    private func capture(_ theme: String, baseline: Bool) {
        launch(theme, language: "en-GB")
        open("Appearance")
        shot("\(theme)-appearance")
        back("Appearance")
        open("Default Model")
        XCTAssertTrue(app.buttons["Calm"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.navigationBars["Default Model"].buttons["Cancel"].exists, baseline)
        app.buttons["Orbit"].tap()
        shot("\(theme)-default-model")
        back("Default Model")
        open("Language")
        XCTAssertEqual(app.navigationBars["Language"].buttons["Cancel"].exists, baseline)
        shot("\(theme)-language")
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("English")
        shot("\(theme)-language-search")
        closeSearch()
        back("Language")
        app.navigationBars["Settings"].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Open Settings"].isHittable)
    }

    func testModelSaveAndDiscard() {
        launch()
        open("Default Model")
        XCTAssertTrue(app.buttons["Calm"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Calm"].isSelected)
        app.buttons["Orbit"].tap()
        back("Default Model")
        XCTAssertEqual(request("/qa/state")["writes"] as? Int, 0)
        open("Default Model")
        XCTAssertTrue(app.buttons["Calm"].isSelected)
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("orbit")
        XCTAssertFalse(app.buttons["Calm"].exists)
        app.buttons["Orbit"].tap()
        closeSearch()
        app.navigationBars["Default Model"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        open("Default Model")
        XCTAssertTrue(app.buttons["Orbit"].isSelected)
        let state = request("/qa/state")
        XCTAssertEqual(state["writes"] as? Int, 1)
        let ui = (state["settings"] as? [String: Any])?["ui"] as? [String: Any]
        XCTAssertEqual(ui?["models"] as? [String], ["demo-orbit"])
        XCTAssertEqual(ui?["memory"] as? Bool, true)
        XCTAssertEqual(ui?["pinnedModels"] as? [String], ["demo-vision"])
    }

    func testLanguageSelectionAndCancel() {
        for code in [nil, "en", "en-GB", "pt-BR"] as [String?] {
            launch(language: code)
            open("Language")
            let search = app.searchFields.firstMatch
            search.tap()
            search.typeText(code == "pt-BR" ? "Portuguese" : "English")
            let selected = app.cells.buttons.allElementsBoundByIndex.filter { $0.isSelected }
            XCTAssertEqual(selected.count, 1, code ?? "system")
            let label = selected.first?.label ?? ""
            XCTAssertTrue(label.contains(code == nil ? "System Default" : code == "pt-BR" ? "Brasil" : code == "en-GB" ? "UK" : "English"))
            if code == "en" { XCTAssertFalse(label.contains("UK")) }
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "System Default")).firstMatch.tap()
            XCTAssertTrue(app.alerts["Restart Required"].waitForExistence(timeout: 5))
            app.alerts.buttons["Later"].tap()
            XCTAssertEqual(app.cells.buttons.allElementsBoundByIndex.filter { $0.isSelected }.first?.label, label)
            closeSearch()
            XCTAssertTrue(app.navigationBars["Language"].exists)
        }
    }

    func testBackAndDismissGestures() {
        for title in ["Default Model", "Language", "Appearance", "Accessibility"] {
            launch()
            open(title)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), title)
            open(title)
            app.navigationBars[title].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5), title)
            XCTAssertTrue(app.buttons["Open Settings"].isHittable, title)
        }
    }

    func testLanguageApplyAndReset() {
        launch()
        open("Language")
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("English")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "English (UK)")).firstMatch.tap()
        app.alerts.buttons["Restart Now"].tap()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        launch(preserveLanguage: true)
        open("Language")
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("English")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "English (UK)")).firstMatch.isSelected)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "System Default")).firstMatch.tap()
        app.alerts.buttons["Restart Now"].tap()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        launch(preserveLanguage: true)
        open("Language")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "System Default")).firstMatch.isSelected)
    }

    private func shot(_ name: String) {
        let settled = expectation(description: "Presentation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func closeSearch() {
        // The native search close control uses this label on the current SDK.
        let close = app.buttons.matching(NSPredicate(format: "label == %@", "close")).firstMatch
        if close.isHittable { close.tap() } else { app.buttons["Cancel"].tap() }
    }

    private func request(_ path: String, method: String = "GET") -> [String: Any] {
        let done = expectation(description: path)
        var value: [String: Any] = [:]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18193" + path)!)
        request.httpMethod = method
        URLSession.shared.dataTask(with: request) { data, _, error in
            XCTAssertNil(error)
            if let data { value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return value
    }
}
