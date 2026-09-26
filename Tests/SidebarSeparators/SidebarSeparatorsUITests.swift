import XCTest

final class SidebarSeparatorsUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBeforeLight() { check(theme: "light", separators: 2, name: "light-before") }
    func testBeforeDark() { check(theme: "dark", separators: 2, name: "dark-before") }
    func testChannelsDisabledLight() { check(theme: "light", separators: 1, name: "light-after") }
    func testChannelsDisabledDark() { check(theme: "dark", separators: 1, name: "dark-after") }
    func testChannelsEnabled() { check(scenario: ["channels": true], separators: 2) }
    func testEmptyFolders() { check(scenario: ["emptyFolders": true], separators: 1) }
    func testBothSectionsEmpty() { check(scenario: ["channels": true, "emptyFolders": true], separators: 2) }
    func testChannelsPermissionDenied() {
        check(scenario: ["channels": true], arguments: ["--qa-no-channel-permission"], separators: 1)
    }
    func testFoldersPermissionDenied() {
        check(arguments: ["--qa-no-folder-permission"], separators: 0)
    }
    func testOnlyChannels() {
        check(scenario: ["channels": true], arguments: ["--qa-no-folder-permission"], separators: 1)
    }
    func testFoldersUnavailable() { check(scenario: ["foldersForbidden": true], separators: 0) }
    func testOnlySharedFolders() { check(scenario: ["foldersForbidden": true, "shared": true], separators: 1) }
    func testNoChatsSection() { check(scenario: ["emptyFolders": true, "emptyChats": true], separators: 0) }

    private func check(theme: String = "light", scenario: [String: Bool] = [:],
                       arguments: [String] = [], separators: Int, name: String? = nil) {
        app.terminate()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18195/qa/scenario")!)
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: scenario)
        let ready = expectation(description: "Fixture ready")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            ready.fulfill()
        }.resume()
        wait(for: [ready], timeout: 5)

        app.launchArguments = ["-openui.appearance.mode", theme, "-last_active_conversation_id", "",
                               "-AppleLanguages", "(en)"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        app.buttons["Menu"].tap()
        // Allow list/config requests and sidebar transition to finish before counting.
        let settled = expectation(description: "Sidebar settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        if let name {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "qa-sidebar-divider").count,
                       separators)
        let channelsShown = scenario["channels"] == true && !arguments.contains("--qa-no-channel-permission")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Channels'")).count > 0,
                       channelsShown)
        if !scenario.keys.contains("emptyChats") {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Cloud shapes'")).firstMatch.exists)
        }
    }
}
