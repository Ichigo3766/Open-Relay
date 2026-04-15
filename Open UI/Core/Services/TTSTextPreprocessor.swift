import Foundation
import NaturalLanguage

/// Preprocesses text for TTS synthesis by stripping markdown, removing
/// tool call information, code blocks, and splitting into speakable chunks.
///
/// Matches the Flutter `ConduitMarkdownPreprocessor.toPlainText` and
/// `TextToSpeechService.splitTextForSpeech` behavior.
enum TTSTextPreprocessor {


    // MARK: - Script Detection

    /// Returns true if the text is predominantly non-Latin (Hindi, Japanese, Chinese, etc.).
    /// Used to skip English-specific preprocessing transforms that would mangle non-Latin scripts.
    private static func isNonLatinScript(_ text: String) -> Bool {
        let sample = text.prefix(200)
        var nonLatinCount = 0
        var letterCount = 0
        for scalar in sample.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            letterCount += 1
            // Non-Latin: Devanagari (hi), CJK (zh, ja), Arabic, Hebrew, Korean, etc.
            let v = scalar.value
            let isLatin = (0x0041...0x007A).contains(v)   // Basic Latin A-Z, a-z
                || (0x00C0...0x024F).contains(v)           // Latin Extended
                || (0x1E00...0x1EFF).contains(v)           // Latin Extended Additional
            if !isLatin { nonLatinCount += 1 }
        }
        guard letterCount > 3 else { return false }
        return Double(nonLatinCount) / Double(letterCount) > 0.5
    }

    // MARK: - Full Pipeline

    /// Prepares raw assistant response text for speech synthesis.
    /// Strips markdown, removes tool calls and code blocks, cleans whitespace.
    /// For non-Latin scripts (Hindi, Japanese, Chinese, etc.), English-specific
    /// transforms (abbreviation expansion, bullet→sentence, compound hyphens) are skipped
    /// to avoid mangling text that Kokoro's language-specific G2P will handle natively.
    static func prepareForSpeech(_ text: String) -> String {
        var result = text

        // 1. Remove code blocks (```...```)
        result = removeCodeBlocks(result)

        // 2. Remove inline code (`...`)
        result = removeInlineCode(result)

        // 3. Remove math/LaTeX expressions ($$...$$ and $...$)
        result = removeMathExpressions(result)

        // 4. Remove tool call patterns
        result = removeToolCalls(result)

        // 5. Remove HTML tags (tool call details blocks, etc.)
        result = removeHTMLTags(result)

        // Detect script early so we can skip English-specific transforms below
        let nonLatin = isNonLatinScript(result)

        if nonLatin {
            // For non-Latin scripts: minimal cleanup only.
            result = removeURLs(result)
            result = removeEmoji(result)
            result = result.replacingOccurrences(of: "\n", with: " ")
            result = result.replacingOccurrences(
                of: "\\s{2,}", with: " ", options: .regularExpression
            )
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 6. Strip markdown formatting
        result = stripMarkdown(result)

        // 7. Replace compound-word hyphens with spaces
        result = result.replacingOccurrences(
            of: "(\\w)-(\\w)",
            with: "$1 $2",
            options: .regularExpression
        )

        // 8. Normalize math operators, symbols, currency, and common acronyms
        result = normalizeMathAndSymbols(result)

        // 9. Expand standalone numbers to words so Kokoro's G2P pronounces them correctly
        result = expandNumbersToWords(result)

        // 10. Remove URLs
        result = removeURLs(result)

        // 11. Remove emoji
        result = removeEmoji(result)

        // 12. Clean up whitespace
        result = cleanWhitespace(result)

        return result
    }

    // MARK: - Sentence Splitting

    /// Max chars per chunk for on-device TTS.
    private static let maxChunkChars = 200

    /// Splits text into natural speakable chunks for TTS synthesis.
    static func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed

        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = String(trimmed[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        if sentences.isEmpty {
            sentences = [trimmed]
        }

        var result: [String] = []
        for sentence in sentences {
            if sentence.count > maxChunkChars {
                result.append(contentsOf: splitLongSentence(sentence))
            } else {
                result.append(sentence)
            }
        }

        return mergeShortFragments(result, minLength: 20)
    }

    // MARK: - Streaming TTS Extraction (Character-Offset Based)

    static func extractNewSpeakableChunks(
        from text: String,
        alreadySpokenLength: Int
    ) -> (chunks: [String], newSpokenLength: Int) {
        let cleaned = prepareForSpeech(text)
        guard !cleaned.isEmpty else { return ([], alreadySpokenLength) }

        let safeEndIndex = findLastSentenceEnd(in: cleaned)

        guard safeEndIndex > alreadySpokenLength else {
            return ([], alreadySpokenLength)
        }

        let startIdx = cleaned.index(cleaned.startIndex, offsetBy: alreadySpokenLength)
        let endIdx = cleaned.index(cleaned.startIndex, offsetBy: safeEndIndex)
        let newText = String(cleaned[startIdx..<endIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newText.isEmpty else {
            return ([], alreadySpokenLength)
        }

        let chunks = splitIntoSentences(newText)
        return (chunks, safeEndIndex)
    }

    static func extractFinalChunks(
        from text: String,
        alreadySpokenLength: Int
    ) -> (chunks: [String], newSpokenLength: Int) {
        let cleaned = prepareForSpeech(text)
        guard !cleaned.isEmpty, cleaned.count > alreadySpokenLength else {
            return ([], alreadySpokenLength)
        }

        let startIdx = cleaned.index(cleaned.startIndex, offsetBy: alreadySpokenLength)
        let remaining = String(cleaned[startIdx...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !remaining.isEmpty else {
            return ([], cleaned.count)
        }

        let chunks = splitIntoSentences(remaining)
        return (chunks, cleaned.count)
    }

    private static func findLastSentenceEnd(in text: String) -> Int {
        let strongTerminators: Set<Character> = [".", "!", "?", ":"]
        var lastStrongEnd = 0
        var lastCommaEnd = 0

        for (i, char) in text.enumerated() {
            let isStrong = strongTerminators.contains(char)
            let isComma = char == ","

            if isStrong || isComma {
                let nextIndex = text.index(text.startIndex, offsetBy: i + 1, limitedBy: text.endIndex)
                if nextIndex == nil || nextIndex == text.endIndex {
                    if isStrong { lastStrongEnd = i + 1 }
                    else { lastCommaEnd = i + 1 }
                } else if let next = nextIndex {
                    let nextChar = text[next]
                    if nextChar == " " || nextChar == "\n" || nextChar == "\t" {
                        if isStrong { lastStrongEnd = i + 1 }
                        else { lastCommaEnd = i + 1 }
                    }
                }
            }
        }

        return lastStrongEnd > 0 ? lastStrongEnd : lastCommaEnd
    }

    // MARK: - Legacy Compatibility (sentence-count based)

    static func extractNewSpeakableChunks(
        from text: String,
        alreadySpokenCount: Int
    ) -> [String] {
        let cleaned = prepareForSpeech(text)
        let allSentences = splitIntoSentences(cleaned)
        let safeEnd = findLastSentenceEnd(in: cleaned)
        var safeSentences: [String] = []
        var charCount = 0
        for s in allSentences {
            charCount += s.count + 1
            if charCount <= safeEnd + 1 {
                safeSentences.append(s)
            }
        }
        guard safeSentences.count > alreadySpokenCount else { return [] }
        return Array(safeSentences[alreadySpokenCount...])
    }

    static func extractFinalChunks(
        from text: String,
        alreadySpokenCount: Int
    ) -> [String] {
        let cleaned = prepareForSpeech(text)
        guard !cleaned.isEmpty else { return [] }
        let allSentences = splitIntoSentences(cleaned)
        guard allSentences.count > alreadySpokenCount else { return [] }
        return Array(allSentences[alreadySpokenCount...])
    }

    // MARK: - Markdown Stripping

    /// Removes markdown formatting for cleaner speech output.
    static func stripMarkdown(_ text: String) -> String {
        var result = text

        // --- Headers → standalone sentences ---
        result = regexReplace(result, pattern: "(?m)^#{1,6}\\s+(.+?)([.!?])?\\s*$") { match in
            let content = match.groups[0]
            let existingPunct = match.groups[1]
            return existingPunct.isEmpty ? "\(content)." : "\(content)\(existingPunct)"
        }

        // --- Remove markdown tables ---
        result = regexReplace(result, pattern: "(?m)^\\|.*\\|\\s*$", with: "")

        // --- Remove task list checkboxes ---
        result = regexReplace(result, pattern: "(?m)^[\\-*+]\\s+\\[[ xX]\\]\\s+(.+)") { match in
            let content = match.groups[0]
            let last = content.last
            return (last == "." || last == "!" || last == "?" || last == ":") ? content : "\(content)."
        }

        // --- Standalone bold lines acting as section headings → sentence boundary ---
        result = regexReplace(result, pattern: "(?m)^\\*\\*(.+?)([.!?])?\\*\\*\\s*$") { match in
            let content = match.groups[0]
            let existingPunct = match.groups[1]
            return existingPunct.isEmpty ? "\(content)." : "\(content)\(existingPunct)"
        }
        result = regexReplace(result, pattern: "(?m)^__(.+?)([.!?])?__\\s*$") { match in
            let content = match.groups[0]
            let existingPunct = match.groups[1]
            return existingPunct.isEmpty ? "\(content)." : "\(content)\(existingPunct)"
        }

        // --- Bold+Italic (***text*** or ___text___) — must come BEFORE bold/italic alone ---
        result = result.replacingOccurrences(
            of: "\\*{3}(.+?)\\*{3}",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "_{3}(.+?)_{3}",
            with: "$1",
            options: .regularExpression
        )

        // --- Bold (**text** or __text__) — inline bold within paragraphs ---
        // Use .+? (lazy) so "**26**" always matches even adjacent to other * chars.
        result = result.replacingOccurrences(
            of: "\\*\\*(.+?)\\*\\*",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "__(.+?)__",
            with: "$1",
            options: .regularExpression
        )

        // --- Italic (*text* or _text_) ---
        result = result.replacingOccurrences(
            of: "(?<!\\*)\\*([^*]+)\\*(?!\\*)",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?<!_)_([^_]+)_(?!_)",
            with: "$1",
            options: .regularExpression
        )

        // --- Safety net: strip any remaining stray asterisks ---
        result = result.replacingOccurrences(
            of: "\\*+",
            with: "",
            options: .regularExpression
        )

        // --- Strikethrough (~~text~~) ---
        result = result.replacingOccurrences(
            of: "~~([^~]+)~~",
            with: "$1",
            options: .regularExpression
        )

        // --- Links [text](url) — keep the text ---
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )

        // --- Images ![alt](url) ---
        result = result.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^)]+\\)",
            with: "",
            options: .regularExpression
        )

        // --- Blockquotes (> text) ---
        result = regexReplace(result, pattern: "(?m)^>\\s*", with: "")

        // --- Bullet points → standalone sentences ---
        result = regexReplace(result, pattern: "(?m)^[\\-*+]\\s+(.+)") { match in
            let content = match.groups[0]
            let last = content.last
            return (last == "." || last == "!" || last == "?" || last == ":") ? content : "\(content)."
        }

        // --- Numbered lists → standalone sentences ---
        result = regexReplace(result, pattern: "(?m)^\\d+\\.\\s+(.+)") { match in
            let content = match.groups[0]
            let last = content.last
            return (last == "." || last == "!" || last == "?" || last == ":") ? content : "\(content)."
        }

        // --- Horizontal rules (---, ***, ___) ---
        result = regexReplace(result, pattern: "(?m)^[\\-*_]{3,}\\s*$", with: "")

        // --- Citation references [1], [2], [^1] etc. ---
        result = result.replacingOccurrences(
            of: "\\[\\^?\\d+\\]",
            with: "",
            options: .regularExpression
        )

        // --- Common abbreviation expansion for more natural pauses ---
        result = expandAbbreviations(result)

        return result
    }

    // MARK: - Code & Tool Removal

    static func removeCodeBlocks(_ text: String) -> String {
        text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: "",
            options: .regularExpression
        )
    }

    static func removeInlineCode(_ text: String) -> String {
        text.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )
    }

    static func removeMathExpressions(_ text: String) -> String {
        var result = text
        result = regexReplace(result, pattern: "(?s)\\$\\$.*?\\$\\$", with: "")
        result = result.replacingOccurrences(
            of: "\\$(?=[^\\s\\d])(?:[^$\n]+?)\\$",
            with: "",
            options: .regularExpression
        )
        return result
    }

    static func removeToolCalls(_ text: String) -> String {
        var result = text
        result = regexReplace(result, pattern: "(?s)\\{\\s*\"tool_calls?\"\\s*:\\s*\\[.*?\\]\\s*\\}", with: "")
        result = regexReplace(result, pattern: "(?s)<tool_call>.*?</tool_call>", with: "")
        result = result.replacingOccurrences(
            of: "\\b\\w+_\\w+\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?:Calling|Using|Executing)\\s+(?:tool|function)\\s*:?\\s*\\w+",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

    static func removeHTMLTags(_ text: String) -> String {
        var result = text
        result = regexReplace(result, pattern: "(?s)<details[^>]*>.*?</details>", with: "")
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        return result
    }

    static func removeURLs(_ text: String) -> String {
        text.replacingOccurrences(
            of: "https?://\\S+",
            with: "",
            options: .regularExpression
        )
    }

    static func removeEmoji(_ text: String) -> String {
        String(text.filter { character in
            !character.unicodeScalars.contains(where: { scalar in
                scalar.properties.isEmoji && scalar.properties.isEmojiPresentation
            }) && !character.isEmoji
        })
    }

    // MARK: - Math & Symbol Normalization

    private static func normalizeMathAndSymbols(_ text: String) -> String {
        var result = text

        result = result.replacingOccurrences(of: "°C", with: " degrees Celsius")
        result = result.replacingOccurrences(of: "°F", with: " degrees Fahrenheit")
        result = result.replacingOccurrences(of: "°",  with: " degrees")

        result = result.replacingOccurrences(of: "×", with: " times ")
        result = result.replacingOccurrences(of: "÷", with: " divided by ")

        result = regexReplace(result, pattern: "(\\d)\\s*\\*\\s*(\\d)", with: "$1 times $2")
        result = regexReplace(result, pattern: "(\\w)\\s*=\\s*(\\d)", with: "$1 equals $2")
        result = regexReplace(result, pattern: "(\\d)\\s*\\+\\s*(\\d)", with: "$1 plus $2")
        result = regexReplace(result, pattern: "(\\d)\\s*[\\-\\u2212]\\s*(\\d)", with: "$1 minus $2")
        result = regexReplace(result, pattern: "(\\d)\\s*/\\s*(\\d)", with: "$1 divided by $2")
        result = regexReplace(result, pattern: "(\\d)\\^(\\d+)", with: "$1 to the power of $2")
        result = regexReplace(result, pattern: "(\\d)%", with: "$1 percent")

        result = result.replacingOccurrences(of: "≈", with: " approximately equals ")
        result = result.replacingOccurrences(of: "≠", with: " does not equal ")
        result = result.replacingOccurrences(of: "≤", with: " is less than or equal to ")
        result = result.replacingOccurrences(of: "≥", with: " is greater than or equal to ")
        result = result.replacingOccurrences(of: "±", with: " plus or minus ")

        result = regexReplace(result, pattern: "(\\d)\\s*<\\s*(\\d)", with: "$1 is less than $2")
        result = regexReplace(result, pattern: "(\\d)\\s*>\\s*(\\d)", with: "$1 is greater than $2")

        result = result.replacingOccurrences(of: "√", with: " square root of ")
        result = result.replacingOccurrences(of: "π", with: " pi ")
        result = result.replacingOccurrences(of: "∞", with: " infinity ")
        result = result.replacingOccurrences(of: "∑", with: " sum of ")
        result = result.replacingOccurrences(of: "∏", with: " product of ")
        result = result.replacingOccurrences(of: "∫", with: " integral of ")
        result = result.replacingOccurrences(of: "∂", with: " partial derivative of ")
        result = result.replacingOccurrences(of: "Δ", with: " delta ")
        result = result.replacingOccurrences(of: "α", with: " alpha ")
        result = result.replacingOccurrences(of: "β", with: " beta ")
        result = result.replacingOccurrences(of: "γ", with: " gamma ")
        result = result.replacingOccurrences(of: "λ", with: " lambda ")
        result = result.replacingOccurrences(of: "μ", with: " mu ")
        result = result.replacingOccurrences(of: "σ", with: " sigma ")
        result = result.replacingOccurrences(of: "θ", with: " theta ")
        result = result.replacingOccurrences(of: "ω", with: " omega ")

        result = regexReplace(result, pattern: "\\$(\\d)", with: "$1 dollars")
        result = regexReplace(result, pattern: "€(\\d)", with: "$1 euros")
        result = regexReplace(result, pattern: "£(\\d)", with: "$1 pounds")
        result = regexReplace(result, pattern: "¥(\\d)", with: "$1 yen")
        result = regexReplace(result, pattern: "₹(\\d)", with: "$1 rupees")

        result = regexReplace(result, pattern: "(\\w)\\s*&\\s*(\\w)", with: "$1 and $2")
        result = regexReplace(result, pattern: "(\\w)\\s*@\\s*(\\w)", with: "$1 at $2")
        result = result.replacingOccurrences(of: "→", with: " to ")
        result = result.replacingOccurrences(of: "←", with: " from ")
        result = result.replacingOccurrences(of: "↑", with: " up ")
        result = result.replacingOccurrences(of: "↓", with: " down ")
        result = regexReplace(result, pattern: "~(\\d)", with: "approximately $1")
        result = result.replacingOccurrences(of: "…", with: ", ")
        result = regexReplace(result, pattern: "#(\\d)", with: "number $1")

        return result
    }

    // MARK: - Number Expansion

    /// Expands standalone Arabic numerals to their English word equivalents so that
    /// Kokoro's G2P reliably pronounces them (e.g. "26" → "twenty-six").
    /// Integers and simple decimals are expanded; tokens that are part of alphanumeric
    /// identifiers (e.g. "h264", "mp3", "v2") are intentionally skipped.
    private static func expandNumbersToWords(_ text: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")

        guard let regex = try? NSRegularExpression(
            // Match a number that is NOT immediately preceded or followed by a letter/underscore.
            pattern: "(?<![A-Za-z_])(\\d{1,15}(?:\\.\\d+)?)(?![A-Za-z_%])"
        ) else { return text }

        let nsText = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[range])

            if token.contains(".") {
                // Decimal: spell out integer and fractional parts separately.
                let parts = token.split(separator: ".", maxSplits: 1)
                if parts.count == 2,
                   let intPart = Int(parts[0]),
                   let fracPart = Int(parts[1]),
                   let intWords = formatter.string(from: NSNumber(value: intPart)),
                   let fracWords = formatter.string(from: NSNumber(value: fracPart)) {
                    result.replaceSubrange(range, with: "\(intWords) point \(fracWords)")
                }
            } else if let number = Int64(token),
                      let words = formatter.string(from: NSNumber(value: number)) {
                result.replaceSubrange(range, with: words)
            }
        }
        return result
    }

    // MARK: - Abbreviation Expansion

    private static func expandAbbreviations(_ text: String) -> String {
        let replacements: [(pattern: String, replacement: String)] = [
            ("\\be\\.g\\.",      "for example"),
            ("\\bi\\.e\\.",      "that is"),
            ("\\bviz\\.",        "namely"),
            ("\\bcf\\.",         "compare"),
            ("\\bib\\.",         "in the same place"),
            ("\\bop\\. cit\\.",  "in the work cited"),
            ("\\betc\\.",        "and so on"),
            ("\\bvs\\.",         "versus"),
            ("\\bapprox\\.",     "approximately"),
            ("\\bmax\\.",        "maximum"),
            ("\\bmin\\.",        "minimum"),
            ("\\bno\\.",         "number"),
            ("\\bNov\\.",        "November"),
            ("\\bDec\\.",        "December"),
            ("\\bJan\\.",        "January"),
            ("\\bFeb\\.",        "February"),
            ("\\bMar\\.",        "March"),
            ("\\bApr\\.",        "April"),
            ("\\bAug\\.",        "August"),
            ("\\bSep\\.",        "September"),
            ("\\bOct\\.",        "October"),
            ("\\bDr\\.",   "Doctor"),
            ("\\bMr\\.",   "Mister"),
            ("\\bMs\\.",   "Ms"),
            ("\\bMrs\\.",  "Missus"),
            ("\\bProf\\.", "Professor"),
            ("\\bSt\\.",   "Saint"),
        ]

        var result = text
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: - Whitespace Cleaning

    static func cleanWhitespace(_ text: String) -> String {
        var result = text

        result = regexReplace(result, pattern: "([^.!?:\\n])\\n{2,}", with: "$1. ")
        result = result.replacingOccurrences(
            of: "\n{2,}",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\.{2,}",
            with: ".",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: ":.", with: ":")
        result = result.replacingOccurrences(
            of: "\\.\\s*\\.",
            with: ".",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    private static func splitLongSentence(_ sentence: String) -> [String] {
        let delimiters: [Character] = [";"]
        var chunks: [String] = []
        var current = ""

        for char in sentence {
            current.append(char)
            if delimiters.contains(char) && current.count >= 60 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(trimmed)
                }
                current = ""
            }
        }

        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            if let last = chunks.last, last.count + remainder.count < maxChunkChars {
                chunks[chunks.count - 1] = last + " " + remainder
            } else {
                chunks.append(remainder)
            }
        }

        return chunks.isEmpty ? [sentence] : chunks
    }

    private static func mergeShortFragments(_ sentences: [String], minLength: Int) -> [String] {
        guard sentences.count > 1 else { return sentences }

        var merged: [String] = []
        var buffer = ""

        for sentence in sentences {
            if buffer.isEmpty {
                buffer = sentence
            } else if buffer.count < minLength || sentence.count < minLength {
                buffer += " " + sentence
            } else {
                merged.append(buffer)
                buffer = sentence
            }
        }

        if !buffer.isEmpty {
            if !merged.isEmpty && buffer.count < minLength {
                merged[merged.count - 1] += " " + buffer
            } else {
                merged.append(buffer)
            }
        }

        return merged
    }

    static func regexReplace(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static func regexReplace(
        _ text: String,
        pattern: String,
        transform: (RegexMatch) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches.reversed() {
            let replacement = transform(RegexMatch(result: match, source: nsText))
            let swiftRange = Range(match.range, in: result)!
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }
}

// MARK: - RegexMatch Helper

private struct RegexMatch {
    let result: NSTextCheckingResult
    let source: NSString

    var groups: [String] {
        (1..<result.numberOfRanges).map { i in
            let range = result.range(at: i)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: source as String) else { return "" }
            return String((source as String)[swiftRange])
        }
    }
}

// MARK: - Character Emoji Detection

private extension Character {
    var isEmoji: Bool {
        if let scalar = unicodeScalars.first {
            if unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return true }
            if scalar.properties.isEmoji {
                if (0x0030...0x0039).contains(scalar.value) || scalar.value == 0x002A || scalar.value == 0x0023 {
                    return unicodeScalars.count > 1
                }
                return scalar.properties.isEmojiPresentation || unicodeScalars.count > 1
            }
        }
        return false
    }
}
