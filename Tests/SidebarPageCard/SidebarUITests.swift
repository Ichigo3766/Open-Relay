import XCTest
import UIKit

final class SidebarUITests: XCTestCase {
    private func launch(_ theme: String, pinned: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
        app.launchArguments = ["-openui.appearance.mode", theme, "-ipad_sidebar_always_shown", pinned ? "YES" : "NO"]
        app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 2) {
            let deny = system.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND label != 'Allow'")).firstMatch
            if deny.exists { deny.tap() }
        }
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.staticTexts["Connect to your OpenWebUI server"].waitForExistence(timeout: 2) {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("http://127.0.0.1:18189")
            app.buttons["Connect"].tap()
        }
        if !app.buttons["Menu"].waitForExistence(timeout: 3) {
            if !app.secureTextFields.firstMatch.exists {
                XCTAssertTrue(app.staticTexts["Version 0.0.0-fixture"].waitForExistence(timeout: 10))
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            }
            let email = app.textFields.firstMatch
            XCTAssertTrue(email.waitForExistence(timeout: 5))
            email.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
                email.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            email.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
            if app.buttons["Skip"].waitForExistence(timeout: 10) { app.buttons["Skip"].tap() }
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 15))
        return app
    }

    private func chat(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapVisibleMenu(_ app: XCUIApplication) {
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertFalse(menu.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(menu.frame))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func pixels(_ image: UIImage, _ rect: CGRect, screenWidth: CGFloat) -> [UInt8] {
        let scale = CGFloat(image.cgImage!.width) / screenWidth
        let crop = image.cgImage!.cropping(to: CGRect(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded(),
                                                    width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded()))!
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                    bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return bytes
    }

    private func exercise(_ theme: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(theme)
        if !chat(app, "Paper garden").isHittable { app.buttons["Menu"].tap() }
        XCTAssertTrue(chat(app, "Paper garden").waitForExistence(timeout: 10))
        chat(app, "Paper garden").tap()
        let answer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1)
        let closed = app.screenshot().image
        capture(app, "\(theme)-closed")
        app.buttons["Menu"].tap()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "\(theme)-open")
        let opened = app.screenshot().image

        // The sidebar must remain continuous behind the rounded page corners;
        // the old full-height divider must not extend into those cutouts.
        let offset = min(app.frame.width * (app.frame.width >= 768 ? 0.40 : 0.82), 360)
        for y in [8.0, app.frame.height - 24] {
            let edge = CGRect(x: offset - 0.5, y: y, width: 0.5, height: 16)
            let border = pixels(opened, edge, screenWidth: app.frame.width)
            let adjacent = pixels(opened, edge.offsetBy(dx: -3, dy: 0), screenWidth: app.frame.width)
            let contrast = zip(border, adjacent).enumerated().filter { $0.offset % 4 != 3 }
                .map { abs(Int($0.element.0) - Int($0.element.1)) }.max()!
            XCTAssertLessThanOrEqual(contrast, 2, "No straight sidebar divider at the rounded page corner (y=\(y))")
        }

        let pixel = app.frame.width / CGFloat(opened.cgImage!.width)
        func brightness(_ image: UIImage, x: CGFloat) -> Double {
            let sample = pixels(image, CGRect(x: x, y: app.frame.height * 0.65, width: pixel, height: 4),
                                screenWidth: app.frame.width)
            let channels = sample.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
            return channels.reduce(0, +) / Double(channels.count)
        }
        let interior = brightness(opened, x: offset + 3 * pixel)
        let outlineContrast = (brightness(opened, x: offset) - interior) * (theme == "dark" ? 1 : -1)
        XCTAssertGreaterThan(outlineContrast, 2, "The open card has a faint outline")
        XCTAssertLessThan(outlineContrast, 30, "The outline remains low contrast")
        XCTAssertEqual(brightness(opened, x: offset + pixel), interior, accuracy: 1, "The stroke is only one physical pixel wide")
        XCTAssertEqual(brightness(closed, x: 0), brightness(closed, x: 3 * pixel), accuracy: 1, "No outline when closed")

        // Compare the same text strip before and after translation: it must not
        // be blurred, dimmed, scaled, or shifted vertically by opening the sidebar.
        let sample = CGRect(x: 16, y: app.frame.height * 0.35, width: 36, height: 220)
        let before = pixels(closed, sample, screenWidth: app.frame.width)
        let after = pixels(opened, sample.offsetBy(dx: offset, dy: 0), screenWidth: app.frame.width)
        XCTAssertEqual(before.count, after.count)
        XCTAssertGreaterThan(Set(before).count, 16, "The sample must contain text, not an empty background")
        let difference = zip(before, after).enumerated().filter { $0.offset % 4 != 3 }
            .reduce(0.0) { $0 + Double(abs(Int($1.element.0) - Int($1.element.1))) }
            / Double(before.count / 4 * 3)
        print("SIDEBAR_PIXEL_DIFFERENCE theme=\(theme) mean=\(difference)")
        XCTAssertLessThan(difference, 8, "Sidebar opening must preserve crisp, undimmed text")

        // Exposed page taps close the sidebar without activating chat controls.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Menu"].isHittable)
        for _ in 0..<3 {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            XCTAssertTrue(chat(app, "Lighthouse sketch").isHittable)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: edge)
            XCTAssertTrue(app.buttons["Menu"].isHittable)
        }
        app.buttons["Menu"].tap()
        chat(app, "Lighthouse sketch").tap()
        let lighthouse = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:' AND label CONTAINS 'An imaginary lighthouse'")).firstMatch
        XCTAssertTrue(lighthouse.waitForExistence(timeout: 10))
        capture(app, "\(theme)-switched-chat")
        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, "\(theme)-keyboard")
        // Verify the actual action after restoring a scrolled chat, rather than
        // relying on the safe-area toolbar's accessibility hit-point estimate.
        tapVisibleMenu(app)
        XCTAssertTrue(chat(app, "Paper garden").isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertFalse(chat(app, "Paper garden").isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        capture(app, "\(theme)-landscape-closed")
        tapVisibleMenu(app)
        XCTAssertTrue(chat(app, "Paper garden").isHittable)
        capture(app, "\(theme)-landscape-open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertFalse(chat(app, "Paper garden").isHittable)
        XCUIDevice.shared.orientation = .portrait
    }

    func testLightSidebar() { exercise("light") }
    func testDarkSidebar() { exercise("dark") }

    func testDarkSidebarBackground() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Page-card sidebar requires iOS 26") }
        let app = prepareSidebarBenchmark("dark")
        tapVisibleMenu(app)
        capture(app, "dark-sidebar-background")
        let image = app.screenshot().image
        // Empty sidebar and footer areas use the same very dark gray surface.
        for y in [0.75, 0.94] {
            let sample = pixels(image, CGRect(x: app.frame.width * 0.4, y: app.frame.height * y,
                                              width: 8, height: 8), screenWidth: app.frame.width)
            for channel in 0..<3 {
                let values = stride(from: channel, to: sample.count, by: 4).map { Double(sample[$0]) }
                XCTAssertEqual(values.reduce(0, +) / Double(values.count), 18, accuracy: 1)
            }
        }
    }

    private func prepareSidebarBenchmark(_ theme: String = "light") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(theme)
        if !chat(app, "Paper garden").isHittable { tapVisibleMenu(app) }
        chat(app, "Paper garden").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch.waitForExistence(timeout: 10))
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    func testSidebarPerformance() {
        let app = prepareSidebarBenchmark()
        let frame = app.frame
        let menu = app.buttons["Menu"].frame
        let open = app.coordinate(withNormalizedOffset: CGVector(dx: menu.midX / frame.width, dy: menu.midY / frame.height))
        let close = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        let options = XCTMeasureOptions()
        options.iterationCount = 8
        var metrics: [XCTMetric] = [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            for _ in 0..<2 {
                open.tap()
                close.tap()
            }
        }
        XCTAssertFalse(chat(app, "Paper garden").isHittable)
        XCTAssertTrue(app.buttons["Menu"].isHittable)
    }

    func testSidebarVideo() { recordSidebar("light") }
    func testDarkSidebarVideo() { recordSidebar("dark") }

    private func recordSidebar(_ theme: String) {
        let app = prepareSidebarBenchmark(theme)
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "\(theme)-video-closed")
        for index in 0..<3 {
            print("SIDEBAR_VIDEO_OPEN \(index) \(Date.timeIntervalSinceReferenceDate)")
            tapVisibleMenu(app)
            Thread.sleep(forTimeInterval: 1)
            print("SIDEBAR_VIDEO_CLOSE \(index) \(Date.timeIntervalSinceReferenceDate)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(chat(app, "Paper garden").isHittable)
    }

    func testPinnedIPadSidebar() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad-only pinned layout") }
        XCUIDevice.shared.orientation = .portrait
        let app = launch("light", pinned: true)
        XCTAssertTrue(chat(app, "Paper garden").waitForExistence(timeout: 10))
        chat(app, "Paper garden").tap()
        XCTAssertTrue(chat(app, "Lighthouse sketch").isHittable)
        capture(app, "pinned-sidebar")
        app.buttons["Menu"].tap()
        XCTAssertFalse(chat(app, "Lighthouse sketch").isHittable)
        app.buttons["Menu"].tap()
        XCTAssertTrue(chat(app, "Lighthouse sketch").isHittable)
    }
}
