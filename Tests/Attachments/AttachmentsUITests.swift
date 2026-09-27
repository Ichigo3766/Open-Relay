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
        Thread.sleep(forTimeInterval: 0.5)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    private func send() {
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        for character in "Summarize it more briefly." { input.typeText(String(character)) }
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Context received' OR label CONTAINS 'No attachment context' OR value CONTAINS 'Context received' OR value CONTAINS 'No attachment context'")).firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1)
    }
    private func latestReferences() -> [[String: Any]] {
        let requests = get("/fixture/state")["requests"] as! [[String: Any]]
        let body = requests.last(where: { $0["path"] as? String == "/api/chat/completions" })!["body"] as! [String: Any]
        return body["files"] as? [[String: Any]] ?? []
    }
    func testBeforeFollowUp() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATTACHMENTS_BASELINE"] == "1")
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
    func testRegeneratePreservesContext() {
        get("/fixture/reset")
        open("synthetic-context")
        app.buttons["Regenerate"].firstMatch.tap()
        let result = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Context received' OR value CONTAINS 'Context received'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertEqual(latestReferences().first?["context"] as? String, "full")
        let requests = get("/fixture/state")["requests"] as! [[String: Any]]
        let body = requests.last(where: { $0["path"] as? String == "/api/chat/completions" })!["body"] as! [String: Any]
        let user = body["user_message"] as! [String: Any]
        XCTAssertEqual((user["files"] as! [[String: Any]]).first?["context"] as? String, "full")
        capture("regenerated-context")
    }
    func testEditPreservesContext() {
        get("/fixture/reset")
        open("synthetic-context")
        let bubble = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'You: Please summarize'")).firstMatch
        bubble.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Save and resend"].waitForExistence(timeout: 5))
        app.buttons["Save and resend"].tap()
        let result = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Context received' OR value CONTAINS 'Context received'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertEqual(latestReferences().first?["context"] as? String, "full")
        capture("edited-context")
    }
    func testOtherClientRemoval() {
        get("/fixture/reset")
        get("/fixture/remove")
        open("synthetic-removal")
        send()
        XCTAssertTrue(latestReferences().isEmpty)
    }
    func testFailedRemovalRestoresSource() {
        get("/fixture/reset")
        open("synthetic-removal")
        get("/fixture/fail-removal")
        app.buttons["More chat actions"].tap()
        app.buttons["Chat Settings"].tap()
        let remove = app.buttons["Remove Sample document 01.txt"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(remove.exists)
        let chats = get("/fixture/state")["chats"] as! [String: [String: Any]]
        let chat = chats["synthetic-removal"]!["chat"] as! [String: Any]
        XCTAssertEqual((chat["files"] as! [Any]).count, 1)
    }
    func testBeforePickers() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATTACHMENTS_BASELINE"] == "1")
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

    private func picker(_ title: String) {
        app.buttons["Attachments & tools"].tap()
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
    private func search(_ text: String) {
        if !app.searchFields.firstMatch.waitForExistence(timeout: 2) {
            app.buttons["Search"].firstMatch.tap()
        }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if field.buttons["Clear text"].exists { field.buttons["Clear text"].tap() }
        field.typeText(text)
    }
    func testFilesSearchAndPersistentSelection() {
        get("/fixture/reset")
        open("synthetic-context")
        picker("Attach Files")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample document 01.txt'")).firstMatch.waitForExistence(timeout: 10))
        capture("after-files")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample document 01.txt'")).firstMatch.tap()
        search("Orchard")
        let orchard = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Orchard guide.txt'")).firstMatch
        XCTAssertTrue(orchard.waitForExistence(timeout: 10))
        orchard.tap()
        capture("after-file-search")
        app.buttons["Attach 2 files"].tap()
        send()
        let files = latestReferences()
        XCTAssertTrue(files.contains { $0["id"] as? String == "document-67" && $0["context"] as? String == "full" })
        XCTAssertTrue(files.contains { $0["id"] as? String == "document-1" })
        let requests = get("/fixture/state")["requests"] as! [[String: Any]]
        XCTAssertTrue(requests.contains {
            let query = $0["query"] as? [String: String]
            return $0["path"] as? String == "/api/v1/files/search" && query?["filename"] == "*Orchard*" && query?["content"] == "false"
        })
    }
    func testFilesPagination() {
        get("/fixture/reset")
        open("synthetic-context")
        picker("Attach Files")
        let more = app.buttons["Load more files"]
        for _ in 0..<8 where !more.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(more.isHittable)
        more.tap()
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample document 31.txt'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let requests = get("/fixture/state")["requests"] as! [[String: Any]]
        XCTAssertTrue(requests.contains { ($0["query"] as? [String: String])?["skip"] == "30" })
        capture("after-files-page-two")
    }
    func testFilesSearchFailureRetryAndEmpty() {
        get("/fixture/reset")
        get("/fixture/fail-search?enabled=1")
        open("synthetic-context")
        picker("Attach Files")
        let retry = app.buttons["Couldn’t load files. Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        get("/fixture/fail-search?enabled=0")
        retry.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample document 01.txt'")).firstMatch.waitForExistence(timeout: 10))
        search("No matching synthetic document")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 10))
    }
    func testKnowledgePaginationAndWholeCollection() {
        get("/fixture/reset")
        open("synthetic-context")
        picker("Attach Knowledge")
        let more = app.buttons["Load more knowledge bases"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sample collection 06,'")).firstMatch
        for _ in 0..<4 where !result.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(app.buttons["Context mode for Sample collection 06"].waitForExistence(timeout: 10))
        send()
        let reference = latestReferences().first { $0["id"] as? String == "collection-6" }
        XCTAssertEqual(reference?["type"] as? String, "collection")
        XCTAssertEqual(reference?["context"] as? String, "full")
        let requests = get("/fixture/state")["requests"] as! [[String: Any]]
        XCTAssertTrue(requests.contains {
            $0["path"] as? String == "/api/v1/knowledge/search" && ($0["query"] as? [String: String])?["page"] == "2"
        })
    }
    func testHashFolderType() {
        get("/fixture/reset")
        open("synthetic-context")
        let input = app.textViews.firstMatch
        input.tap()
        Thread.sleep(forTimeInterval: 1)
        for character in "#Sample" { input.typeText(String(character)) }
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample folder'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        folder.tap()
        send()
        let reference = latestReferences().first { $0["id"] as? String == "sample-folder" }
        XCTAssertEqual(reference?["type"] as? String, "folder")
    }
    func testKnowledgeBrowseAndMode() {
        get("/fixture/reset")
        open("synthetic-context")
        picker("Attach Knowledge")
        let browse = app.buttons["Browse Sample collection 01"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        capture("after-knowledge")
        browse.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample document 01.txt'")).firstMatch.waitForExistence(timeout: 10))
        capture("after-collection-documents")
        search("Orchard")
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Orchard guide.txt'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        capture("after-collection-search")
        file.tap()
        let menu = app.buttons["Context mode for Orchard guide.txt"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        capture("after-context-menu")
        app.buttons["Focused Retrieval"].tap()
        send()
        let reference = latestReferences().first { $0["id"] as? String == "document-67" }
        XCTAssertEqual(reference?["type"] as? String, "file")
        XCTAssertNil(reference?["context"])
        XCTAssertNotNil(reference?["file"])
    }
    func testHashSearch() {
        get("/fixture/reset")
        open("synthetic-context")
        let input = app.textViews.firstMatch
        input.tap()
        Thread.sleep(forTimeInterval: 1)
        for character in "#Orchard" {
            input.typeText(String(character))
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(input.value as? String, "#Orchard")
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Orchard guide.txt'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        XCTAssertTrue(file.isHittable)
        capture("after-hash-search")
        file.tap()
        XCTAssertTrue(app.buttons["Context mode for Orchard guide.txt"].waitForExistence(timeout: 5))
        let requests = get("/fixture/state")["requests"] as! [[String: Any]]
        XCTAssertTrue(requests.contains {
            $0["path"] as? String == "/api/v1/knowledge/search/files" && ($0["query"] as? [String: String])?["query"] == "Orchard"
        })
    }
    func testUploadDefaultSettings() {
        get("/fixture/reset")
        open("synthetic-context")
        app.buttons["Menu"].tap()
        app.buttons["More"].firstMatch.tap()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chat Behavior'")).firstMatch.tap()
        let mode = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Default Upload Mode'")).firstMatch
        for _ in 0..<3 where !mode.isHittable { app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        capture("after-upload-settings")
        mode.tap()
        app.buttons["Focused Retrieval"].tap()
        Thread.sleep(forTimeInterval: 1)
        let ui = (get("/fixture/state")["settings"] as! [String: Any])["ui"] as! [String: Any]
        XCTAssertEqual(ui["defaultUploadContext"] as? String, "focused")
        XCTAssertEqual(ui["fixtureUnrelatedSetting"] as? String, "keep")
        capture("after-upload-setting-saved")
    }
    func testFolderKnowledgePicker() {
        get("/fixture/reset")
        open("synthetic-context")
        app.buttons["Menu"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample folder'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.press(forDuration: 1)
        app.buttons["Create Folder"].tap()
        let knowledge = app.buttons["Select Knowledge"]
        for _ in 0..<8 where !knowledge.isHittable { app.swipeUp() }
        XCTAssertTrue(knowledge.isHittable)
        knowledge.tap()
        XCTAssertTrue(app.buttons["Browse Sample collection 01"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.navigationBars["Attach Knowledge"].buttons.count, 1)
        capture("after-folder-knowledge")
        app.buttons["Browse Sample collection 01"].tap()
        XCTAssertTrue(app.navigationBars["Sample collection 01"].waitForExistence(timeout: 5))
        app.navigationBars["Sample collection 01"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Browse Sample collection 01"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Create Folder"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }
}
