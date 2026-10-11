import XCTest
import SwiftUI

@MainActor final class CachedDetailsLoaderTests: XCTestCase {
    func testInitialPlaceholderStartsOneRequestAndShowsFailure() async throws {
        var requests = 0
        let loader = CachedDetailsLoader().environment(\.loadCachedDetails, {
            requests += 1
            throw URLError(.notConnectedToInternet)
        })
        let controller = UIHostingController(rootView: loader)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(requests, 1, "The initial placeholder must mount and start loading")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(requests, 1, "Showing retry must not start a request loop")
    }
}
