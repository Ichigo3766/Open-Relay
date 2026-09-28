import SwiftUI
import ImageIO
import XCTest

// Fresh synthetic pixels only. This protocol intercepts a reserved domain;
// these tests never contact an image server or use account credentials.
private final class ImageFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var pixels = Data()
    static var requests = 0
    static var conditional = false
    static var lastRequest: URLRequest?
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "image-fixture.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lastRequest = request
        let data = Self.pixels, conditional = Self.conditional, status = Self.status
        Self.lock.unlock()
        let unchanged = conditional && request.value(forHTTPHeaderField: "If-None-Match") != nil
        let response = HTTPURLResponse(url: request.url!, statusCode: unchanged ? 304 : status, httpVersion: nil,
                                       headerFields: conditional ? ["ETag": "synthetic-image"] : ["Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: unchanged ? Data() : data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests }
}

@MainActor final class ImageCacheVariantTests: XCTestCase {
    let cache = ImageCacheService.shared
    override func setUp() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let pixels = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1024), format: format).pngData {
            UIColor.orange.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        }
        ImageFixtureProtocol.lock.lock()
        ImageFixtureProtocol.pixels = pixels
        ImageFixtureProtocol.conditional = false
        ImageFixtureProtocol.status = 200
        ImageFixtureProtocol.lastRequest = nil
        ImageFixtureProtocol.lock.unlock()
        XCTAssertTrue(URLProtocol.registerClass(ImageFixtureProtocol.self))
    }
    override func tearDown() { URLProtocol.unregisterClass(ImageFixtureProtocol.self) }
    func url() -> URL { URL(string: "https://image-fixture.invalid/\(UUID()).png")! }

    func testSizesRemainCorrectAcrossMemoryAndDisk() async throws {
        let url = url(), before = ImageFixtureProtocol.count()
        let thumbnail = await cache.loadImage(from: url, targetPixelSize: 64)
        let original = await cache.loadImage(from: url)
        XCTAssertEqual(thumbnail?.cgImage?.width, 64)
        XCTAssertEqual(original?.cgImage?.width, 2048)
        XCTAssertTrue(cache.cachedImageSync(for: url, targetPixelSize: 64) === thumbnail)
        XCTAssertTrue(cache.cachedImageSync(for: url) === original)
        await cache.clearMemory()
        let diskThumbnail = await cache.loadImage(from: url, targetPixelSize: 64)
        let diskOriginal = await cache.loadImage(from: url)
        XCTAssertEqual(diskThumbnail?.cgImage?.width, 64)
        XCTAssertEqual(diskOriginal?.cgImage?.width, 2048)
        XCTAssertEqual(ImageFixtureProtocol.count() - before, 1)
        let bitmap = try XCTUnwrap(diskThumbnail?.cgImage)
        print("IMAGE_VARIANT disk_thumbnail_bitmap_bytes=\(bitmap.bytesPerRow * bitmap.height)")
        await cache.evict(for: url)
    }

    func testConcurrentSizesShareOneDownloadAndSameSizeDecode() async {
        for _ in 0..<4 {
            let url = url(), before = ImageFixtureProtocol.count()
            async let small = cache.loadImage(from: url, targetPixelSize: 64)
            async let medium = cache.loadImage(from: url, targetPixelSize: 128)
            async let original = cache.loadImage(from: url)
            async let secondSmall = cache.loadImage(from: url, targetPixelSize: 64)
            let results = await (small, medium, original, secondSmall)
            XCTAssertEqual(results.0?.cgImage?.width, 64)
            XCTAssertEqual(results.1?.cgImage?.width, 128)
            XCTAssertEqual(results.2?.cgImage?.width, 2048)
            XCTAssertTrue(results.0 === results.3)
            XCTAssertEqual(ImageFixtureProtocol.count() - before, 1)
            await cache.evict(for: url)
        }
    }

    func testEvictionClearsEverySize() async {
        let url = url()
        _ = await cache.loadImage(from: url, targetPixelSize: 64)
        _ = await cache.loadImage(from: url)
        await cache.evict(for: url)
        XCTAssertNil(cache.cachedImageSync(for: url, targetPixelSize: 64))
        XCTAssertNil(cache.cachedImageSync(for: url))
        let before = ImageFixtureProtocol.count()
        let fetched = await cache.loadImage(from: url, targetPixelSize: 128)
        XCTAssertEqual(fetched?.cgImage?.width, 128)
        XCTAssertEqual(ImageFixtureProtocol.count() - before, 1)
        await cache.evict(for: url)
    }

    func testReplacementInvalidatesOldVariants() async {
        let url = url()
        _ = await cache.loadImage(from: url, targetPixelSize: 64)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let replacement = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128), format: format).image {
            UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        }
        await cache.store(replacement, for: url)
        XCTAssertNil(cache.cachedImageSync(for: url, targetPixelSize: 64))
        XCTAssertTrue(cache.cachedImageSync(for: url) === replacement)
        let thumbnail = await cache.loadImage(from: url, targetPixelSize: 64)
        XCTAssertEqual(thumbnail?.cgImage?.width, 64)
        await cache.evict(for: url)
    }

    func testInvalidDownloadDoesNotPoisonDiskCache() async {
        let url = url()
        ImageFixtureProtocol.lock.lock()
        let valid = ImageFixtureProtocol.pixels
        ImageFixtureProtocol.pixels = Data("not an image".utf8)
        ImageFixtureProtocol.lock.unlock()
        let invalid = await cache.loadImage(from: url)
        XCTAssertNil(invalid)
        ImageFixtureProtocol.lock.lock(); ImageFixtureProtocol.pixels = valid; ImageFixtureProtocol.lock.unlock()
        let retry = await cache.loadImage(from: url, targetPixelSize: 64)
        XCTAssertEqual(retry?.cgImage?.width, 64)
        await cache.evict(for: url)
    }

    func testNonpositiveSizeUsesOriginal() async {
        let url = url()
        let original = await cache.loadImage(from: url, targetPixelSize: -1)
        let zero = await cache.loadImage(from: url)
        XCTAssertEqual(original?.cgImage?.width, 2048)
        XCTAssertTrue(original === zero)
        await cache.evict(for: url)
    }

    func testAuthenticationHeadersAndFailedRequestRetry() async {
        let url = url(), before = ImageFixtureProtocol.count()
        ImageFixtureProtocol.lock.lock(); ImageFixtureProtocol.status = 401; ImageFixtureProtocol.lock.unlock()
        let denied = await cache.loadImage(from: url, authToken: "synthetic-token",
                                          customHeaders: ["X-Fixture": "synthetic"], targetPixelSize: 64)
        XCTAssertNil(denied)
        ImageFixtureProtocol.lock.lock()
        let request = ImageFixtureProtocol.lastRequest
        ImageFixtureProtocol.status = 200
        ImageFixtureProtocol.lock.unlock()
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Fixture"), "synthetic")
        let retry = await cache.loadImage(from: url, authToken: "synthetic-token", targetPixelSize: 64)
        XCTAssertEqual(retry?.cgImage?.width, 64)
        XCTAssertEqual(ImageFixtureProtocol.count() - before, 2)
        await cache.evict(for: url)
    }

    func testTruncatedDownloadIsNotPersistedWithValidator() async throws {
        let url = url()
        ImageFixtureProtocol.lock.lock(); let valid = ImageFixtureProtocol.pixels; ImageFixtureProtocol.lock.unlock()
        let truncated = try XCTUnwrap((33..<valid.count).lazy.compactMap { length -> Data? in
            let prefix = Data(valid.prefix(length))
            guard let source = CGImageSourceCreateWithData(prefix as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  UIImage(data: prefix) == nil else { return nil }
            return prefix
        }.first, "Synthetic PNG must expose a recognized but undecodable truncated header")
        ImageFixtureProtocol.lock.lock()
        ImageFixtureProtocol.pixels = truncated
        ImageFixtureProtocol.conditional = true
        ImageFixtureProtocol.lock.unlock()
        let first = await cache.loadImage(from: url)
        XCTAssertNil(first)
        ImageFixtureProtocol.lock.lock(); ImageFixtureProtocol.pixels = valid; ImageFixtureProtocol.lock.unlock()
        let retry = await cache.loadImage(from: url)
        XCTAssertEqual(retry?.cgImage?.width, 2048, "A failed decode must not retain a validator that turns retries into 304 failures")
        await cache.evict(for: url)
    }
}
