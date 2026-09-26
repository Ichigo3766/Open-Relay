import XCTest

/// Requires prepare_qa.py's app copy on a synthetic-only simulator.
final class NewChatSuggestionsUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    private var toggle: XCUIElement { app.switches["Show New Chat Suggestions"] }
    private let titles = ["Paper garden", "Cloud shapes", "Puzzle time", "Star map"]
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBeforeLight() { baseline("light") }
    func testBeforeDark() { baseline("dark") }
    func testAfterLight() { exercise("light", source: "admin") }
    func testAfterDark() { exercise("dark", source: "model") }

    private func launch(_ theme: String, settings: Bool = false, reset: Bool = false) {
        app.launchArguments = ["-openui.appearance.mode", theme, "-last_active_conversation_id", "",
                               "-AppleLanguages", "(en)"]
        if settings { app.launchArguments.append("--qa-settings") }
        if reset { app.launchArguments.append("--qa-reset") }
        app.launch()
        if settings {
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
            let behavior = app.buttons["Chat Behavior"]
            for _ in 0..<4 where !behavior.isHittable { app.swipeUp() }
            behavior.tap()
            XCTAssertTrue(app.navigationBars["Chat Settings"].waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 30))
        }
    }

    private func baseline(_ theme: String) {
        resetServer("admin")
        launch(theme, reset: true)
        assertCards(true)
        shot("\(theme)-before-chat")
        launch(theme, settings: true)
        XCTAssertFalse(toggle.exists)
        shot("\(theme)-before-settings")
    }

    private func exercise(_ theme: String, source: String) {
        resetServer(source)
        launch(theme, reset: true)
        assertCards(true)
        launch(theme, settings: true)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        setSuggestions(false)
        shot("\(theme)-after-settings")
        closeSettings()
        assertCards(false)
        shot("\(theme)-after-chat")

        // Must survive a real app termination/relaunch, not launch-argument defaults.
        launch(theme)
        assertCards(false)
        let newChat = app.buttons.matching(NSPredicate(format: "label == 'New Chat'"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(newChat)
        newChat?.tap()
        assertCards(false)
        launch(theme, settings: true)
        XCTAssertEqual(toggle.value as? String, "0")
        setSuggestions(true)
        closeSettings()
        assertCards(true)
        XCTAssertEqual(state()["writes"] as? Int, 0, "Hiding local cards must not change the server or create a chat")
    }

    func testNoServerSuggestions() {
        resetServer("none")
        launch("light", reset: true)
        assertCards(false)
        launch("light", settings: true)
        setSuggestions(false)
        closeSettings()
        assertCards(false)
    }

    func testHiddenOnFirstRender() {
        resetServer("model")
        launch("dark", settings: true, reset: true)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setSuggestions(false)
        app.terminate()
        launch("dark")
        assertCards(false)
    }

    private func closeSettings() {
        app.navigationBars["Chat Settings"].buttons.firstMatch.tap()
        app.navigationBars["Settings"].buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 10))
    }

    private func setSuggestions(_ enabled: Bool) {
        // SwiftUI exposes the full row as a switch; tap its trailing control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.toggle.value as? String == (enabled ? "1" : "0") },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func assertCards(_ shown: Bool) {
        for title in titles {
            let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in card.exists == shown }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, title)
        }
        XCTAssertTrue(app.staticTexts["How can I help?"].exists)
    }

    private func shot(_ name: String) {
        let settled = expectation(description: "Settle transition")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func resetServer(_ source: String) {
        _ = request("/qa/reset", body: ["source": source])
    }
    private func state() -> [String: Any] { request("/qa/state") }
    private func request(_ path: String, body: [String: Any]? = nil) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18194" + path)!)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try! JSONSerialization.data(withJSONObject: body)
        }
        let done = expectation(description: path)
        var result: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, _, error in
            XCTAssertNil(error)
            result = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }
}
