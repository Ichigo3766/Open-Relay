import XCTest

@MainActor final class AppUITests: XCTestCase {
    func testAuthenticatedParagraphPrefetchAndPlayerControls() async throws {
        continueAfterFailure = false
        let base = URL(string: "http://127.0.0.1:18191")!
        var reset = URLRequest(url: base.appendingPathComponent("fixture/reset"))
        reset.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
        app.launchArguments = ["-ttsEngine", "server", "-ttsResponseSplitting", "paragraphs",
                               "-last_active_conversation_id", "prefetch-demo-chat"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 20))
        let selector = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Audio Prefetch Demo'")).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 10), "Use only the loopback fixture")
        if !app.buttons["Speak"].firstMatch.exists {
            app.buttons["Menu"].tap()
            let chat = app.buttons["Audio Prefetch Demo"].firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 5))
            chat.tap()
        }
        XCTAssertTrue(app.buttons["Speak"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Speak"].firstMatch.tap()
        let close = app.buttons["Close audio player"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let preparing = app.staticTexts["Preparing…"].firstMatch
        if preparing.exists { preparing.tap() }
        else { app.staticTexts.matching(NSPredicate(format: "label MATCHES '^0:0[0-9]$'")).firstMatch.tap() }
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES '^0:0[1-9]$'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Pause"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Play"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("fixture/requests"))
        let requests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(requests.count, 3)
        let ordered = requests.sorted { ($0["index"] as! Int) < ($1["index"] as! Int) }
        XCTAssertTrue(ordered.allSatisfy { $0["authenticated"] as? Bool == true })
        XCTAssertLessThan(ordered[2]["started"] as! Double, ordered[1]["finished"] as! Double)
        XCTAssertGreaterThanOrEqual(ordered[1]["started"] as! Double, ordered[0]["finished"] as! Double)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }
}
