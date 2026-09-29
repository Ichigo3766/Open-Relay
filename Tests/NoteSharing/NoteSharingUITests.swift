import XCTest

@MainActor final class NoteSharingUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/" + path)!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }
    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func openNote(reset: Bool = true, mode: String = "owner", appearance: String = "light", large: Bool = false) async throws {
        app.terminate()
        if reset { try await post("reset") }
        if mode != "owner" { try await post(mode) }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notes Sharing Demo'")).firstMatch.waitForExistence(timeout: 30), "Use only the loopback fixture")
        app.buttons["Menu"].tap(); app.buttons["More"].tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts["Paper Lanterns"].waitForExistence(timeout: 10))
        app.staticTexts["Paper Lanterns"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Notes"].waitForExistence(timeout: 10))
    }
    func openAccess(large: Bool = false) {
        app.buttons["Note Actions"].tap()
        capture("after-note-actions")
        app.buttons["Manage Access"].tap()
        XCTAssertTrue(app.navigationBars["Note Access"].waitForExistence(timeout: 5))
        if large {
            capture("after-large-text-top")
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Add Access"].waitForExistence(timeout: 5))
    }
    func waitSaved() {
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForNonExistence(timeout: 8))
    }
    func testBefore() async throws {
        try await openNote()
        app.buttons["AI Features"].tap()
        XCTAssertFalse(app.buttons["Manage Access"].exists)
        capture("before-note-actions")
    }
    func testSharing() async throws {
        try await openNote(); openAccess()
        capture("after-private")
        app.buttons["Add Access"].tap()
        XCTAssertTrue(app.buttons["Demo Reader 1"].waitForExistence(timeout: 10))
        app.buttons["Load More"].tap()
        XCTAssertTrue(app.buttons["Demo Reader 3"].waitForExistence(timeout: 5))
        capture("people-picker")
        app.searchFields.firstMatch.tap(); app.searchFields.firstMatch.typeText("Reader 3")
        XCTAssertTrue(app.buttons["Demo Reader 1"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Demo Reader 3"].waitForExistence(timeout: 5))
        app.buttons["Demo Reader 3"].tap(); waitSaved()
        XCTAssertTrue(app.buttons["Access for Demo Reader 3"].waitForExistence(timeout: 5))
        app.buttons["Access for Demo Reader 3"].tap(); app.buttons["Can edit"].tap(); waitSaved()
        app.buttons["Add Access"].tap(); app.buttons["Groups"].tap()
        XCTAssertTrue(app.buttons["Paper Team"].waitForExistence(timeout: 5))
        capture("groups-picker")
        app.buttons["Paper Team"].tap(); waitSaved()
        XCTAssertTrue(app.buttons["Access for Paper Team"].waitForExistence(timeout: 5))
        capture("after-people-groups")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Everyone on this server'")).firstMatch.tap()
        app.buttons["Can read"].tap(); waitSaved()
        capture("after-shared")
        let saved = try await state()
        let grants = saved["grants"] as! [[String: String]]
        XCTAssertTrue(grants.contains { $0["principal_id"] == "person-3" && $0["permission"] == "write" })
        XCTAssertTrue(grants.contains { $0["principal_id"] == "paper-team" && $0["permission"] == "read" })
        XCTAssertTrue(grants.contains { $0["principal_id"] == "*" && $0["permission"] == "read" })
        let searches = saved["searches"] as! [[String: Any]]
        XCTAssertTrue(searches.contains { $0["page"] as? Int == 2 })
        XCTAssertTrue(searches.contains { $0["query"] as? String == "Reader 3" })
        try await openNote(reset: false, appearance: "dark"); openAccess()
        XCTAssertTrue(app.buttons["Access for Paper Team"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Access for Demo Reader 3"].waitForExistence(timeout: 5))
        capture("after-dark-reopened")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Everyone on this server'")).firstMatch.tap()
        app.buttons["Can edit"].tap(); waitSaved()
        var publicGrants = try await state()["grants"] as! [[String: String]]
        XCTAssertTrue(publicGrants.contains { $0["principal_id"] == "*" && $0["permission"] == "write" })
        XCTAssertTrue(publicGrants.contains { $0["principal_id"] == "*" && $0["permission"] == "read" })
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Everyone on this server'")).firstMatch.tap()
        app.buttons["No access"].tap(); waitSaved()
        publicGrants = try await state()["grants"] as! [[String: String]]
        XCTAssertFalse(publicGrants.contains { $0["principal_id"] == "*" })
        app.buttons["Access for Paper Team"].tap(); app.buttons["Remove access"].tap(); waitSaved()
        let removed = try await state()["grants"] as! [[String: String]]
        XCTAssertFalse(removed.contains { $0["principal_id"] == "paper-team" })
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Note Actions"].waitForExistence(timeout: 5))
    }
    func testFailureAndReadOnly() async throws {
        try await openNote(); openAccess(); try await post("fail")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Everyone on this server'")).firstMatch.tap()
        app.buttons["Can read"].tap(); waitSaved()
        XCTAssertTrue(app.staticTexts["Couldn’t update access"].waitForExistence(timeout: 5))
        var saved = try await state()
        XCTAssertEqual((saved["updates"] as! [Any]).count, 1, "No automatic write retries")
        XCTAssertTrue((saved["grants"] as! [Any]).isEmpty)
        capture("failure-retains-private")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Everyone on this server'")).firstMatch.tap()
        app.buttons["Can read"].tap(); waitSaved()
        saved = try await state()
        XCTAssertEqual((saved["updates"] as! [Any]).count, 2)
        XCTAssertEqual((saved["grants"] as! [Any]).count, 1)
        try await openNote(mode: "reader")
        app.buttons["Note Actions"].tap(); app.buttons["Manage Access"].tap()
        XCTAssertTrue(app.staticTexts["Only the owner or an administrator can manage this note’s access."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add Access"].exists)
        let denied = try await state()
        XCTAssertTrue((denied["updates"] as! [Any]).isEmpty)
        capture("read-only-access")
    }
    func testLargeText() async throws {
        try await openNote(large: true); openAccess(large: true)
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.buttons["Add Access"].isHittable)
        capture("after-large-text")
        close.tap()
        XCTAssertTrue(app.buttons["Note Actions"].waitForExistence(timeout: 5))
    }
}
