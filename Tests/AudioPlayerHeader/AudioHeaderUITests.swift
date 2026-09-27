import XCTest
import UIKit

/// Run in a UI-test runner against an app signed into the loopback audio fixture.
final class AudioHeaderUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")

    func testLight() throws { try exerciseHeader(appearance: "light") }
    func testDark() throws { try exerciseHeader(appearance: "dark") }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Accessibility can report a hittable button even when its glyph is invisible.
    private func verifyCloseIsDrawn(_ close: XCUIElement) {
        let frame = close.frame.insetBy(dx: 4, dy: 4)
        let image = app.screenshot().image.cgImage!
        let scale = CGFloat(image.width) / app.frame.width
        let crop = image.cropping(to: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                            width: frame.width * scale, height: frame.height * scale))!
        let width = crop.width, height = crop.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var darkest = 255, brightest = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let brightness = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
            darkest = min(darkest, brightness)
            brightest = max(brightest, brightness)
        }
        XCTAssertGreaterThan(brightest - darkest, 20, "The close glyph must visibly contrast with its background.")
    }

    private func exerciseHeader(appearance: String) throws {
        continueAfterFailure = false
        app.launchArguments = ["-openui.appearance.mode", appearance, "-ttsEngine", "server", "-hiddenMessageActions", ""]
        app.launch()
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        app.buttons["New Chat"].firstMatch.tap()
        let selector = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Synthetic Test Model'")).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 10), "Use only the synthetic fixture, never a personal account.")
        menu.tap()
        let chat = app.buttons["Audio Header Demo"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        let speak = app.buttons["Speak"].firstMatch
        XCTAssertTrue(speak.waitForExistence(timeout: 10))
        let original = selector.frame

        func verifyHeader(below playerElement: XCUIElement) {
            XCTAssertTrue(selector.isHittable)
            XCTAssertTrue(menu.isHittable)
            XCTAssertTrue(app.buttons["More chat actions"].isHittable)
            XCTAssertEqual(selector.frame, original)
            XCTAssertGreaterThan(playerElement.frame.minY, menu.frame.maxY,
                                 "The player must sit below, not overlap, the header controls.")
        }

        for mode in ["success", "failure"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/fixture/audio-control")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
            let ready = expectation(description: "Configure synthetic audio")
            URLSession.shared.dataTask(with: request) { data, response, error in
                XCTAssertNil(error)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                XCTAssertEqual(json?["synthetic"] as? Bool, true)
                ready.fulfill()
            }.resume()
            wait(for: [ready], timeout: 10)
            speak.tap()
            let preparing = app.staticTexts["Preparing…"].firstMatch
            XCTAssertTrue(preparing.waitForExistence(timeout: 3))
            capture("\(appearance)-preparing")
            verifyHeader(below: preparing)
            let close = app.buttons["Close audio player"]
            XCTAssertTrue(close.isHittable)
            verifyCloseIsDrawn(close)
            // 12-point padding + 32-point icon + 8-point gap before the label.
            XCTAssertEqual((preparing.frame.minX - 52 + close.frame.maxX + 12) / 2,
                           app.frame.midX, accuracy: 2)
            preparing.tap()
            if mode == "success" {
                XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 15))
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES '^0:0[1-9]$'")).firstMatch.waitForExistence(timeout: 10),
                              "Playback must advance beyond zero, not merely buffer audio.")
                verifyHeader(below: close)
                app.buttons["Pause"].firstMatch.tap()
                XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
                verifyHeader(below: close)
                verifyCloseIsDrawn(close)
                capture("\(appearance)-paused-expanded")
                app.buttons["Play"].firstMatch.tap()
                XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
                selector.tap()
                XCTAssertTrue(app.staticTexts["Models"].firstMatch.waitForExistence(timeout: 5))
                capture("\(appearance)-model-picker")
                app.buttons["Done"].tap()
                XCTAssertTrue(close.waitForExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Couldn’t prepare audio'")).firstMatch.waitForExistence(timeout: 15))
                verifyHeader(below: close)
            }
            close.tap()
            XCTAssertTrue(selector.isHittable)
            XCTAssertEqual(selector.frame, original)
            XCTAssertFalse(close.exists)
        }
        capture("\(appearance)-closed")
    }
}
