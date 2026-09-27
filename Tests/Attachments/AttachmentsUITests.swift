import XCTest

/// Only use with fixture.py and a disposable simulator connected to its loopback server.
final class AttachmentsUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    let base = "http://127.0.0.1:18191"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-last_active_conversation_id", ""]
        app.launch()
    }
    @discardableResult private func get(_ path: String) -> [String: Any] {
        let done = expectation(description: path)
        var result: [String: Any] = [:]
        URLSession.shared.dataTask(with: URL(string: base + path)!) { data, _, error in
            XCTAssertNil(error)
            if let data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }
    private func open(_ id: String) {
        app.open(URL(string: "openui://chat/" + id)!)
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 20))
        capture("opened-chat")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'fictional garden layouts' OR value CONTAINS 'fictional garden layouts'")).firstMatch.waitForExistence(timeout: 20))
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    private func send() {
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Summarize it more briefly.")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Context received' OR label CONTAINS 'No attachment context' OR value CONTAINS 'Context received' OR value CONTAINS 'No attachment context'")).firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1)
    }
    private func latestReferences() -> [[String: Any]] {
        let requests = get("/fixture/state")["requests"] as! [[String: Any]]
        let body = requests.last(where: { $0["path"] as? String == "/api/chat/completions" })!["body"] as! [String: Any]
        return body["files"] as? [[String: Any]] ?? []
    }
    func testBeforeFollowUp() {
        get("/fixture/reset")
        open("synthetic-context")
        get("/fixture/recording?state=start")
        Thread.sleep(forTimeInterval: 2)
        send()
        capture("before-context")
        XCTAssertNil(latestReferences().first?["context"])
        Thread.sleep(forTimeInterval: 2)
        get("/fixture/recording?state=stop")
    }
    func testAfterFollowUp() {
        get("/fixture/reset")
        open("synthetic-context")
        get("/fixture/recording?state=start")
        Thread.sleep(forTimeInterval: 2)
        send()
        capture("after-context")
        XCTAssertEqual(latestReferences().first?["context"] as? String, "full")
        XCTAssertNotNil(latestReferences().first?["file"])
        Thread.sleep(forTimeInterval: 2)
        get("/fixture/recording?state=stop")
    }
    func testRemovalAfterRelaunch() {
        get("/fixture/reset")
        open("synthetic-removal")
        app.buttons["More chat actions"].tap()
        app.buttons["Chat Settings"].tap()
        let row = app.cells.containing(.staticText, identifier: "Sample document 01.txt").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No files or knowledge attached"].waitForExistence(timeout: 5))
        capture("removed-context")
        app.buttons["Cancel"].tap()
        let state = get("/fixture/state")
        let chat = (state["chats"] as! [String: [String: Any]])["synthetic-removal"]!["chat"] as! [String: Any]
        XCTAssertEqual((chat["files"] as! [Any]).count, 0)
        app.terminate()
        app.launch()
        open("synthetic-removal")
        send()
        XCTAssertTrue(latestReferences().isEmpty)
        capture("removed-context-reopened")
    }
    func testBeforePickers() {
        open("synthetic-context")
        app.buttons["Attachments & tools"].tap()
        let files = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Attach Files'")).firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(app.staticTexts["Sample document 03.txt"].waitForExistence(timeout: 10))
        capture("before-files")
        app.textFields["Search files…"].tap()
        app.textFields["Search files…"].typeText("Orchard")
        Thread.sleep(forTimeInterval: 1)
        capture("before-file-search")
        app.buttons["Back"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Attach Knowledge'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sample collection 01"].waitForExistence(timeout: 10))
        capture("before-knowledge")
    }
}
