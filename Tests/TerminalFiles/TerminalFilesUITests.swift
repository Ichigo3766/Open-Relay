import XCTest

/// Run only against fixture.py on a clean, synthetic-only simulator.
final class TerminalFilesUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    private let base = "http://127.0.0.1:18191"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-last_active_conversation_id", ""]
        app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Not Now"].waitForExistence(timeout: 2) { system.buttons["Not Now"].tap() }
    }
    private func get(_ path: String) -> [String: Any] {
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
    private func requests() -> [String: Int] { get("/fixture/metrics")["requests"] as! [String: Int] }
    private func open(_ id: String = "synthetic-files") {
        app.open(URL(string: "openui://chat/" + id)!)
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 20))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test01Connect() {
        if app.buttons["Menu"].waitForExistence(timeout: 3) { return }
        XCTAssertTrue(app.buttons["Advanced"].waitForExistence(timeout: 30))
        let address = app.textFields.firstMatch
        address.tap()
        address.typeText(base)
        if !app.secureTextFields.firstMatch.exists { app.buttons["Advanced"].tap() }
        app.secureTextFields.firstMatch.tap()
        app.secureTextFields.firstMatch.typeText("synthetic-token")
        app.buttons.matching(identifier: "Connect").allElementsBoundByIndex.first(where: \.isHittable)!.tap()
        if app.buttons["Skip"].waitForExistence(timeout: 8) { app.buttons["Skip"].tap() }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
    }

    func test02IdleReopenAndToolDetails() {
        _ = get("/fixture/reset")
        open()
        let hasAttachment = app.buttons["Play motion.mp4"].waitForExistence(timeout: 20)
        capture("attachments-idle")
        XCTAssertTrue(hasAttachment)
        for _ in 0..<4 { app.swipeUp(); app.swipeDown() }
        let group = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Explored '")).firstMatch
        if group.exists { group.tap() }
        let tool = app.buttons["View Result from display_file"].firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        tool.tap()
        XCTAssertTrue(app.staticTexts["OUTPUT"].waitForExistence(timeout: 5))
        tool.tap()
        if group.exists { group.tap() }
        for _ in 0..<2 {
            app.terminate()
            app.launch()
            open()
            XCTAssertTrue(app.buttons["Play motion.mp4"].waitForExistence(timeout: 20))
        }
        XCTAssertEqual(requests(), [:])
        XCTAssertEqual(get("/fixture/metrics")["bytes"] as! [String: Int], [:])
    }

    func test03PlaybackAndReuse() {
        _ = get("/fixture/reset")
        open()
        let play = app.buttons["Play motion.mp4"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        XCTAssertTrue(app.buttons["Cancel loading motion.mp4"].waitForExistence(timeout: 5))
        capture("loading-selected-video")
        XCTAssertTrue(app.otherElements["Video"].waitForExistence(timeout: 30))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let toggle = app.buttons["Play/Pause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        if toggle.label == "Pause" { toggle.tap() }
        XCTAssertEqual(toggle.label, "Play")
        let before = elapsed()
        toggle.tap()
        Thread.sleep(forTimeInterval: 3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if toggle.label == "Pause" { toggle.tap() }
        let paused = elapsed()
        XCTAssertGreaterThan(paused, before)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(elapsed(), paused)
        app.sliders["Current position"].adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertGreaterThan(elapsed(), 25)
        capture("video-playback-seek")
        toggle.tap()
        Thread.sleep(forTimeInterval: 2)
        closePreview()
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertTrue(app.otherElements["Video"].waitForExistence(timeout: 5))
        closePreview()
        XCTAssertEqual(requests(), ["motion.mp4": 1])
    }
    private func elapsed() -> Int {
        let label = app.staticTexts["Elapsed Time"].label
        let parts = (label.split(separator: " ").first ?? "").split(separator: ":").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2)
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }
    private func closePreview() {
        let done = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        if app.otherElements["Video"].exists {
            // Let playing video's chrome hide, reveal it, then tap the observed
            // native close control immediately, without slow AX snapshots.
            Thread.sleep(forTimeInterval: 5)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.095)).tap()
        } else {
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
        }
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForNonExistence(timeout: 5))
    }

    func test04Export() {
        _ = get("/fixture/reset")
        open()
        let save = app.buttons["Save or share motion.mp4"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        XCTAssertTrue(app.buttons["Cancel loading motion.mp4"].waitForNonExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        capture("export-original-file")
        XCTAssertTrue(app.otherElements["ActivityListView"].exists)
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 5))
        app.buttons["header.closeButton"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForNonExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 5))
        app.buttons["header.closeButton"].tap()
        XCTAssertEqual(requests(), ["motion.mp4": 1])
    }

    func test05FailureCancelRetry() {
        _ = get("/fixture/reset")
        open("synthetic-errors")
        let missing = app.buttons["Play missing.mp4"]
        XCTAssertTrue(missing.waitForExistence(timeout: 20))
        missing.tap()
        XCTAssertTrue(app.buttons["Retry missing.mp4"].waitForExistence(timeout: 10))
        capture("recoverable-missing-file")
        app.buttons["Retry missing.mp4"].tap()
        XCTAssertTrue(app.buttons["Retry missing.mp4"].waitForExistence(timeout: 10))
        let slow = app.buttons["Play slow.mp4"]
        if !slow.isHittable { app.swipeUp() }
        slow.tap()
        let cancel = app.buttons["Cancel loading slow.mp4"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        cancel.tap()
        XCTAssertTrue(slow.waitForExistence(timeout: 5))
        XCTAssertLessThan((get("/fixture/metrics")["bytes"] as! [String: Int])["slow.mp4"]!, 52_000_000)
        let retry = app.buttons["Play retry.mp4"]
        if !retry.isHittable { app.swipeUp() }
        retry.tap()
        XCTAssertTrue(app.buttons["Retry retry.mp4"].waitForExistence(timeout: 10))
        app.buttons["Retry retry.mp4"].tap()
        XCTAssertTrue(app.otherElements["Video"].waitForExistence(timeout: 30))
        closePreview()
        XCTAssertEqual(requests()["retry.mp4"], 2)
    }

    func test06LiveEventNoDownload() {
        _ = get("/fixture/reset")
        open("synthetic-live")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.buttons["Open notes.txt"].exists)
        _ = get("/fixture/live")
        XCTAssertTrue(app.buttons["Open notes.txt"].waitForExistence(timeout: 15))
        _ = get("/fixture/live")
        XCTAssertEqual(app.buttons.matching(identifier: "Open notes.txt").count, 1)
        _ = get("/fixture/live-saved")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.buttons.matching(identifier: "Open notes.txt").count, 1)
        XCTAssertEqual(requests(), [:])
        app.buttons["Open notes.txt"].tap()
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 15))
        let textLoaded = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'A freshly invented sample document' OR value CONTAINS 'A freshly invented sample document'")).firstMatch.waitForExistence(timeout: 15)
        capture("document-preview")
        XCTAssertTrue(textLoaded)
    }

    func test07OtherContent() {
        _ = get("/fixture/reset")
        open("synthetic-ordinary")
        XCTAssertTrue(app.buttons["View Result from sample_table"].waitForExistence(timeout: 20))
        app.buttons["View Result from sample_table"].tap()
        XCTAssertTrue(app.staticTexts["OUTPUT"].waitForExistence(timeout: 5))
        app.buttons["View Result from sample_table"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Sample table"].waitForExistence(timeout: 20))
        capture("ordinary-tool-image-and-embed")
        XCTAssertEqual(requests(), [:])
    }

    func test08AudioAndImage() {
        _ = get("/fixture/reset")
        open()
        let audio = app.buttons["Play tone.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 20))
        if !audio.isHittable { app.swipeUp() }
        audio.tap()
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 15))
        let toggle = app.buttons.matching(NSPredicate(format: "label == 'Play' OR label == 'Pause'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.label == "Play" { toggle.tap() }
        Thread.sleep(forTimeInterval: 3)
        toggle.tap()
        let audioTime = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'seconds remaining' OR label CONTAINS 'seconds elapsed'")).firstMatch.label
        let seconds = Int(audioTime.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertLessThan(seconds, 10)
        capture("audio-preview")
        app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].tap()
        let image = app.buttons["Open sample.png"]
        if !image.isHittable { app.swipeUp() }
        image.tap()
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        capture("image-preview")
        XCTAssertEqual(requests(), ["tone.m4a": 1, "sample.png": 1])
    }

    func test09PathOnlyOriginatingEvent() {
        _ = get("/fixture/reset")
        _ = get("/fixture/enable-terminal")
        app.terminate()
        app.launch()
        open("synthetic-active")
        let terminal = app.descendants(matching: .any).matching(identifier: "Terminal").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        terminal.tap()
        app.textViews.firstMatch.tap()
        app.textViews.firstMatch.typeText("Show the sample note.")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Open notes.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop Generating"].exists)
        XCTAssertEqual(get("/fixture/active-request")["terminal_id"] as? String, "demo-terminal")
        XCTAssertEqual(requests(), [:])
        capture("path-only-live-event")
    }
}
