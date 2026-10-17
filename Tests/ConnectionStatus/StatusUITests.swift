import XCTest

/// Run on a disposable simulator with the invented fixture described in README.md.
@MainActor final class StatusUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    let message = "Couldn’t save your message. Your draft has been restored. Please try again."
    let chatID = "af55b47a-ed1d-54f7-95e3-975d9afdfb57"

    override func setUpWithError() throws { continueAfterFailure = true; control(false) }
    func control(_ failSave: Bool) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18365/audit/control")!)
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: ["fail_save": failSave])
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
    func failSend() {
        control(true)
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts[message].firstMatch.waitForExistence(timeout: 25))
        control(false)
        Thread.sleep(forTimeInterval: 0.7)
    }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait; app.terminate() }

    func open(_ fixture: String) {
        app.launchEnvironment["SYNTHETIC_STATUS_FIXTURE"] = fixture
        app.launchArguments = ["-last_active_conversation_id", chatID]
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 3) {
            let url = app.textFields.firstMatch
            url.tap(); url.typeText("http://127.0.0.1:18365")
            app.buttons["Connect"].tap()
        }
        if !app.buttons["Sign in"].exists {
            let email = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch
            if email.waitForExistence(timeout: 3) { email.tap() }
        }
        if app.buttons["Sign in"].waitForExistence(timeout: 2) {
            app.textFields.firstMatch.tap(); app.textFields.firstMatch.typeText("aster@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic-aster-password")
            app.buttons["Sign in"].tap()
            if app.buttons["Skip"].waitForExistence(timeout: 5) { app.buttons["Skip"].tap() }
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        app.open(URL(string: "openui://chat/" + chatID)!)
        Thread.sleep(forTimeInterval: 3)
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if spring.buttons["Don’t Allow"].exists { spring.buttons["Don’t Allow"].tap() }
    }
    func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func status(_ fixture: String, _ title: String) {
        open(fixture)
        capture(fixture)
        let badge = app.buttons["connection-status"]
        XCTAssertTrue(badge.exists, "Toolbar must expose connection status")
        if badge.exists { XCTAssertTrue(badge.label.contains(title)) }
        XCTAssertTrue(app.buttons["Menu"].firstMatch.isHittable, "An outage must not block saved chats")
    }
    func test01ServerWithSavedChats() { status("server", "Server unreachable") }
    func test02ServerWithoutSavedChats() { status("blocking", "Server unreachable") }
    func test03Offline() { status("offline", "Offline") }
    func test04ConnectedSidebar() {
        open("connected"); app.buttons["Menu"].firstMatch.tap(); Thread.sleep(forTimeInterval: 1)
        capture("sidebar-connected")
        XCTAssertTrue(app.buttons["sidebar-connection-status"].firstMatch.label.contains("Connected"))
    }
    func test05OfflineSidebar() {
        open("offline"); app.buttons["Menu"].firstMatch.tap(); Thread.sleep(forTimeInterval: 1)
        capture("sidebar-offline")
        XCTAssertTrue(app.buttons["sidebar-connection-status"].firstMatch.label.contains("Offline"))
    }
    func draft(_ landscape: Bool) {
        open("draft")
        failSend()
        if landscape { XCUIDevice.shared.orientation = .landscapeLeft; Thread.sleep(forTimeInterval: 2) }
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.exists)
        let notice = app.staticTexts[message].firstMatch
        capture(landscape ? "draft-closed-landscape" : "draft-closed-portrait")
        print("SYNTHETIC_CLOSED_LAYOUT banner=\(notice.frame) composer=\(field.frame)")
        XCTAssertFalse(notice.frame.intersects(field.frame), "A send error must not cover the draft with the keyboard closed")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        Thread.sleep(forTimeInterval: 2)
        capture(landscape ? "draft-landscape" : "draft-portrait")
        let banner = app.staticTexts[message].firstMatch
        XCTAssertTrue(banner.exists)
        let keyboard = app.keyboards.firstMatch
        print("SYNTHETIC_LAYOUT banner=\(banner.frame) composer=\(field.frame) keyboardVisible=\(keyboard.exists)")
        XCTAssertFalse(banner.frame.intersects(field.frame), "The error notice must occupy space above the composer")
        let gap = field.frame.minY - banner.frame.maxY
        XCTAssertTrue((0...60).contains(gap), "The notice stays next to the composer, not floating over chat content")
        XCTAssertTrue(banner.isHittable, "The notice stays visible above the keyboard")
        XCTAssertTrue((field.value as? String ?? "").contains("Invented clockwork planet"))
    }
    func test06LongDraftPortrait() { draft(false) }
    func test07LongDraftLandscape() { draft(true) }
    func test08Connecting() { status("checking", "Connecting…") }
    func test09Reconnecting() { status("reconnecting", "Reconnecting…") }
    func test10ConnectionActions() {
        open("server")
        let badge = app.buttons["connection-status"]
        guard badge.exists else { XCTFail("Missing status menu"); return }
        badge.tap(); capture("connection-actions")
        XCTAssertTrue(app.buttons["Retry Connection"].waitForExistence(timeout: 3))
        app.buttons["Retry Connection"].tap()
        XCTAssertTrue(app.textViews.firstMatch.exists, "Retry leaves the composer accessible")
    }
    func test12ConnectedToolbarIsQuiet() {
        open("connected")
        XCTAssertFalse(app.buttons["connection-status"].exists)
        capture("connected")
    }
    func test11DismissSendErrorPreservesDraft() {
        open("draft")
        failSend()
        let close = app.buttons["Dismiss message"].firstMatch
        guard close.exists else { XCTFail("Missing in-layout composer notice"); return }
        close.tap()
        XCTAssertFalse(app.staticTexts[message].exists)
        XCTAssertTrue((app.textViews.firstMatch.value as? String ?? "").contains("Invented clockwork planet"))
    }
}
