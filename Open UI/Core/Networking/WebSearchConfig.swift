import Foundation

// MARK: - Web Search Config

/// The `web` nested object inside `RetrievalConfig`.
///
/// The server's `POST /api/v1/retrieval/config/update` handler assigns **every**
/// `web.*` field unconditionally (no `is not None` guard), so any key missing
/// from the payload is reset on the server. To avoid wiping settings this app
/// doesn't render, the object is kept as the raw JSON dictionary returned by
/// `GET /api/v1/retrieval/config` and re-sent as-is with only edited keys changed.
/// Accessors use the exact server key names (`WebConfig` in
/// `backend/open_webui/routers/retrieval.py`) and the value types its pydantic
/// form expects.
struct WebSearchConfig: Codable, @unchecked Sendable {
    /// Raw server JSON (JSON-compatible values only).
    private(set) var raw: [String: Any]

    init() { raw = [:] }
    init(raw: [String: Any]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dict = (try? container.decode([String: JSONAnyCodable].self)) ?? [:]
        raw = dict.mapValues(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sanitizedForSave().mapValues { JSONAnyCodable($0) })
    }

    /// True when the config was loaded from the server (safe to send back).
    var isLoaded: Bool { !raw.isEmpty }

    // MARK: - Typed access

    func string(_ key: String, default def: String = "") -> String {
        let v = raw[key]
        if let s = v as? String { return s }
        if let n = v as? NSNumber, !(v is Bool) { return n.stringValue }
        return def
    }

    func bool(_ key: String, default def: Bool = false) -> Bool {
        raw[key] as? Bool ?? def
    }

    /// Integer value rendered as text ("" when null/absent).
    func intText(_ key: String) -> String {
        let v = raw[key]
        if v is Bool { return "" }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return String(Int(d)) }
        if let s = v as? String { return s }
        return ""
    }

    func stringList(_ key: String) -> [String] {
        if let arr = raw[key] as? [String] { return arr }
        if let s = raw[key] as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    mutating func setString(_ key: String, _ value: String) { raw[key] = value }
    mutating func setBool(_ key: String, _ value: Bool) { raw[key] = value }

    /// For `int | None` server fields. Empty input sends `null` (never `""`,
    /// which the server's int fields reject with a 422).
    mutating func setInt(_ key: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { raw[key] = NSNull() }
        else if let i = Int(trimmed) { raw[key] = i }
    }

    /// For numeric values the server types as `str | None`
    /// (`WEB_LOADER_TIMEOUT`, `FIRECRAWL_TIMEOUT`). An int here fails validation.
    mutating func setNumericString(_ key: String, _ text: String) {
        raw[key] = text.trimmingCharacters(in: .whitespaces).filter(\.isNumber)
    }

    mutating func setStringList(_ key: String, commaSeparated text: String) {
        raw[key] = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Common fields

    var enableWebSearch: Bool {
        get { bool("ENABLE_WEB_SEARCH") }
        set { raw["ENABLE_WEB_SEARCH"] = newValue }
    }

    var webSearchEngine: String {
        get { string("WEB_SEARCH_ENGINE") }
        set { raw["WEB_SEARCH_ENGINE"] = newValue }
    }

    var webLoaderEngine: String {
        get { string("WEB_LOADER_ENGINE") }
        set { raw["WEB_LOADER_ENGINE"] = newValue }
    }

    /// `LINKUP_SEARCH_PARAMS` (`dict | None`) as pretty JSON text.
    var linkupSearchParamsJSON: String {
        guard let obj = raw["LINKUP_SEARCH_PARAMS"] as? [String: Any], !obj.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Stores LINKUP_SEARCH_PARAMS. Returns false when the text isn't a JSON object.
    @discardableResult
    mutating func setLinkupSearchParams(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { raw["LINKUP_SEARCH_PARAMS"] = [String: Any](); return true }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        raw["LINKUP_SEARCH_PARAMS"] = obj
        return true
    }

    /// Normalises values whose stored type the current server form rejects, so a
    /// save never fails validation on fields the user didn't touch. Mirrors the
    /// conversions done by the web UI's `WebSearch.svelte` submit handler.
    func sanitizedForSave() -> [String: Any] {
        var out = raw
        for key in ["WEB_LOADER_TIMEOUT", "FIRECRAWL_TIMEOUT"] {
            if let n = out[key] as? NSNumber, !(out[key] is Bool) { out[key] = n.stringValue }
        }
        for key in ["YOUTUBE_LOADER_LANGUAGE", "WEB_SEARCH_DOMAIN_FILTER_LIST"] {
            if let s = out[key] as? String {
                out[key] = s.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        // EXA_MAX_CONTENT_LENGTH: strict int > 0, or null.
        if let v = out["EXA_MAX_CONTENT_LENGTH"], !(v is NSNull) {
            if !(v is Bool), let i = v as? Int, i > 0 { out["EXA_MAX_CONTENT_LENGTH"] = i }
            else { out["EXA_MAX_CONTENT_LENGTH"] = NSNull() }
        }
        return out
    }
}
