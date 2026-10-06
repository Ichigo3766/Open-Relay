import Foundation

// MARK: - Code spans, close matching, attributes

extension DetailsBlockScanner {

    /// A fenced-code open/close at a line's first content byte.
    nonisolated static func fenceTransition(_ s: [UInt8], at i: Int, current: Fence?) -> (fence: Fence?, lineEnd: Int)? {
        let c = s[i]
        guard c == backtick || c == tilde else { return nil }
        var run = 0
        while i + run < s.count, s[i + run] == c { run += 1 }
        guard run >= 3 else { return nil }
        let end = lineEnd(s, from: i + run)
        if let f = current {
            guard f.char == c, run >= f.count, s[(i + run)..<end].allSatisfy(isSpace) else { return nil }
            return (nil, end)
        }
        if c == backtick, s[(i + run)..<end].contains(backtick) { return nil }   // ```inline``` span
        return (Fence(char: c, count: run), end)
    }

    /// End of an inline code span starting at a backtick run (same line only).
    /// Unmatched backticks are literal and only the run itself is skipped.
    nonisolated static func endOfInlineCode(_ s: [UInt8], at i: Int) -> Int {
        var run = 0
        while i + run < s.count, s[i + run] == backtick { run += 1 }
        var j = i + run
        while j < s.count, s[j] != newline {
            if s[j] == backtick {
                var closeRun = 0
                while j + closeRun < s.count, s[j + closeRun] == backtick { closeRun += 1 }
                if closeRun == run { return j + closeRun }
                j += closeRun
            } else {
                j += 1
            }
        }
        return i + run
    }

    /// True when a byte range contains a structural `<details type=…>` tag.
    nonisolated static func spanContainsStructuralTag(_ s: [UInt8], _ r: Range<Int>) -> Bool {
        var k = r.lowerBound
        while k < r.upperBound {
            if s[k] == lt, case .complete(let end) = openingTag(s, at: k) {
                if let type = attributes(in: decode(s, k..<end))["type"]?.lowercased(),
                   structuralTypes.contains(type) { return true }
            }
            k += 1
        }
        return false
    }

    /// Finds the `</details>` closing a block whose body starts at `start`.
    /// `codeAware` skips fenced and inline code inside the body.
    nonisolated static func findClose(_ s: [UInt8], from start: Int, codeAware: Bool) -> (start: Int, end: Int)? {
        var depth = 1
        var j = start
        var atLineStart = false
        var fence: Fence?
        while j < s.count {
            let c = s[j]
            if c == newline { atLineStart = true; j += 1; continue }
            if atLineStart {
                if isSpace(c) { j += 1; continue }
                if let w = zeroWidthLength(s, j) { j += w; continue }
                atLineStart = false
                if codeAware, let next = fenceTransition(s, at: j, current: fence) {
                    fence = next.fence
                    j = next.lineEnd
                    continue
                }
            }
            if codeAware {
                if fence != nil { j = lineEnd(s, from: j); continue }
                if c == backtick { j = endOfInlineCode(s, at: j); continue }
            }
            if c == lt {
                if case .complete(let end) = openingTag(s, at: j) {
                    depth += 1
                    j = end
                    continue
                }
                if matches(s, at: j, closePrefix), isTagBoundary(s, j + closePrefix.count) {
                    guard let gt = indexOf(gtByte, in: s, from: j + closePrefix.count) else { return nil }
                    depth -= 1
                    if depth == 0 { return (j, gt + 1) }
                    j = gt + 1
                    continue
                }
            }
            j += 1
        }
        return nil
    }

    /// Parses the attributes of an opening tag. Names are lowercased; boolean
    /// attributes (e.g. `open`) map to `""`. The first occurrence wins.
    nonisolated static func attributes(in openTag: String) -> [String: String] {
        let s = Array(openTag.utf8)
        var i = min(openPrefix.count, s.count)
        var result: [String: String] = [:]
        func skipSpace() { while i < s.count, isSpace(s[i]) || s[i] == newline { i += 1 } }
        while i < s.count {
            while i < s.count, isSpace(s[i]) || s[i] == newline || s[i] == slash { i += 1 }
            guard i < s.count, s[i] != gtByte else { break }
            let nameStart = i
            while i < s.count, !isSpace(s[i]), s[i] != newline, s[i] != eq, s[i] != gtByte, s[i] != slash { i += 1 }
            let name = decode(s, nameStart..<i).lowercased()
            skipSpace()
            var value = ""
            if i < s.count, s[i] == eq {
                i += 1
                skipSpace()
                if i < s.count, s[i] == dquote || s[i] == squote {
                    let q = s[i]
                    i += 1
                    let valueStart = i
                    while i < s.count, s[i] != q { i += (s[i] == backslash && i + 1 < s.count) ? 2 : 1 }
                    value = decode(s, valueStart..<min(i, s.count))
                    i += 1
                } else {
                    let valueStart = i
                    while i < s.count, !isSpace(s[i]), s[i] != newline, s[i] != gtByte { i += 1 }
                    value = decode(s, valueStart..<i)
                }
            }
            if !name.isEmpty, result[name] == nil { result[name] = value }
            if i == nameStart { i += 1 }   // always make progress
        }
        return result
    }
}
