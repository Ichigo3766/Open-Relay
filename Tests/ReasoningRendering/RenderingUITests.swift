import UIKit
import XCTest

/// Run only in a disposable simulator connected to rendering_server.py.
final class RenderingUITests: XCTestCase {
    private let relay = XCUIApplication(bundleIdentifier: "com.openui.openui")

    override func setUpWithError() throws {
        continueAfterFailure = false
        relay.launchArguments = ["-renderAssistantMarkdown", "YES", "-openui.appearance.mode", "light"]
        relay.launch()
        if relay.buttons["Skip"].waitForExistence(timeout: 2) {
            relay.buttons["Skip"].tap()
        }
        if !relay.buttons["Menu"].waitForExistence(timeout: 3) {
            let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 2) {
                deny.tap()
            }
            if relay.buttons["Connect"].exists {
                let url = relay.textFields.firstMatch
                url.tap()
                url.typeText("http://127.0.0.1:18188")
                relay.buttons["Connect"].tap()
            }
            XCTAssertTrue(relay.staticTexts["Version 0.0.0-fixture"].waitForExistence(timeout: 10), "Use the loopback synthetic fixture server, never a real account.")
            let signIn = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch
            signIn.tap()
            let email = relay.textFields.firstMatch
            if !email.waitForExistence(timeout: 2) {
                relay.activate()
                signIn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
            }
            XCTAssertTrue(email.waitForExistence(timeout: 5))
            email.tap()
            if !relay.keyboards.firstMatch.waitForExistence(timeout: 2) {
                relay.activate()
                email.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
            }
            XCTAssertTrue(relay.keyboards.firstMatch.waitForExistence(timeout: 5))
            email.typeText("demo@example.test")
            relay.secureTextFields.firstMatch.tap()
            relay.secureTextFields.firstMatch.typeText("synthetic")
            relay.buttons["Sign in"].tap()
            if relay.buttons["Skip"].waitForExistence(timeout: 10) {
                relay.buttons["Skip"].tap()
            }
        }
        if relay.buttons["Skip"].exists {
            relay.buttons["Skip"].tap()
        }
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 15))
        XCTAssertTrue(relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Model'")).firstMatch.waitForExistence(timeout: 15))
    }

    private func openChat(_ title: String) {
        relay.buttons["Menu"].tap()
        let chat = relay.buttons[title]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertTrue(relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch.waitForExistence(timeout: 10))
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: relay.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scroll(_ up: Bool, fast: Bool = false) {
        let start = relay.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: up ? 0.75 : 0.3))
        let end = relay.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: up ? 0.3 : 0.75))
        if fast {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 2500), thenHoldForDuration: 0)
        } else {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    private func toggleThinking(expanded: Bool) {
        let toggle = relay.buttons["Thinking"]
        if !toggle.waitForExistence(timeout: 15) {
            screenshot("Synthetic missing reasoning toggle")
            add(XCTAttachment(string: relay.debugDescription))
        }
        XCTAssertTrue(toggle.isHittable)
        toggle.tap()
        let chevron = relay.images[expanded ? "chevron.down" : "chevron.right"]
        XCTAssertTrue(chevron.waitForExistence(timeout: 5))
    }

    private func reasoningRoundTrip(_ title: String) {
        openChat(title)
        toggleThinking(expanded: true)
        XCTAssertTrue(relay.buttons["Thinking"].isHittable, "Expanding reasoning must not jump away from its header.")
        screenshot(title + " expanded")
        var down = 0
        while !relay.buttons["Continue response"].isHittable, down < 400 {
            scroll(true, fast: true)
            down += 1
            if down == 10 {
                screenshot(title + " middle")
            }
        }
        XCTAssertTrue(relay.buttons["Continue response"].isHittable, "The final answer must remain reachable.")
        screenshot(title + " end")
        var up = 0
        while !relay.buttons["Thinking"].isHittable, up < 400 {
            scroll(false, fast: true)
            up += 1
        }
        toggleThinking(expanded: false)
        XCTAssertTrue(relay.buttons["Continue response"].isHittable)
        screenshot(title + " collapsed again")
        print("Synthetic round trip:", title, "down:", down, "up:", up)
    }

    func testLongReasoningScrollCollapse() {
        reasoningRoundTrip("Large completed reasoning")
    }

    func testLongParagraphScrollCollapse() {
        reasoningRoundTrip("Long reasoning paragraph")
    }

    func testLiteralTextAndSwitching() {
        for title in ["Literal reasoning text", "Large completed reasoning", "Long reasoning paragraph", "Literal reasoning text"] {
            openChat(title)
            toggleThinking(expanded: true)
            screenshot(title + " after chat switch")
            toggleThinking(expanded: false)
        }
    }

    func testReasoningSelectionMenu() {
        openChat("Literal reasoning text")
        toggleThinking(expanded: true)
        let text = relay.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '**Literal asterisks**'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.08)).press(forDuration: 1)
        XCTAssertTrue(relay.buttons["Copy"].waitForExistence(timeout: 5))
        screenshot("Synthetic reasoning selection menu")
    }

    func testUpwardPaginationKeepsMessageBodiesVisible() throws {
        openChat("Many completed messages")
        let rows = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant: **Message'"))
        func earliestMountedMessage() -> Int {
            rows.allElementsBoundByIndex.compactMap { row in
                row.label.components(separatedBy: "**").dropFirst().first?.split(separator: " ").last.flatMap { Int($0) }
            }.min() ?? 513
        }
        let first = earliestMountedMessage()
        var checkedBodies = 0
        for index in 0 ..< 100 {
            scroll(false)
            let messages = rows.allElementsBoundByIndex
            for message in messages {
                let frame = message.frame
                guard frame.minY >= 110, frame.maxY <= 780, frame.height > 130 else { continue }
                let image = relay.screenshot().image
                let rect = CGRect(x: 16, y: frame.minY + 65, width: 370, height: frame.height - 105)
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale, width: rect.width * image.scale, height: rect.height * image.scale)))
                var pixels = [UInt8](repeating: 255, count: crop.width * crop.height * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 150 && pixels[$0 + 1] < 150 && pixels[$0 + 2] < 150 }.count
                if ink <= 100 {
                    screenshot("Synthetic pagination blank body")
                }
                XCTAssertGreaterThan(ink, 100, "Visible fixture message body must contain rendered text.")
                XCTAssertLessThan(ink, crop.width * crop.height / 3, "The pixel check requires the fixture's light background.")
                checkedBodies += 1
            }
            if index.isMultiple(of: 20) {
                screenshot("Synthetic pagination step \(index)")
            }
        }
        XCTAssertGreaterThan(checkedBodies, 20)
        XCTAssertLessThan(earliestMountedMessage(), first - 30, "The test must actually page into older history.")
    }
}
