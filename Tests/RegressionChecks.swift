import XCTest
import UIKit
import SwiftUI

@MainActor final class RegressionChecks: XCTestCase {
    let uris = ["data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAA6nRFWHRTeW50aGV0aWMASW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiDjc1l9AAAAEUlEQVR4nGP4L2KDFTEMLQkA6mhTwf1+SM0AAAAASUVORK5CYII=", "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAA6nRFWHRTeW50aGV0aWMASW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiBJbnZlbnRlZCBNb29uIEludmVudGVkIE1vb24gSW52ZW50ZWQgTW9vbiDjc1l9AAAAEUlEQVR4nGMQcfuAFTEMLQkABahSgSoFZIIAAAAASUVORK5CYII="]
    func testDifferentValidImagesHaveDistinctKeys() {
        let first = URL(string: uris[0])!, second = URL(string: uris[1])!
        XCTAssertEqual(uris[0].count, uris[1].count)
        XCTAssertEqual(uris[0].prefix(80), uris[1].prefix(80))
        let firstKey = InlineImageFixture.base64CacheKey(for: first)
        let secondKey = InlineImageFixture.base64CacheKey(for: second)
        XCTAssertNotEqual(firstKey, secondKey)
        let red = InlineImageFixture.decodeDataURIString(uris[0])!
        let blue = InlineImageFixture.decodeDataURIString(uris[1])!
        XCTAssertEqual(red.cgImage!.width, 8); XCTAssertEqual(blue.cgImage!.width, 8)
        InlineImageFixture.store(red, for: firstKey)
        XCTAssertNil(InlineImageFixture.base64ImageCache.object(forKey: secondKey))
        InlineImageFixture.store(blue, for: secondKey)
        XCTAssertTrue(InlineImageFixture.base64ImageCache.object(forKey: firstKey) === red)
        XCTAssertTrue(InlineImageFixture.base64ImageCache.object(forKey: secondKey) === blue)
    }
    func testMalformedDataAndRepeatedLookup() {
        for value in ["data:text/plain;base64,SGVsbG8=", "data:image/png;base64,not-an-image", "https://example.test/fictional.png", "data:image/png,invalid"] {
            XCTAssertNil(InlineImageFixture.decodeDataURIString(value))
        }
        let uri = URL(string: uris[0])!
        XCTAssertEqual(InlineImageFixture.base64CacheKey(for: uri), InlineImageFixture.base64CacheKey(for: uri))
    }
    func testDecodedRasterBudgetAndHashCost() {
        InlineImageFixture.base64ImageCache.removeAllObjects()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        for i in 0..<12 { InlineImageFixture.store(image, for: "invented-\(i)" as NSString) }
        let retained = (0..<12).filter { InlineImageFixture.base64ImageCache.object(forKey: "invented-\($0)" as NSString) != nil }.count
        print("SYNTHETIC_MEASUREMENT decoded_raster_retained_bytes \(retained * image.cgImage!.bytesPerRow * image.cgImage!.height)")
        // NSCache's cost limit is advisory; do not assert a platform-specific eviction order.
        let large = URL(string: "data:image/png;base64," + String(repeating: "A", count: 2 * 1024 * 1024))!
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { _ = InlineImageFixture.base64CacheKey(for: large) }
        print("SYNTHETIC_MEASUREMENT full_URI_2MiB_hash_mean_ms \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e7)")
    }
    func testSyntheticImagesRemainDistinctOnScreen() async throws {
        let keys = uris.map { InlineImageFixture.base64CacheKey(for:URL(string:$0)!) }
        for i in uris.indices { InlineImageFixture.store(InlineImageFixture.decodeDataURIString(uris[i])!,for:keys[i]) }
        let images = keys.map { InlineImageFixture.base64ImageCache.object(forKey:$0)! }
        let controller = UIHostingController(rootView: VStack(spacing:20) {
            Text("Synthetic image cache fixture").font(.headline)
            Text("Same URI length and prefix; different pixels.")
            HStack { ForEach(0..<2) { index in
                VStack { Image(uiImage:images[index]).resizable().interpolation(.none).frame(width:150,height:150); Text(index == 0 ? "Invented red moon" : "Invented blue moon") }
            } }
        }.padding().frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.white))
        let window = UIWindow(windowScene:UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.frame = UIScreen.main.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for:.seconds(2)); window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "synthetic-distinct-images"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(images[0] === images[1])
        try await Task.sleep(for:.seconds(2))
    }

}
