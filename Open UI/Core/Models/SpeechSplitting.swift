import Foundation

/// Open WebUI's split values, plus a device-local inheritance option.
enum SpeechSplitting: String, CaseIterable, Identifiable {
    case followServer = "server"
    case sentences = "punctuation"
    case paragraphs
    case wholeMessage = "none"

    static let preferenceKey = "ttsResponseSplitting"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .followServer: "Follow Server"
        case .sentences: "Sentences"
        case .paragraphs: "Paragraphs"
        case .wholeMessage: "Whole Message"
        }
    }

    func resolved(serverValue: String?) -> Self {
        guard self == .followServer else { return self }
        let server = Self(rawValue: serverValue ?? "") ?? .sentences
        return server == .followServer ? .sentences : server
    }

    /// Call after removing reasoning/tool blocks, before whitespace cleanup erases paragraphs.
    func chunks(from text: String) -> [String] {
        switch self {
        case .paragraphs:
            return text.components(separatedBy: .newlines)
                .map(TTSTextPreprocessor.prepareForSpeech).filter { !$0.isEmpty }
        case .wholeMessage:
            let cleaned = TTSTextPreprocessor.prepareForSpeech(text)
            return cleaned.isEmpty ? [] : [cleaned]
        case .sentences, .followServer:
            return TTSTextPreprocessor.splitIntoSentences(TTSTextPreprocessor.prepareForSpeech(text))
        }
    }
}
