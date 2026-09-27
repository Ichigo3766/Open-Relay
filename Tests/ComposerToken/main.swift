import Foundation
import Darwin

func oldQuery(_ text: String, _ offset: Int, _ symbol: Character) -> String? {
    let prefix = String(text.prefix(offset))
    guard let index = prefix.lastIndex(of: symbol) else { return nil }
    let position = prefix.distance(from: prefix.startIndex, to: index)
    guard position == 0 || prefix[prefix.index(before: index)].isWhitespace else { return nil }
    let query = String(prefix[prefix.index(after: index)...])
    return query.contains(where: { $0.isWhitespace || $0.isNewline }) ? nil : query
}

func reference(_ text: String, _ offset: Int) -> String? {
    guard offset >= 0, let range = Range(NSRange(location: 0, length: offset), in: text) else { return nil }
    let words = text[range].split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace })
    guard let word = words.last, let first = word.first, "#@/$".contains(first),
          !word.dropFirst().contains(first) else { return nil }
    return String(word)
}

func signature(_ token: ComposerToken?) -> String? { token.map { String($0.symbol) + $0.query } }
var checks = 0
let examples = ["", "#", "#paper", "word #paper", "word#paper", "#paper ", "#paper#card",
                "@model", "/command", "$skill", "$one@two", "/one/two", "a\n#paper",
                "🌦️ #paper more", "👨‍👩‍👧‍👦 @rover later", "cafe\u{301} /test end", "星 $map end"]
for text in examples {
    for index in text.indices + [text.endIndex] {
        let offset = text[..<index].utf16.count
        precondition(signature(ComposerToken(text: text, utf16Offset: offset)) == reference(text, offset))
        checks += 1
    }
}
precondition(ComposerToken(text: "😀 #x", utf16Offset: 1) == nil)
precondition(ComposerToken(text: "#x", utf16Offset: -1) == nil)
precondition(ComposerToken(text: "#x", utf16Offset: 100) == nil)
let unicode = "🌦️ #paper more"
let caret = "🌦️ #pap".utf16.count
precondition(ComposerToken(text: unicode, utf16Offset: caret)?.query == "pap")
precondition(oldQuery(unicode, caret, "#") != "pap")
print("REPRO old UTF16 cursor handling differs from the expected token; candidate correct")

var seed: UInt64 = 123456789
let alphabet = Array("ab #@/$\n\t🌦️星é")
for _ in 0..<1500 {
    var text = ""
    for _ in 0..<40 {
        seed = seed &* 6364136223846793005 &+ 1
        text.append(alphabet[Int(seed % UInt64(alphabet.count))])
    }
    for index in text.indices + [text.endIndex] {
        let offset = text[..<index].utf16.count
        precondition(signature(ComposerToken(text: text, utf16Offset: offset)) == reference(text, offset))
        checks += 1
    }
}
print("CHECKS \(checks + 5) passed")

if CommandLine.arguments.contains("--benchmark") {
    func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    var checksum = 0
    for (kind, unit) in [("ascii", "invented paper rover "), ("unicode", "星🌦️e\u{301} rover "), ("single-token", "x")] {
      for count in [64, 8192, 65536, 262144] {
        let text = (kind == "single-token" ? "#" : "") + String(repeating: unit, count: max(1, count / unit.count)) + (kind == "single-token" ? "map" : "#map")
        let offset = text.utf16.count
        for candidate in [false, true, true, false] {
            var timings: [Double] = []
            let batch = candidate && kind != "single-token" ? 128 : 4
            for iteration in 0..<12 {
                let start = cpu()
                for item in 0..<batch {
                    let cursor = offset - item % 2
                    if candidate {
                        checksum += ComposerToken(text: text, utf16Offset: cursor)?.query.count ?? 0
                    } else {
                        for symbol in "#@/$" { checksum += oldQuery(text, cursor, symbol)?.count ?? 0 }
                    }
                }
                if iteration > 0 { timings.append((cpu() - start) * 1000 / Double(batch)) }
            }
            timings.sort()
            print("TOKEN_BENCH kind=\(kind) chars=\(text.count) candidate=\(candidate) median_ms=\(timings[5]) max_ms=\(timings.last!)")
        }
      }
    }
    print("CHECKSUM \(checksum)")
}
