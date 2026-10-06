import Foundation

// MARK: - Low-level byte helpers

extension DetailsBlockScanner {

    struct Fence { let char: UInt8; let count: Int }

    enum OpenTag { case complete(end: Int), partial }

    nonisolated static let newline = UInt8(ascii: "\n")
    nonisolated static let lt = UInt8(ascii: "<")
    nonisolated static let gtByte = UInt8(ascii: ">")
    nonisolated static let slash = UInt8(ascii: "/")
    nonisolated static let eq = UInt8(ascii: "=")
    nonisolated static let dquote = UInt8(ascii: "\"")
    nonisolated static let squote = UInt8(ascii: "'")
    nonisolated static let backslash = UInt8(ascii: "\\")
    nonisolated static let backtick = UInt8(ascii: "`")
    nonisolated static let tilde = UInt8(ascii: "~")
    nonisolated static let openPrefix = Array("<details".utf8)
    nonisolated static let closePrefix = Array("</details".utf8)

    nonisolated static func decode(_ s: [UInt8], _ r: Range<Int>) -> String {
        String(decoding: s[r], as: UTF8.self)
    }

    nonisolated static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }

    nonisolated static func lowercase(_ c: UInt8) -> UInt8 { (0x41...0x5A).contains(c) ? c + 0x20 : c }

    /// Byte length of a zero-width character at `i` (U+200B/C/D, U+2060, U+FEFF).
    nonisolated static func zeroWidthLength(_ s: [UInt8], _ i: Int) -> Int? {
        guard i + 2 < s.count else { return nil }
        if s[i] == 0xE2, s[i + 1] == 0x80, (0x8B...0x8D).contains(s[i + 2]) { return 3 }
        if s[i] == 0xE2, s[i + 1] == 0x81, s[i + 2] == 0xA0 { return 3 }
        if s[i] == 0xEF, s[i + 1] == 0xBB, s[i + 2] == 0xBF { return 3 }
        return nil
    }

    /// Case-insensitive match of a lowercase ASCII `prefix` at `i`.
    nonisolated static func matches(_ s: [UInt8], at i: Int, _ prefix: [UInt8]) -> Bool {
        guard i >= 0, i + prefix.count <= s.count else { return false }
        for k in 0..<prefix.count where lowercase(s[i + k]) != prefix[k] { return false }
        return true
    }

    /// The byte after a tag name must end it (`<detailsview` is not a tag).
    nonisolated static func isTagBoundary(_ s: [UInt8], _ i: Int) -> Bool {
        i >= s.count || isSpace(s[i]) || s[i] == newline || s[i] == gtByte || s[i] == slash
    }

    nonisolated static func indexOf(_ byte: UInt8, in s: [UInt8], from: Int) -> Int? {
        var i = from
        while i < s.count { if s[i] == byte { return i }; i += 1 }
        return nil
    }

    nonisolated static func lineEnd(_ s: [UInt8], from i: Int) -> Int {
        indexOf(newline, in: s, from: i) ?? s.count
    }

    /// Parses a `<details …>` opening tag at `i`, quote-aware.
    /// `.partial` means the tag (or the `<details` name itself) is still
    /// arriving at the end of the text.
    nonisolated static func openingTag(_ s: [UInt8], at i: Int) -> OpenTag? {
        let remaining = s.count - i
        if remaining < openPrefix.count + 1 {
            // "<d", "<deta", "<details" right at the end: still streaming in.
            guard remaining >= 2 else { return nil }
            let tail = s[i...].map(lowercase)
            return Array(openPrefix.prefix(tail.count)) == tail ? .partial : nil
        }
        guard matches(s, at: i, openPrefix), isTagBoundary(s, i + openPrefix.count) else { return nil }
        var j = i + openPrefix.count
        var quote: UInt8?
        var expectValue = false
        while j < s.count {
            let c = s[j]
            if let q = quote {
                if c == backslash { j += 2; continue }
                if c == q { quote = nil }
            } else if c == gtByte {
                return .complete(end: j + 1)
            } else if c == newline, j + 1 < s.count, s[j + 1] == newline {
                return nil   // a blank line can't sit inside an unquoted tag: it's prose
            } else if c == eq {
                expectValue = true
            } else if (c == dquote || c == squote) && expectValue {
                quote = c
                expectValue = false
            } else if !isSpace(c) && c != newline {
                expectValue = false
            }
            j += 1
        }
        return .partial
    }
}
