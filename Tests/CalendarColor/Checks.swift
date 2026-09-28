import Foundation
import SwiftUI

@main struct Checks {
    @MainActor static func main() throws {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(name)") }
        }
        func calendar(_ color: String) -> String {
            "{\"id\":\"demo-calendar\",\"user_id\":\"demo-user\",\"name\":\"Synthetic calendar\",\"is_default\":true,\"is_system\":false\(color)}"
        }
        for color in [",\"color\":null", ""] {
            let value = try? JSONDecoder().decode(OWCalendar.self, from: Data(calendar(color).utf8))
            check(value != nil, "nullable or missing color does not reject calendar")
            check(value?.swiftUIColor == .blue, "nullable or missing color uses existing blue fallback")
            if let value {
                let roundTrip = try JSONDecoder().decode(OWCalendar.self, from: JSONEncoder().encode(value))
                check(roundTrip.swiftUIColor == .blue, "nullable color survives encode/decode")
            }
        }
        let colored = try JSONDecoder().decode(OWCalendar.self, from: Data(calendar(",\"color\":\"#2468AC\"").utf8))
        check(colored.swiftUIColor == Color(hex: "#2468AC"), "configured color still renders")
        let invalid = try JSONDecoder().decode(OWCalendar.self, from: Data(calendar(",\"color\":\"invalid\"").utf8))
        check(invalid.swiftUIColor == .blue, "invalid hex retains fallback")
        let page = Data("[\(calendar(",\"color\":null")),\(calendar(",\"color\":\"#2468AC\""))]".utf8)
        check((try? JSONDecoder().decode([OWCalendar].self, from: page))?.count == 2, "one uncolored calendar does not reject list")
        print("\(checks - failures)/\(checks) calendar checks passed")
        if failures > 0 { exit(1) }
    }
}
