import Foundation

/// Read-only local projection. The full server history must be restored before writes.
nonisolated enum CachedConversationSnapshot {
    static let marker = "openrelay_cache_compact"

    static func compact(_ data: Data) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var chat = json["chat"] as? [String: Any] else { return nil }
        var changed = false
        var projections: [String: String] = [:]
        func apply(_ projected: String, to message: [String: Any]) -> [String: Any] {
            changed = true
            var result = message
            result["content"] = projected
            result.removeValue(forKey: "output")
            result.removeValue(forKey: "originalContent")
            return result
        }
        func project(_ message: [String: Any]) -> [String: Any] {
            guard message["role"] as? String == "assistant", message["done"] as? Bool != false,
                  (message["embeds"] as? [Any] ?? []).isEmpty else { return message }
            let output = message["output"] as? [[String: Any]] ?? []
            // Tool-generated images/files remain visible even with the card collapsed.
            guard !output.contains(where: { !($0["files"] as? [Any] ?? []).isEmpty
                || !($0["embeds"] as? [Any] ?? []).isEmpty || !($0["images"] as? [Any] ?? []).isEmpty || $0["name"] as? String == "display_file" }) else { return message }
            let original = message["content"] as? String ?? ""
            let content = original.isEmpty ? (MessageHistory.reconstructContentFromOutput(output) ?? "") : original
            guard content.contains("<") else { return message }
            if let projected = projections[content] { return apply(projected, to: message) }
            let prepared = ToolCallParser.preprocessThinkTags(content)
            var projected = ""
            var stripped = false
            for piece in DetailsBlockScanner.scan(prepared) {
                switch piece {
                case .text(let text, _): projected += text
                case .partialTag: return message
                case .block(let block):
                    guard block.isClosed, block.attributes["done"]?.lowercased() != "false",
                          ["reasoning", "tool_calls"].contains(block.type ?? ""),
                          block.type != "tool_calls" || block.attributes["done"]?.lowercased() == "true",
                          block.attributes["embeds"] == nil, block.attributes["files"] == nil,
                          block.attributes["name"] != "display_file" else {
                        projected += block.raw
                        continue
                    }
                    let parsed = ToolCallParser.parseOrdered(block.raw)
                    let summary = DetailsBlockScanner.splitSummary(block.body).summary ?? ""
                    var attributes = block.attributes.filter { ["type", "done", "duration", "id", "name", "label", "status"].contains($0.key) }
                    attributes["cache-missing"] = "true"
                    var body = ""
                    var spillover = ""
                    for segment in parsed.segments {
                        switch segment {
                        case .reasoning(let reasoning):
                            // Keep the identity anchor, not the rest of the reasoning body.
                            body = escape(String(reasoning.content.prefix(80)))
                        case .toolCall(let tool):
                            attributes["cache-error"] = tool.isError ? "true" : "false"
                            if attributes["id"] == nil { attributes["id"] = "tool-\(tool.name)-\(block.byteRange.lowerBound)" }
                        case .text(let text): spillover += text
                        case .details: break
                        }
                    }
                    let tag = attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\"\(escape(ToolCallParser.decodeHTMLEntities($0.value) ?? $0.value))\"" }.joined(separator: " ")
                    projected += "<details \(tag)><summary>\(summary)</summary>\(body)</details>" + spillover
                    stripped = true
                }
            }
            guard stripped else { return message }
            projections[content] = projected
            return apply(projected, to: message)
        }
        if var history = chat["history"] as? [String: Any], let messages = history["messages"] as? [String: [String: Any]] {
            history["messages"] = messages.mapValues(project)
            chat["history"] = history
        }
        if let messages = chat["messages"] as? [[String: Any]] { chat["messages"] = messages.map(project) }
        guard changed else { return nil }
        chat[marker] = true
        json["chat"] = chat
        guard let compact = try? JSONSerialization.data(withJSONObject: json), compact.count < data.count else { return nil }
        return compact
    }

    static func hasDeferredContent(_ content: String) -> Bool {
        guard content.contains("cache-missing") else { return false }
        return DetailsBlockScanner.scan(content).contains { piece in
            if case .block(let block) = piece { return block.attributes["cache-missing"] == "true" }
            return false
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
