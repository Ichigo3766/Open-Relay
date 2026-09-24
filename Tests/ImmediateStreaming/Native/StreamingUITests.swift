import XCTest

final class StreamingUITests: XCTestCase {
    func setMode(_ mode: String) throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18188/fixture/control")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let ready = expectation(description: "Synthetic fixture configured")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200); ready.fulfill()
        }.resume()
        wait(for: [ready], timeout: 5)
    }
    func openFixture() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
        app.launchArguments = ["-renderAssistantMarkdown", "YES", "-openui.appearance.mode", "light"]
        app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 2) {
            let deny = system.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND label != 'Allow'")).firstMatch
            if deny.exists { deny.tap() }
        }
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.staticTexts["Connect to your OpenWebUI server"].waitForExistence(timeout: 2) {
            let server = app.textFields.firstMatch
            server.tap(); server.typeText("http://127.0.0.1:18188")
            app.buttons["Connect"].tap()
        }
        if !app.buttons["Menu"].waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["Version 0.0.0-fixture"].waitForExistence(timeout: 10))
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            let email = app.textFields.firstMatch
            XCTAssertTrue(email.waitForExistence(timeout: 5))
            email.tap(); email.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
            if app.buttons["Skip"].waitForExistence(timeout: 10) { app.buttons["Skip"].tap() }
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Model'")).firstMatch.waitForExistence(timeout: 15), "Synthetic fixture account required")
        return app
    }
    func sendNew(_ text: String, in app: XCUIApplication) {
        func newChat() -> XCUIElement? {
            app.buttons.matching(identifier: "New Chat").allElementsBoundByIndex.first(where: { $0.isHittable })
        }
        for _ in 0..<5 {
            if newChat() != nil { break }
            app.swipeDown()
        }
        guard let button = newChat() else { XCTFail("New Chat must be visible"); return }
        button.tap()
        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText(text)
        app.buttons["Send message"].tap()
    }
    func testStopThenStartAgain() throws {
        let app = try openFixture()
        for trial in 0..<3 {
            try setMode("slow-thinking")
            sendNew("Invented cancellation trial \(trial).", in: app)
            let stop = app.buttons["Stop Generating"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
            let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !stop.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)
            try setMode("plain")
            sendNew("Invented fresh-session trial \(trial).", in: app)
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.buttons["Continue response"].exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
            print("IOS_UI cancellation_and_restart trial=\(trial) passed")
        }
    }
    func testThinkingExpansion() throws {
        let app = try openFixture()
        try setMode("slow-thinking")
        sendNew("Synthetic thinking expansion trial.", in: app)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.buttons["Continue response"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 60), .completed)
        app.swipeDown(velocity: .fast)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch
        XCTAssertTrue(row.exists)
        print("IOS_UI thinking_collapsed_frame=\(row.frame)")
        let height = row.frame.height
        // The combined accessibility element hides its disclosure child. In the
        // default-scale fixture, the reasoning header follows the model/status rows.
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 70)).tap()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in row.frame.height > height + 500 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 10), .completed)
        print("IOS_UI thinking_expanded_frame=\(row.frame)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Synthetic expanded thinking"; attachment.lifetime = .keepAlways; add(attachment)
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 70)).tap()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(row.frame.height - height) < 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 10), .completed)
        print("IOS_UI thinking_expand_collapse verified")
    }
    func testSyntheticStream() throws {
        let app = try openFixture()
        for (trial, mode) in ["modern-thinking", "slow-thinking", "long-code", "mixed", "long"].enumerated() {
            try setMode(mode)
            sendNew("Describe an imaginary observatory. Synthetic trial \(trial).", in: app)
            print("IOS_UI sent trial=\(trial) mode=\(mode) wall=\(Date().timeIntervalSince1970)")
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.buttons["Continue response"].exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 60), .completed)
            print("IOS_UI completed trial=\(trial) wall=\(Date().timeIntervalSince1970)")
            for _ in 0..<3 { app.swipeDown(); app.swipeUp() }
            app.swipeDown(velocity: .fast)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Synthetic completed trial \(trial)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    /// Capture both app builds with exactly the same synthetic replay, without
    /// gestures during delivery. Trim/align on the visible "Replay running" cue.
    func testVideoComparison() throws {
        let app = try openFixture()
        for mode in ["slow-thinking", "mixed", "long"] {
            try setMode("video-" + mode)
            sendNew("Synthetic demo.", in: app)
            // Reasoning must remain active through the recovery poll, not just
            // produce a completed row after a premature fixture-driven stop.
            if mode == "slow-thinking" {
                Thread.sleep(forTimeInterval: 8)
                XCTAssertTrue(app.buttons["Stop Generating"].exists)
                Thread.sleep(forTimeInterval: 10)
            } else {
                Thread.sleep(forTimeInterval: 18)
            }
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.buttons["Continue response"].exists && !app.buttons["Stop Generating"].exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 60), .completed)
            let answer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch
            XCTAssertTrue(answer.exists)
            // The combined accessibility label is a truncated persistence
            // preview, not the rendered text; NativeTests checks that text.
            print("IOS_VIDEO completed mode=\(mode) wall=\(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: 3)
        }
    }

    func testScrollDuringStreamingAndSwitchChats() throws {
        let app = try openFixture()
        // Create an independent completed chat before the long stream.
        try setMode("plain")
        sendNew("Synthetic earlier conversation.", in: app)
        var done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.buttons["Continue response"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
        try setMode("scrolling")
        sendNew("Synthetic scrolling conversation.", in: app)
        // The combined row's label uses persisted content, not the live store.
        // NativeTests separately verifies actual rendered text during streaming.
        XCTAssertTrue(app.buttons["Stop Generating"].waitForExistence(timeout: 5))
        for _ in 0..<5 { app.swipeDown(); app.swipeUp() }
        done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.buttons["Continue response"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 60), .completed)
        for trial in 0..<6 {
            app.swipeDown(velocity: .fast)
            app.buttons["Menu"].tap()
            let title = trial % 2 == 0 ? "Synthetic plain " : "Synthetic scrolling "
            let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch.waitForExistence(timeout: 10))
            app.swipeDown(); app.swipeUp()
        }
        print("IOS_UI streaming_scroll_and_six_chat_switches verified")
    }
}
