import Foundation

@main struct RegressionChecks {
    static func main() {
        let cases: [(String, CGFloat, CGFloat, CGFloat, Bool, Bool, Bool)] = [
            ("bottom of long chat", 10000, 800, 9200, true, false, false),
            ("40pt from bottom", 10000, 800, 9160, true, false, false),
            ("60pt threshold", 10000, 800, 9140, true, false, false),
            ("61pt above bottom", 10000, 800, 9139, true, false, true),
            ("reading earlier content", 10000, 800, 4000, true, false, true),
            ("bottom overscroll", 10000, 800, 9300, true, false, false),
            ("short content", 300, 800, 0, true, false, false),
            ("nonstreaming chat", 10000, 800, 4000, false, false, false),
            ("already paused", 10000, 800, 9200, true, true, true),
            ("top of long chat", 10000, 800, 0, true, false, true),
            ("negative top overscroll", 10000, 800, -20, true, false, true)
        ]
        var failures = 0
        for (name, height, viewport, offset, streaming, paused, expected) in cases {
            let actual = decelerate(height: height, viewport: viewport, offset: offset, streaming: streaming, paused: paused)
            if actual != expected {
                print("FAIL: \(name): paused=\(actual), expected=\(expected)")
                failures += 1
            }
        }
        print("\(cases.count - failures)/\(cases.count) synthetic deceleration checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
