import XCTest

/// Run only on a disposable simulator signed into fixture.py at 127.0.0.1:18191.
final class LibrarySearchUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    private var results: XCUIElement { app.scrollViews["library-search-results"] }
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDark() { exercise("dark") }
    func testLight() { exercise("light") }

    func testDarkDemo() { demo("dark") }
    func testLightDemo() { demo("light") }

    private func demo(_ appearance: String) {
        launch(appearance)
        openSearch()
        settle()
        search("lantern")
        XCTAssertTrue(results.staticTexts["Paper gallery"].waitForExistence(timeout: 5))
        app.keyboards.buttons["Search"].tap()
        settle()
        app.buttons["search-filter-Knowledge"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hang the yellow lantern'")).firstMatch.waitForExistence(timeout: 10))
        settle()
        results.staticTexts["Assembly guide.txt"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        settle()
        app.buttons["Done"].tap()
        app.buttons["search-filter-Chats"].tap()
        XCTAssertTrue(results.staticTexts["Paper gallery"].waitForExistence(timeout: 5))
        results.staticTexts["Paper gallery"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch.waitForExistence(timeout: 15))
        settle()
    }

    func testPaginationAndChangingQuery() {
        launch("dark")
        openSearch()
        search("slow")
        search("lantern")
        XCTAssertTrue(results.staticTexts["Paper gallery"].waitForExistence(timeout: 5))
        search("pages")
        app.buttons["search-filter-Chats"].tap()
        app.keyboards.buttons["Search"].tap()
        let more = app.buttons["search-more-chats"]
        for _ in 0..<20 {
            if more.exists && more.isHittable { break }
            app.scrollViews["library-search-results"].swipeUp()
        }
        XCTAssertTrue(more.isHittable)
        more.tap()
        XCTAssertTrue(app.staticTexts["Paper display 60"].waitForExistence(timeout: 5))
        XCTAssertFalse(more.exists)
        app.buttons["Close search"].tap()
    }

    func testBefore() throws {
        launch("dark")
        app.buttons["Menu"].tap()
        if app.buttons["Search library"].exists {
            throw XCTSkip("Baseline capture requires the old sidebar-search build.")
        }
        let field = app.textFields["Search conversations…"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        capture("before-sidebar")
        field.tap()
        field.typeText("lantern")
        settle()
        capture("before-body-match")
        XCTAssertFalse(app.buttons["Paper gallery"].exists)
    }

    private func launch(_ appearance: String) {
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance,
                               "-chatScrollControls", "hidden"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
    }

    private func openSearch() {
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["Search library"].waitForExistence(timeout: 5))
        app.buttons["Search library"].tap()
        XCTAssertTrue(app.textFields["library-search-field"].waitForExistence(timeout: 5))
    }

    private func search(_ text: String) {
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        let field = app.textFields["library-search-field"]
        field.tap()
        field.typeText(text)
        settle()
    }

    private func exercise(_ appearance: String) {
        launch(appearance)
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["Search library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Search conversations…"].exists)
        XCTAssertLessThan(app.buttons["Chat actions"].frame.midX, app.buttons["Search library"].frame.midX)
        app.buttons["Chat actions"].tap()
        XCTAssertTrue(app.buttons["Archived Chats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Shared Chats"].exists)
        app.buttons["Select Chats"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        capture("\(appearance)-sidebar")
        app.buttons["Search library"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("\(appearance)-empty")
        search("lantern")
        XCTAssertTrue(results.staticTexts["Paper gallery"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A yellow lantern lights the miniature harbor beside a silver kite."].exists)
        capture("\(appearance)-all-keyboard")
        app.keyboards.buttons["Search"].tap()
        settle()
        capture("\(appearance)-all")
        app.buttons["search-filter-Knowledge"].tap()
        XCTAssertTrue(results.staticTexts["Assembly guide.txt"].waitForExistence(timeout: 10))
        let excerpt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hang the yellow lantern'"))
        XCTAssertTrue(excerpt.firstMatch.waitForExistence(timeout: 10))
        capture("\(appearance)-knowledge")
        results.staticTexts["Assembly guide.txt"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fold a square sheet'")).firstMatch.waitForExistence(timeout: 10))
        capture("\(appearance)-document")
        app.buttons["Done"].tap()
        results.staticTexts["Paper crafts"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Paper crafts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Assembly guide.txt"].waitForExistence(timeout: 5))
        capture("\(appearance)-knowledge-files")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["search-filter-Folders"].tap()
        XCTAssertTrue(results.staticTexts["Lantern workshop"].waitForExistence(timeout: 5))
        results.staticTexts["Lantern workshop"].tap()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close search"].exists)
        openSearch()
        search("lantern")
        app.buttons["search-filter-Chats"].tap()
        XCTAssertTrue(results.staticTexts["Paper gallery"].waitForExistence(timeout: 5))
        results.staticTexts["Paper gallery"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch.waitForExistence(timeout: 15))
        openSearch()
        search("no-matches-here")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.waitForExistence(timeout: 5))
        capture("\(appearance)-no-results")
        search("offline")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        XCTAssertTrue(results.staticTexts["Paper gallery"].exists)
        app.buttons["Retry"].tap()
        settle()
        search("lantern")
        XCTAssertTrue(results.staticTexts["Paper gallery"].waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["Search your library"].waitForExistence(timeout: 5))
        app.buttons["Close search"].tap()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 5))
    }

    private func settle() {
        let settled = expectation(description: "Search settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
