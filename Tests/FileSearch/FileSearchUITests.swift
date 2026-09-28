import XCTest

/// Use only an isolated simulator connected to fixture.py, never a real library.
@MainActor final class FileSearchUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    var results: XCUIElement { app.scrollViews["library-search-results"] }
    override func setUpWithError() throws { continueAfterFailure = false }

    func launch(_ appearance: String = "light") {
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.buttons["Connect"].exists {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("http://127.0.0.1:18191")
            app.buttons["Connect"].tap()
        }
        if app.staticTexts["Version 0.0.0-search-fixture"].waitForExistence(timeout: 3) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            let email = app.textFields.firstMatch
            XCTAssertTrue(email.waitForExistence(timeout: 5))
            email.tap(); email.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
            if app.buttons["Skip"].waitForExistence(timeout: 3) { app.buttons["Skip"].tap() }
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Paper Planner' OR label BEGINSWITH 'Kite Designer'")).firstMatch.waitForExistence(timeout: 15), "Synthetic fixture required")
    }
    func openSearch() {
        app.buttons["Menu"].tap()
        app.buttons["Search library"].tap()
        XCTAssertTrue(app.textFields["library-search-field"].waitForExistence(timeout: 5))
    }
    func search(_ text: String) {
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        let field = app.textFields["library-search-field"]
        field.tap()
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        field.typeText(text)
        app.keyboards.buttons["Search"].tap()
    }
    func filesFilter() {
        XCTAssertFalse(app.buttons["search-filter-Documents"].exists)
        let button = app.buttons["search-filter-Files"]
        if !button.isHittable { app.scrollViews["library-search-filters"].swipeLeft() }
        button.tap()
    }
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func scrollToResult(_ element: XCUIElement) {
        // XCTest can report offscreen rows behind the bottom search bar as hittable.
        for _ in 0..<20 {
            if element.exists && element.isHittable,
               element.frame.minY >= results.frame.minY,
               element.frame.maxY < app.buttons["Close search"].frame.minY - 8 { return }
            results.swipeUp(velocity: .slow)
        }
        XCTFail("Search result did not scroll into view")
    }
    func resetFixture() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/reset")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }
    func testBefore() {
        launch(); openSearch(); search("paper")
        XCTAssertTrue(results.staticTexts["Paper guide.pdf"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["search-filter-Files"].exists)
        shot("files-before-light")
        app.buttons["Close search"].tap()
    }
    func testFilesLight() { exercise("light") }
    func testFilesDark() { exercise("dark") }
    func testFilesSearchesKnowledgeContents() {
        launch(); openSearch(); filesFilter()
        search("imaginary")
        XCTAssertTrue(results.staticTexts["Paper guide.pdf"].waitForExistence(timeout: 10))
        XCTAssertTrue(results.staticTexts.matching(NSPredicate(format: "label CONTAINS 'imaginary boat'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(results.staticTexts["Paper plan 01.pdf"].exists)
        shot("files-content-match-light")
        app.buttons["Close search"].tap()
    }
    func testSearchDoesNotDownloadOriginals() async throws {
        launch(); openSearch(); filesFilter()
        try await resetFixture()
        search("paper")
        XCTAssertTrue(results.staticTexts["Paper guide.pdf"].waitForExistence(timeout: 10))
        results.swipeUp(); results.swipeDown()
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/metrics")!)
        let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        // Knowledge excerpts use /data/content; original file bytes use /{id}/content.
        XCTAssertFalse(requests.contains {
            let path = $0["path"] as? String ?? ""
            return path.hasSuffix("/content") && !path.hasSuffix("/data/content")
        })
        XCTAssertTrue(requests.contains { $0["path"] as? String == "/api/v1/knowledge/search/files" })
        XCTAssertEqual(results.staticTexts.matching(identifier: "Paper guide.pdf").count, 1)
        let searches = requests.filter { $0["path"] as? String == "/api/v1/files/search" }
        XCTAssertFalse(searches.isEmpty)
        XCTAssertTrue(searches.allSatisfy { $0["authorized"] as? Bool == true })
        XCTAssertTrue(searches.allSatisfy { ($0["query"] as? [String: [String]])?["content"] == ["false"] })
        app.scrollViews["library-search-filters"].swipeRight()
        app.buttons["search-filter-All"].tap()
        XCTAssertTrue(results.staticTexts["Paper collection"].waitForExistence(timeout: 10))
        XCTAssertEqual(results.staticTexts.matching(identifier: "Paper guide.pdf").count, 1)
        app.buttons["Close search"].tap()
    }
    func exercise(_ appearance: String) {
        launch(appearance); openSearch(); filesFilter(); search("paper")
        XCTAssertTrue(results.staticTexts["Paper guide.pdf"].waitForExistence(timeout: 10))
        XCTAssertTrue(results.staticTexts["Paper plan 01.pdf"].exists)
        XCTAssertTrue(results.staticTexts.matching(NSPredicate(format: "label CONTAINS 'imaginary boat'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(results.staticTexts.matching(identifier: "Paper guide.pdf").count, 1)
        shot("files-\(appearance)")
        results.staticTexts["Paper plan 01.pdf"].tap()
        XCTAssertTrue(app.buttons["Save or share file"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Paper workshop guide"].waitForExistence(timeout: 15))
        shot("file-preview-\(appearance)")
        app.buttons["Save or share file"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10))
        shot("file-share-\(appearance)")
        app.otherElements["PopoverDismissRegion"].tap()
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        let more = app.buttons["search-more-files"]
        scrollToResult(more); more.tap()
        let notes = results.staticTexts["Paper notes.txt"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        scrollToResult(notes)
        XCTAssertFalse(more.exists)
        notes.tap()
        XCTAssertTrue(app.buttons["Save or share file"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Fold a square sheet'")).firstMatch.waitForExistence(timeout: 15))
        shot("text-preview-\(appearance)")
        app.buttons["Close"].firstMatch.tap()
        search("no-such-file")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Close search"].tap()
    }
    func testErrorsAndCancellation() async throws {
        try await resetFixture()
        launch(); openSearch(); filesFilter(); search("offline")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        search("retry")
        XCTAssertTrue(results.staticTexts["Retry example.pdf"].waitForExistence(timeout: 10))
        results.staticTexts["Retry example.pdf"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["Save or share file"].waitForExistence(timeout: 10))
        app.buttons["Close"].firstMatch.tap()
        search("waiting")
        XCTAssertTrue(results.staticTexts["Waiting example.pdf"].waitForExistence(timeout: 10))
        results.staticTexts["Waiting example.pdf"].tap()
        XCTAssertTrue(app.staticTexts["Loading file…"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        search("notes")
        XCTAssertTrue(results.staticTexts["Paper notes.txt"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Save or share file"].exists)
        app.buttons["Close search"].tap()
    }
}
