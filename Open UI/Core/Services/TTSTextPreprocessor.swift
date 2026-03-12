import Foundation
import NaturalLanguage

/// Preprocesses text for TTS synthesis by stripping markdown, removing
/// tool call information, code blocks, and splitting into speakable chunks.
///
/// Matches the Flutter `ConduitMarkdownPreprocessor.toPlainText` and
/// `TextToSpeechService.splitTextForSpeech` behavior.
enum TTSTextPreprocessor {

    // MARK: - Full Pipeline

    /// Prepares raw assistant response text for speech synthesis.
    /// Strips markdown, removes tool calls and code blocks, cleans whitespace.
    static func prepareForSpeech(_ text: String) -> String {
        var result = text

        // 1. Remove code blocks (```...```)
        result = removeCodeBlocks(result)

        // 2. Remove inline code (`...`)
        result = removeInlineCode(result)

        // 3. Remove tool call patterns
        result = removeToolCalls(result)

        // 4. Remove HTML tags (tool call details blocks, etc.)
        result = removeHTMLTags(result)

        // 5. Strip markdown formatting
        result = stripMarkdown(result)

        // 6. Remove URLs
        result = removeURLs(result)

        // 7. Remove emoji (they sound terrible when read aloud)
        result = removeEmoji(result)

        // 8. Clean up whitespace
        result = cleanWhitespace(result)

        return result
    }

    // MARK: - Sentence Splitting

    /// Max chars per chunk for on-device TTS.
    private static let maxChunkChars = 200

    /// Splits text into natural speakable chunks for TTS synthesis.
    /// Sentences preserve their original content; a trailing period is added
    /// only if the sentence doesn't already end with terminal punctuation.
    static func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Use NLTokenizer for proper sentence splitting
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

        // Split any sentences that are too long for the model
        var result: [String] = []
        for sentence in sentences {
            if sentence.count > maxChunkChars {
                result.append(contentsOf: splitLongSentence(sentence))
            } else {
                result.append(sentence)
            }
        }

        // Merge very short fragments
        return mergeShortFragments(result, minLength: 20)
    }

    // MARK: - Streaming TTS Extraction (Character-Offset Based)

    /// Extracts new complete sentences from streaming text that haven't been spoken yet.
    /// Uses character-offset tracking instead of sentence counting for robustness —
    /// as text accumulates, sentence boundaries can shift, so counting sentences is unreliable.
    ///
    /// - Parameters:
    ///   - text: The accumulated raw response text so far
    ///   - alreadySpokenLength: Number of characters of *cleaned* text already enqueued
    /// - Returns: Tuple of (new chunks to speak, updated spoken length)
    static func extractNewSpeakableChunks(
        from text: String,
        alreadySpokenLength: Int
    ) -> (chunks: [String], newSpokenLength: Int) {
        let cleaned = prepareForSpeech(text)
        guard !cleaned.isEmpty else { return ([], alreadySpokenLength) }

        // Find the last terminal punctuation in the cleaned text.
        // Everything up to (and including) it is "safe" to speak.
        // The remainder after it is still being streamed and might be incomplete.
        let safeEndIndex = findLastSentenceEnd(in: cleaned)

        guard safeEndIndex > alreadySpokenLength else {
            return ([], alreadySpokenLength)
        }

        // Extract the new safe text (from where we left off to the safe boundary)
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

    /// Extracts ALL remaining text as chunks when streaming is complete.
    /// Called when `done:true` is received — everything remaining is safe to speak.
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

    /// Finds the character offset of the end of the last complete sentence.
    /// A sentence ends at `.`, `!`, `?`, or `:` followed by a space or end of string.
    private static func findLastSentenceEnd(in text: String) -> Int {
        let terminators: Set<Character> = [".", "!", "?"]
        var lastEnd = 0

        for (i, char) in text.enumerated() {
            if terminators.contains(char) {
                // Check it's followed by a space, newline, or is the last char
                let nextIndex = text.index(text.startIndex, offsetBy: i + 1, limitedBy: text.endIndex)
                if nextIndex == nil || nextIndex == text.endIndex {
                    lastEnd = i + 1
                } else if let next = nextIndex {
                    let nextChar = text[next]
                    if nextChar == " " || nextChar == "\n" || nextChar == "\t" {
                        lastEnd = i + 1
                    }
                }
            }
        }

        return lastEnd
    }

    // MARK: - Legacy Compatibility (sentence-count based)
    // Kept for non-streaming callers that use the old API.

    /// Legacy: extract by sentence count. Prefer the character-offset versions above.
    static func extractNewSpeakableChunks(
        from text: String,
        alreadySpokenCount: Int
    ) -> [String] {
        let cleaned = prepareForSpeech(text)
        let allSentences = splitIntoSentences(cleaned)
        let safeEnd = findLastSentenceEnd(in: cleaned)
        // Only return sentences whose text falls within the safe boundary
        var safeSentences: [String] = []
        var charCount = 0
        for s in allSentences {
            charCount += s.count + 1 // +1 for space between
            if charCount <= safeEnd + 1 {
                safeSentences.append(s)
            }
        }
        guard safeSentences.count > alreadySpokenCount else { return [] }
        return Array(safeSentences[alreadySpokenCount...])
    }

    /// Legacy: extract final by sentence count.
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

        // Remove headers (## Header)
        result = result.replacingOccurrences(
            of: "^#{1,6}\\s+",
            with: "",
            options: .regularExpression
        )

        // Remove bold (**text** or __text__)
        result = result.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "__([^_]+)__",
            with: "$1",
            options: .regularExpression
        )

        // Remove italic (*text* or _text_) — careful not to match ** or __
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

        // Remove strikethrough (~~text~~)
        result = result.replacingOccurrences(
            of: "~~([^~]+)~~",
            with: "$1",
            options: .regularExpression
        )

        // Remove links [text](url) — keep the text
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )

        // Remove images ![alt](url)
        result = result.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^)]+\\)",
            with: "",
            options: .regularExpression
        )

        // Remove blockquotes (> text) — multiline-aware
        result = regexReplace(result, pattern: "(?m)^>\\s*", with: "")

        // Convert bullet points into standalone sentences:
        // Add a period before removing the marker so each item becomes a sentence.
        result = regexReplace(result, pattern: "(?m)^[\\-*+]\\s+(.+)", with: "$1.")

        // Convert numbered lists into standalone sentences
        result = regexReplace(result, pattern: "(?m)^\\d+\\.\\s+(.+)", with: "$1.")

        // Remove horizontal rules (---, ***, ___)
        result = regexReplace(result, pattern: "(?m)^[\\-*_]{3,}$", with: "")

        // Remove citation references [1], [2] etc.
        result = result.replacingOccurrences(
            of: "\\[\\d+\\]",
            with: "",
            options: .regularExpression
        )

        return result
    }

    // MARK: - Code & Tool Removal

    /// Removes fenced code blocks (```...```).
    static func removeCodeBlocks(_ text: String) -> String {
        text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: "",
            options: .regularExpression
        )
    }

    /// Removes inline code (`...`).
    static func removeInlineCode(_ text: String) -> String {
        text.replacingOccurrences(
            of: "`[^`]+`",
            with: "",
            options: .regularExpression
        )
    }

    /// Removes tool call patterns and function call syntax.
    static func removeToolCalls(_ text: String) -> String {
        var result = text

        // Remove JSON tool call blocks (use (?s) for dot-matches-newlines)
        result = regexReplace(result, pattern: "(?s)\\{\\s*\"tool_calls?\"\\s*:\\s*\\[.*?\\]\\s*\\}", with: "")

        // Remove <tool_call>...</tool_call> XML-style blocks
        result = regexReplace(result, pattern: "(?s)<tool_call>.*?</tool_call>", with: "")

        // Remove function_call patterns: name(args)
        // Be careful not to remove normal parenthetical expressions
        result = result.replacingOccurrences(
            of: "\\b\\w+_\\w+\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )

        // Remove "Calling tool: ..." or "Using tool: ..." prefixes
        result = result.replacingOccurrences(
            of: "(?:Calling|Using|Executing)\\s+(?:tool|function)\\s*:?\\s*\\w+",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return result
    }

    /// Removes HTML tags (including <details> blocks from tool calls).
    static func removeHTMLTags(_ text: String) -> String {
        var result = text

        // Remove <details>...</details> blocks entirely (use (?s) for dot-matches-newlines)
        result = regexReplace(result, pattern: "(?s)<details[^>]*>.*?</details>", with: "")

        // Remove remaining HTML tags
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        return result
    }

    /// Removes URLs from text.
    static func removeURLs(_ text: String) -> String {
        text.replacingOccurrences(
            of: "https?://\\S+",
            with: "",
            options: .regularExpression
        )
    }

    /// Removes emoji characters from text for cleaner TTS output.
    ///
    /// Uses Swift's `Character`-level emoji detection which correctly handles
    /// all emoji forms including supplemental symbols (0x1F900-0x1F9FF),
    /// flag sequences, skin tone modifiers, and ZWJ sequences.
    static func removeEmoji(_ text: String) -> String {
        String(text.filter { character in
            !character.unicodeScalars.contains(where: { scalar in
                scalar.properties.isEmoji && scalar.properties.isEmojiPresentation
            }) && !character.isEmoji
        })
    }

    // MARK: - Whitespace Cleaning

    /// Cleans up excessive whitespace while preserving sentence boundaries.
    /// Single newlines become spaces (they are soft wraps within a paragraph).
    /// Double newlines (paragraph breaks) become sentence boundaries.
    static func cleanWhitespace(_ text: String) -> String {
        var result = text

        // Double newlines = paragraph break → sentence boundary
        // Insert a period only if the line doesn't already end with punctuation
        result = regexReplace(result, pattern: "([^.!?:;\\n])\\n{2,}", with: "$1. ")

        // Lines ending with punctuation + double newline → just add space
        result = result.replacingOccurrences(
            of: "\n{2,}",
            with: " ",
            options: .regularExpression
        )

        // Single newlines → space (soft wrap within paragraph, NOT a sentence break)
        result = result.replacingOccurrences(of: "\n", with: " ")

        // Collapse multiple spaces
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        // Remove double periods
        result = result.replacingOccurrences(
            of: "\\.{2,}",
            with: ".",
            options: .regularExpression
        )

        // Clean up period-space-period patterns
        result = result.replacingOccurrences(
            of: "\\.\\s*\\.",
            with: ".",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    /// Splits a long sentence at major clause boundaries (semicolon, dash).
    /// Commas are NOT used as split points — they are part of natural sentence
    /// flow and splitting on them produces unnatural, fragmented speech.
    private static func splitLongSentence(_ sentence: String) -> [String] {
        let delimiters: [Character] = [";", "—", "–"]
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

    /// Merges very short fragments with their neighbors.
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
            merged.append(buffer)
        }

        return merged
    }

    /// Helper that uses NSRegularExpression for patterns needing multiline/dotAll flags.
    private static func regexReplace(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}

// MARK: - Character Emoji Detection

private extension Character {
    /// Whether this character is an emoji (single or multi-scalar).
    /// Covers emoticons, symbols, flags, skin-toned emoji, ZWJ sequences.
    var isEmoji: Bool {
        // Single-scalar fast path
        if let scalar = unicodeScalars.first {
            // Variation selector U+FE0F forces emoji presentation
            if unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return true }
            // Check emoji properties
            if scalar.properties.isEmoji {
                // Numbers 0-9, *, # have isEmoji=true but aren't emoji unless
                // followed by U+FE0F (caught above) or U+20E3 (keycap)
                if (0x0030...0x0039).contains(scalar.value) || scalar.value == 0x002A || scalar.value == 0x0023 {
                    return unicodeScalars.count > 1
                }
                return scalar.properties.isEmojiPresentation || unicodeScalars.count > 1
            }
        }
        return false
    }
}
