import XCTest

final class PlayerUITests: XCTestCase {
    let relay = XCUIApplication(bundleIdentifier: "com.openui.openui")
    let chatID = "02d642ed-d5ee-4270-b8f1-e4f271987f90"

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture(["role": name.contains("NonAdmin") ? "user" : "admin", "split": "paragraphs", "voice": "fixture-voice", "delay": 0, "failures": 0])
        relay.launchArguments = ["-readAloudPlaybackRate", "1"]
        relay.launch()
        if !relay.buttons["Menu"].waitForExistence(timeout: 3) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for _ in 0..<2 {
                let deny = springboard.buttons["Don’t Allow"]
                if deny.waitForExistence(timeout: 2) { deny.tap() }
            }
            if relay.buttons["Connect"].exists {
                let url = relay.textFields.firstMatch
                url.tap(); url.typeText("http://127.0.0.1:18081")
                relay.buttons["Connect"].tap()
            }
            if !relay.buttons["Sign in"].exists {
                let option = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch
                if option.waitForExistence(timeout: 15) { option.tap() }
            }
            if relay.buttons["Sign in"].exists {
                settle(2)
                relay.textFields.firstMatch.tap(); relay.textFields.firstMatch.typeText("demo@example.test")
                relay.secureTextFields.firstMatch.tap(); relay.secureTextFields.firstMatch.typeText("synthetic")
                relay.buttons["Sign in"].tap()
                if relay.buttons["Skip"].waitForExistence(timeout: 10) { relay.buttons["Skip"].tap() }
            }
        }
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 30), relay.debugDescription)
    }

    @discardableResult func fixture(_ body: [String: Any]? = nil) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18081/fixture")!)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try! JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = expectation(description: "fixture response")
        var result: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, _, error in
            XCTAssertNil(error)
            if let data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }
    func settle(_ seconds: Double = 0.7) {
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 3)
    }
    func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: relay.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func waitFor(_ condition: @escaping () -> Bool, timeout: Double = 12, file: StaticString = #filePath, line: UInt = #line) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: timeout), .completed, file: file, line: line)
    }
    func openTTS() {
        relay.buttons["Menu"].tap()
        let account = relay.staticTexts["Demo"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5)); account.tap()
        let tts = relay.staticTexts["Text-to-Speech"].firstMatch
        for _ in 0..<4 where !tts.isHittable { relay.swipeUp() }
        XCTAssertTrue(tts.isHittable, relay.debugDescription); tts.tap()
        let server = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Server, OpenWebUI'")).firstMatch
        if server.exists { server.tap() }
        else { relay.staticTexts["Server"].firstMatch.tap() }
    }
    func choose(_ mode: String) {
        let picker = relay.buttons["speech.clientSplitting"]
        for _ in 0..<5 where !picker.isHittable { relay.swipeUp() }
        XCTAssertTrue(picker.isHittable, relay.debugDescription)
        relay.swipeUp()
        screenshot("Speech settings")
        picker.tap()
        let option = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", mode)).firstMatch
        if option.exists { option.tap() } else { relay.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", mode)).firstMatch.tap() }
        if relay.navigationBars["Client setting"].exists { relay.navigationBars["Client setting"].buttons.firstMatch.tap() }
    }
    func closeTTS() {
        relay.navigationBars["Text-to-Speech"].buttons.firstMatch.tap()
        relay.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 5))
    }
    func openChat() {
        relay.open(URL(string: "openui://chat/" + chatID)!)
        XCTAssertTrue(relay.buttons["Speak"].waitForExistence(timeout: 15), relay.debugDescription)
    }
    func startAudio() {
        relay.buttons["Speak"].tap()
        XCTAssertTrue(relay.buttons["speech.playPause"].waitForExistence(timeout: 10), relay.debugDescription)
    }
    var elapsed: Int {
        let values = (relay.buttons["speech.details"].value as? String ?? "").split(separator: ":").compactMap { Int($0) }
        return values.reduce(0) { $0 * 60 + $1 }
    }
    func inputs() -> [String] { (fixture()["requests"] as? [[String: Any]] ?? []).compactMap { $0["input"] as? String } }

    func test01PlayerControlsBackgroundAndTranscript() {
        openTTS(); choose("Follow Server"); closeTTS(); openChat(); startAudio()
        waitFor { self.elapsed >= 2 }
        screenshot("Player playing")
        relay.buttons["speech.playPause"].tap()
        let paused = elapsed; settle(1.2); XCTAssertEqual(elapsed, paused)
        XCTAssertEqual(relay.buttons["speech.playPause"].label, "Play audio")
        relay.buttons["speech.speed"].tap()
        XCTAssertEqual(relay.buttons["speech.speed"].value as? String, "1.25 times")
        relay.buttons["speech.forward"].tap(); settle(); XCTAssertGreaterThanOrEqual(elapsed, paused + 14)
        relay.buttons["speech.back"].tap(); settle(); XCTAssertLessThanOrEqual(abs(elapsed - paused), 1)
        relay.buttons["speech.playPause"].tap()
        let beforeBackground = elapsed
        XCUIDevice.shared.press(.home); settle(3); relay.activate()
        waitFor { self.elapsed >= beforeBackground + 2 }
        relay.buttons["speech.playPause"].tap()
        relay.buttons["speech.details"].tap()
        XCTAssertTrue(relay.sliders["speech.position"].waitForExistence(timeout: 5))
        relay.sliders["speech.position"].adjust(toNormalizedSliderPosition: 0.6)
        let transcript = relay.textViews["speech.transcript"]
        XCTAssertTrue(transcript.exists)
        XCTAssertFalse((transcript.value as? String ?? "").contains("hidden reasoning"))
        screenshot("Selectable transcript")
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.12)).press(forDuration: 1.2)
        settle()
        let fromHere = relay.menuItems["Play from here"]
        XCTAssertTrue(fromHere.waitForExistence(timeout: 5), relay.debugDescription)
        fixture([:]); fromHere.tap()
        waitFor { !self.inputs().isEmpty }
        XCTAssertFalse(self.inputs().first?.hasPrefix("A blue lantern") ?? true)
        XCTAssertTrue(relay.buttons["speech.close"].waitForExistence(timeout: 5))
        screenshot("Player restarted from selection")
        relay.buttons["speech.close"].tap()
        XCTAssertFalse(relay.buttons["speech.playPause"].exists)
    }

    func test02ServerInheritanceAndLocalOverrides() {
        for (mode, count) in [("Follow Server", 2), ("Sentences", 3), ("Whole Message", 1), ("Paragraphs", 2)] {
            fixture(["split": "paragraphs"])
            openTTS(); choose(mode); closeTTS(); openChat(); startAudio()
            waitFor { self.inputs().count == count }
            let requests = fixture()["requests"] as! [[String: Any]]
            XCTAssertTrue(requests.allSatisfy { ($0["voice"] as? String) == "fixture-voice" })
            XCTAssertFalse(inputs().joined().contains("hidden reasoning"))
            XCTAssertEqual((fixture()["updates"] as? [Any])?.count, 0)
            relay.buttons["speech.close"].tap()
        }
        openTTS(); choose("Follow Server"); closeTTS()
        fixture(["split": "none", "voice": "changed-voice"])
        openChat(); startAudio()
        waitFor { self.inputs().count == 1 }
        XCTAssertEqual((fixture()["requests"] as? [[String: Any]])?.first?["voice"] as? String, "changed-voice")
        relay.buttons["speech.close"].tap()
    }

    func test03ErrorRetryAndCloseWhileBuffering() {
        openTTS(); choose("Paragraphs"); closeTTS(); openChat()
        fixture(["failures": 1]); startAudio()
        XCTAssertTrue(relay.staticTexts["speech.error"].waitForExistence(timeout: 10))
        XCTAssertEqual(relay.buttons["speech.playPause"].label, "Retry audio")
        screenshot("Recoverable audio error")
        relay.buttons["speech.playPause"].tap()
        waitFor { self.elapsed > 0 }
        XCTAssertFalse(relay.staticTexts["speech.error"].exists)
        relay.buttons["speech.close"].tap()
        fixture(["delay": 2]); startAudio()
        relay.buttons["speech.close"].tap(); settle(3)
        XCTAssertFalse(relay.buttons["speech.playPause"].exists)
    }
    func test04AdminChangeFeedsFollowServer() {
        openTTS(); choose("Follow Server")
        let editServer = relay.buttons["Edit Server Audio"]
        for _ in 0..<4 where !editServer.isHittable { relay.swipeUp() }
        XCTAssertTrue(editServer.isHittable, relay.debugDescription)
        editServer.tap()
        let paragraphs = relay.buttons["Paragraphs"]
        for _ in 0..<5 where !paragraphs.isHittable { relay.swipeUp() }
        XCTAssertTrue(paragraphs.isHittable, relay.debugDescription)
        paragraphs.tap(); relay.buttons["None"].tap()
        relay.buttons["Save"].tap()
        XCTAssertTrue(relay.buttons["Saved"].waitForExistence(timeout: 10))
        let saved = fixture()
        XCTAssertEqual(saved["split"] as? String, "none")
        let updates = saved["updates"] as? [[String: Any]] ?? []
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual((updates.first?["stt"] as? [String: Any])?["ENGINE"] as? String, "fixture-stt")
        XCTAssertEqual(((updates.first?["tts"] as? [String: Any])?["OPENAI_PARAMS"] as? [String: Any])?["fixture"] as? Bool, true)
        relay.navigationBars["Server Audio"].buttons.firstMatch.tap()
        waitFor { self.relay.staticTexts["speech.serverSplitting"].label.contains("Whole Message") }
        screenshot("Updated server setting")
        closeTTS(); openChat(); startAudio()
        waitFor { self.inputs().count == 1 }
        relay.buttons["speech.close"].tap()
    }

    func test05NonAdminCanOverrideWithoutAdminAudioAccess() {
        openTTS(); choose("Whole Message")
        XCTAssertFalse(relay.buttons["Edit Server Audio"].exists)
        closeTTS(); openChat(); startAudio()
        waitFor { self.inputs().count == 1 }
        XCTAssertEqual(fixture()["role"] as? String, "user")
        XCTAssertEqual((fixture()["updates"] as? [Any])?.count, 0)
        waitFor { self.elapsed > 0 }
        screenshot("Non-admin client override")
        relay.buttons["speech.close"].tap()
    }

}
