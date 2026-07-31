import Foundation

// MARK: - HistoryNode

/// A single node in the OpenWebUI history tree.
///
/// Mirrors the server's `history.messages[id]` structure exactly so that
/// parse ↔ serialize is a direct mapping with no lossy transformations.
/// Every message in a conversation (user, assistant, system) is a node.
/// Branching (edits, regenerations) is expressed through `childrenIds`
/// — multiple children of the same parent with the same role are siblings
/// (alternative versions).
struct HistoryNode: Sendable {
    var id: String
    var parentId: String?
    var childrenIds: [String]
    var role: MessageRole
    var content: String
    var timestamp: Date
    var model: String?
    var done: Bool
    var files: [ChatMessageFile]
    var sources: [ChatSourceReference]
    var followUps: [String]
    var statusHistory: [ChatStatusUpdate]
    var error: ChatMessageError?
    /// Token usage data — `[String: Any]` for provider-agnostic storage.
    /// Not truly `Sendable` but matches the existing `ChatMessage.usage` pattern.
    var usage: [String: Any]?
    /// Rich UI HTML embeds stored by the server on the message.
    var embeds: [String]
    /// For user messages: the model IDs that were selected when this message was sent.
    var models: [String]
    /// Feedback annotation for this message (thumbs up/down + detail ratings).
    var annotation: MessageAnnotation?
    /// Server-assigned feedback record ID.
    var feedbackId: String?
    /// True when meta.internal == true on this node (e.g. background sub-agent completion).
    var isInternalMessage: Bool
    /// Delegation ID from meta.delegation_id (background sub-agent completion notices).
    var subagentDelegationId: String?
    /// Raw `output` array from the server (v0.7+). Stored as-is and re-emitted
    /// verbatim on every sync so the server's canonical format is never corrupted.
    /// Content is reconstructed from this array during parsing but the original
    /// array must survive the round-trip so that `files`, `images`, and other
    /// server-derived metadata (e.g. from `function_call_output`) are preserved
    /// even when the node is on an inactive branch.
    var output: [[String: Any]]

    init(
        id: String = UUID().uuidString,
        parentId: String? = nil,
        childrenIds: [String] = [],
        role: MessageRole,
        content: String = "",
        timestamp: Date = .now,
        model: String? = nil,
        done: Bool = true,
        files: [ChatMessageFile] = [],
        sources: [ChatSourceReference] = [],
        followUps: [String] = [],
        statusHistory: [ChatStatusUpdate] = [],
        error: ChatMessageError? = nil,
        usage: [String: Any]? = nil,
        embeds: [String] = [],
        models: [String] = [],
        annotation: MessageAnnotation? = nil,
        feedbackId: String? = nil,
        isInternalMessage: Bool = false,
        subagentDelegationId: String? = nil,
        output: [[String: Any]] = []
    ) {
        self.id = id
        self.parentId = parentId
        self.childrenIds = childrenIds
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.model = model
        self.done = done
        self.files = files
        self.sources = sources
        self.followUps = followUps
        self.statusHistory = statusHistory
        self.error = error
        self.usage = usage
        self.embeds = embeds
        self.models = models
        self.annotation = annotation
        self.feedbackId = feedbackId
        self.isInternalMessage = isInternalMessage
        self.subagentDelegationId = subagentDelegationId
        self.output = output
    }

    // MARK: - Serialization

    /// Converts this node to the server's JSON dict format for `history.messages[id]`.
    func toServerDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "parentId": (parentId as Any?) ?? NSNull(),
            "childrenIds": childrenIds,
            "role": role.rawValue,
            "content": content,
            "timestamp": Int(timestamp.timeIntervalSince1970)
        ]

        if role == .assistant {
            if let m = model { dict["model"] = m; dict["modelName"] = m }
            dict["modelIdx"] = 0
            dict["done"] = done
        }

        if role == .user && !models.isEmpty {
            dict["models"] = models
        }

        if !files.isEmpty {
            let filesArray: [[String: Any]] = files.compactMap { file -> [String: Any]? in
                guard let url = file.url else { return nil }
                var d: [String: Any] = [
                    "type": file.type ?? "file",
                    "id": url,
                    "url": url
                ]
                if let name = file.name { d["name"] = name }
                if let ct = file.contentType { d["content_type"] = ct }
                return d
            }
            if !filesArray.isEmpty { dict["files"] = filesArray }
        }

        if !sources.isEmpty {
            let sourcesArray: [[String: Any]] = sources.map { source in
                var d: [String: Any] = [:]
                if let id = source.id { d["id"] = id }
                if let title = source.title { d["name"] = title }
                if let url = source.url { d["url"] = url; d["source"] = url }
                if let snippet = source.snippet { d["snippet"] = snippet }
                if let type = source.type { d["type"] = type }
                if let meta = source.metadata {
                    var metaDict: [String: Any] = [:]
                    for (k, v) in meta { metaDict[k] = v }
                    if !metaDict.isEmpty { d["metadata"] = [metaDict] }
                }
                d["document"] = source.snippet.map { [$0] } ?? ([] as [String])
                return d
            }
            dict["sources"] = sourcesArray
        }

        if !followUps.isEmpty {
            dict["followUps"] = followUps
        }

        if let error {
            dict["error"] = ["content": error.content ?? ""]
        }

        if let usage, !usage.isEmpty {
            dict["usage"] = usage
        }

        if let annotation {
            dict["annotation"] = annotation.toDict()
        }

        if let feedbackId {
            dict["feedbackId"] = feedbackId
        }

        if !statusHistory.isEmpty {
            let statusArray: [[String: Any]] = statusHistory.map { status in
                var d: [String: Any] = [:]
                if let action = status.action { d["action"] = action }
                if let st = status.status { d["status"] = st }
                if let desc = status.description { d["description"] = desc }
                if let done = status.done { d["done"] = done }
                if let hidden = status.hidden { d["hidden"] = hidden }
                if !status.urls.isEmpty { d["urls"] = status.urls }
                if let count = status.count { d["count"] = count }
                if let query = status.query { d["query"] = query }
                if !status.queries.isEmpty { d["queries"] = status.queries }
                if !status.items.isEmpty {
                    d["items"] = status.items.map { item in
                        var itemDict: [String: Any] = [:]
                        if let title = item.title { itemDict["title"] = title }
                        if let link = item.link { itemDict["link"] = link }
                        return itemDict
                    }
                }
                return d
            }
            dict["statusHistory"] = statusArray
        }

        // Re-emit the raw output array verbatim so the server's v0.7+ format is
        // preserved across every sync. Without this, the server loses the `output`
        // array and falls back to `content` only — which strips `files` and breaks
        // image rendering when switching between regenerated versions.
        if !output.isEmpty {
            dict["output"] = output
        }

        return dict
    }
}

// MARK: - MessageHistory

/// The tree-based message history that mirrors OpenWebUI's `history` object.
///
/// Contains a dictionary of `HistoryNode` values keyed by message ID, plus
/// a `currentId` pointing to the leaf of the active branch. The flat
/// `[ChatMessage]` array displayed in the UI is derived by walking from
/// `currentId` to the root via `parentId` chains, then reversing.
///
/// All mutation operations (edit, regenerate, new message, version switch)
/// modify the tree directly, then the flat list is re-derived.
struct MessageHistory: Sendable {
    var nodes: [String: HistoryNode] = [:]
    var currentId: String?

    /// Whether the tree has been populated (non-empty).
    var isPopulated: Bool { !nodes.isEmpty }

    // MARK: - Tree Walking

    /// Derives the ordered flat message list by walking from `currentId` to root.
    ///
    /// This is the primary way to get the `[ChatMessage]` array for the UI.
    /// Each node on the current branch path becomes a `ChatMessage`, with
    /// `versions` populated from tree siblings so the existing UI version
    /// switcher works without modification.
    func createMessagesList() -> [ChatMessage] {
        guard let currentId else { return [] }

        // Walk from currentId → root via parentId chain
        var chain: [String] = []
        var cursor: String? = currentId
        var visited = Set<String>()
        while let id = cursor, !visited.contains(id), let node = nodes[id] {
            visited.insert(id)
            chain.append(id)
            cursor = node.parentId
        }
        chain.reverse()

        // Convert each node to ChatMessage with versions from siblings
        return chain.compactMap { id -> ChatMessage? in
            guard let node = nodes[id] else { return nil }

            // Build versions from sibling nodes (same parent, same role, differeznt ID)
            let siblingIds = siblings(of: id)
            var versions: [ChatMessageVersion] = []
            for sibId in siblingIds where sibId != id {
                guard let sibNode = nodes[sibId] else { continue }
                let version = ChatMessageVersion(
                    id: sibNode.id,
                    content: sibNode.content,
                    timestamp: sibNode.timestamp,
                    model: sibNode.model,
                    error: sibNode.error,
                    files: sibNode.files,
                    sources: sibNode.sources,
                    followUps: sibNode.followUps,
                    statusHistory: sibNode.statusHistory,
                    usage: sibNode.usage
                )

                // The tree is the source of truth for branching. Navigation between
                // edit/regen branches uses restoreUserVersion/restoreAssistantVersion
                // which call deepestLeaf() and re-derive the flat list from the tree.
                // The version object carries only the sibling node's own content/metadata.
                versions.append(version)
            }

            // Sort versions by timestamp (oldest first) for both user and assistant,
            // so versions[0] is always the oldest sibling and the index matches
            // the timestamp-based displayIndex calculation in the action bar.
            if !versions.isEmpty {
                versions.sort { $0.timestamp < $1.timestamp }
            }

            return ChatMessage(
                id: node.id,
                parentId: node.parentId,
                role: node.role,
                content: node.content,
                timestamp: node.timestamp,
                model: node.model,
                files: node.files,
                sources: node.sources,
                statusHistory: node.statusHistory,
                followUps: node.followUps,
                error: node.error,
                versions: versions,
                usage: node.usage,
                embeds: node.embeds,
                annotation: node.annotation,
                feedbackId: node.feedbackId,
                isInternalMessage: node.isInternalMessage,
                subagentDelegationId: node.subagentDelegationId
            )
        }
    }

    /// Returns all sibling IDs of a node (children of the same parent with the same role).
    ///
    /// For root-level nodes (parentId == nil), returns all root nodes with the same role.
    /// The returned array is ordered: oldest first, newest last. The active sibling
    /// (the one on the current branch) is typically last, matching OpenWebUI's convention.
    func siblings(of nodeId: String) -> [String] {
        guard let node = nodes[nodeId] else { return [nodeId] }

        if let parentId = node.parentId, let parent = nodes[parentId] {
            // Non-root: filter parent's children by same role
            return parent.childrenIds.filter { childId in
                guard let child = nodes[childId] else { return false }
                return child.role == node.role
            }
        } else {
            // Root-level node: find all root nodes with the same role
            return nodes.values
                .filter { $0.parentId == nil && $0.role == node.role }
                .sorted { $0.timestamp < $1.timestamp }
                .map(\.id)
        }
    }

    /// Walks from a node to its deepest leaf by always following the last child.
    ///
    /// In OpenWebUI's convention, the last child in `childrenIds` is the "active"
    /// branch. This method finds the leaf of that active branch, which becomes
    /// the new `currentId` when switching to a sibling.
    func deepestLeaf(from nodeId: String) -> String {
        var current = nodeId
        while let node = nodes[current],
              let lastChild = node.childrenIds.last,
              nodes[lastChild] != nil {
            current = lastChild
        }
        return current
    }

    // MARK: - Tree Mutation

    /// Adds a new node to the tree. Does NOT update parent's childrenIds — call
    /// `appendChildId(_:to:)` separately for that.
    mutating func addNode(_ node: HistoryNode) {
        nodes[node.id] = node
    }

    /// Appends a child ID to a parent node's `childrenIds` array.
    /// No-op if the child is already listed.
    mutating func appendChildId(_ childId: String, to parentId: String) {
        guard var parent = nodes[parentId] else { return }
        if !parent.childrenIds.contains(childId) {
            parent.childrenIds.append(childId)
            nodes[parentId] = parent
        }
    }

    /// Removes a child ID from a parent node's `childrenIds` array.
    mutating func removeChildId(_ childId: String, from parentId: String) {
        guard var parent = nodes[parentId] else { return }
        parent.childrenIds.removeAll { $0 == childId }
        nodes[parentId] = parent
    }

    /// Removes a node and its entire subtree from the tree.
    /// Also removes the node from its parent's `childrenIds`.
    mutating func removeSubtree(rootId: String) {
        guard let node = nodes[rootId] else { return }
        // Remove from parent
        if let parentId = node.parentId {
            removeChildId(rootId, from: parentId)
        }
        // Recursively remove all descendants
        var queue = [rootId]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let n = nodes.removeValue(forKey: id) {
                queue.append(contentsOf: n.childrenIds)
            }
        }
    }

    /// Updates a specific node in-place. Useful for streaming content updates.
    mutating func updateNode(id: String, _ transform: (inout HistoryNode) -> Void) {
        guard var node = nodes[id] else { return }
        transform(&node)
        nodes[id] = node
    }

    // MARK: - Serialization

    /// Converts the entire history to the server's JSON format.
    ///
    /// Returns: `["messages": messagesMap, "currentId": currentId]`
    func toServerDict() -> [String: Any] {
        var messagesMap: [String: Any] = [:]
        for (id, node) in nodes {
            messagesMap[id] = node.toServerDict()
        }
        return [
            "messages": messagesMap,
            "currentId": (currentId as Any?) ?? NSNull()
        ]
    }

    // MARK: - Parsing

    /// Populates the tree from the server's `history` JSON object.
    ///
    /// Expects: `{"messages": {id: nodeDict, ...}, "currentId": "..."}`
    static func fromServerJSON(_ historyJSON: [String: Any],
                               messagesMap: [String: [String: Any]],
                               currentId: String?) -> MessageHistory {
        var history = MessageHistory()
        history.currentId = currentId

        for (id, msgData) in messagesMap {
            history.nodes[id] = parseNode(id: id, from: msgData)
        }

        return history
    }

    // MARK: - v0.7 Output Array Reconstruction

    /// Reconstructs a legacy-style content string from Open WebUI v0.7's structured
    /// `output` array, producing inline `<details type="tool_calls">` and
    /// `<details type="reasoning">` blocks that the existing `ToolCallParser`
    /// can render without modification.
    ///
    /// Output array structure (v0.7+):
    /// ```
    /// [
    ///   { type: "message", content: [{type: "output_text", text: "..."}] },
    ///   { type: "function_call", id: "...", call_id: "...", name: "search_web", arguments: "{...}", status: "completed" },
    ///   { type: "function_call_output", call_id: "...", output: [{type: "input_text", text: "..."}], status: "completed" },
    ///   { type: "message", content: [{type: "output_text", text: "Final answer..."}] },
    /// ]
    /// ```
    ///
    /// Returns `nil` if the output array is empty or has no usable content.
    static func reconstructContentFromOutput(_ outputArr: [[String: Any]]) -> String? {
        // First pass: build a map of call_id → result text AND call_id → embeds
        // from function_call_output items.
        var outputByCallId: [String: String] = [:]
        var embedsByCallId: [String: [String]] = [:]
        for item in outputArr {
            guard (item["type"] as? String) == "function_call_output",
                  let callId = item["call_id"] as? String else { continue }
            // Extract result text from output[].text
            if let outputItems = item["output"] as? [[String: Any]] {
                let texts = outputItems.compactMap { o -> String? in
                    guard let text = o["text"] as? String, !text.isEmpty else { return nil }
                    return text
                }
                if !texts.isEmpty {
                    outputByCallId[callId] = texts.joined(separator: "\n")
                }
            }
            // Extract embeds — new server format stores Rich UI HTML here directly
            // as a [String] array on the function_call_output item itself.
            if let embeds = item["embeds"] as? [String] {
                let filtered = embeds.filter { !$0.isEmpty && !$0.contains("data-iv-build") }
                if !filtered.isEmpty {
                    embedsByCallId[callId] = filtered
                }
            }
        }

        // Second pass: build content string in order
        var parts: [String] = []
        for item in outputArr {
            guard let type = item["type"] as? String else { continue }

            switch type {
            case "message":
                // Plain text or final answer
                guard let contentArr = item["content"] as? [[String: Any]] else { continue }
                let textParts = contentArr.compactMap { piece -> String? in
                    guard (piece["type"] as? String) == "output_text",
                          let text = piece["text"] as? String, !text.isEmpty else { return nil }
                    return text
                }
                let text = textParts.joined()
                if !text.isEmpty {
                    parts.append(text)
                }

            case "function_call":
                // Tool call → reconstruct <details type="tool_calls"> block
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                let callId = item["call_id"] as? String ?? item["id"] as? String ?? ""
                let itemId = item["id"] as? String ?? callId
                let status = item["status"] as? String ?? "completed"
                let isDone = (status == "completed")
                let arguments = item["arguments"] as? String ?? ""

                // HTML-entity encode arguments for use as an attribute value
                let encodedArgs = htmlEntityEncode(arguments)
                // Retrieve the matching result
                let resultText = outputByCallId[callId] ?? ""
                let encodedResult = htmlEntityEncode(resultText)

                let doneAttr = isDone ? "true" : "false"

                // Build embeds attribute if this call produced Rich UI HTML embeds.
                // The new server format stores them on the matching function_call_output
                // item. We JSON-encode the array and HTML-entity-encode it so that
                // parseEmbedsAttribute() in ToolCallParser can decode it unchanged.
                let embedsAttr: String = {
                    guard let embeds = embedsByCallId[callId], !embeds.isEmpty else { return "" }
                    // JSON-encode the array: ["<html>...", ...]
                    guard let jsonData = try? JSONSerialization.data(withJSONObject: embeds),
                          let jsonStr = String(data: jsonData, encoding: .utf8) else { return "" }
                    // HTML-entity encode for safe embedding as an attribute value
                    let encoded = jsonStr
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "\"", with: "&quot;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    return " embeds=\"\(encoded)\""
                }()

                // Build the details block matching ToolCallParser expectations
                // Result goes both as `result` attribute (fast path) and as body (fallback)
                let block: String
                if resultText.isEmpty {
                    block = """
                    <details type="tool_calls" id="\(itemId)" name="\(name)" done="\(doneAttr)" arguments="\(encodedArgs)"\(embedsAttr)>
                    <summary>Tool Executed</summary>
                    </details>
                    """
                } else {
                    block = """
                    <details type="tool_calls" id="\(itemId)" name="\(name)" done="\(doneAttr)" arguments="\(encodedArgs)" result="\(encodedResult)"\(embedsAttr)>
                    <summary>Tool Executed</summary>
                    \(resultText)
                    </details>
                    """
                }
                parts.append(block)

            case "reasoning":
                // Reasoning block (e.g. from Gemini) → <details type="reasoning">
                if let contentArr = item["content"] as? [[String: Any]] {
                    let reasoningText = contentArr.compactMap { piece -> String? in
                        guard (piece["type"] as? String) == "output_text",
                              let text = piece["text"] as? String, !text.isEmpty else { return nil }
                        return text
                    }.joined()
                    if !reasoningText.isEmpty {
                        let block = """
                        <details type="reasoning" done="true">
                        <summary>Thinking</summary>
                        \(reasoningText)
                        </details>
                        """
                        parts.append(block)
                    }
                }

            default:
                break  // Skip function_call_output (already consumed above) and unknown types
            }
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    /// HTML-entity encodes a string for safe use as an XML/HTML attribute value.
    /// Encodes & " < > ' to prevent attribute parsing issues in ToolCallParser.
    private static func htmlEntityEncode(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Parses a single node from server JSON.
    static func parseNode(id: String, from msg: [String: Any]) -> HistoryNode {
        let roleStr = msg["role"] as? String ?? "user"
        let role = MessageRole(rawValue: roleStr) ?? .user
        var content = msg["content"] as? String ?? ""
        // v0.7+: content is stored in a structured `output` array.
        // Reconstruct the full content string (with inline <details> blocks for
        // tool calls and reasoning) so the existing ToolCallParser renders everything
        // correctly: text, tool call cards, and reasoning blocks — all in order.
        //
        // Always prefer the output array when present — even when `content` is non-empty.
        // OpenWebUI 0.10+ stores only a compact tool-result summary blob in `content`
        // (e.g. "📊 Presentazione pronta · 14 slide") while the full rich response
        // (prose + tool call blocks + final answer) lives in the `output` array.
        // Using `content` directly would show the stub instead of the real reply.
        if let outputArr = msg["output"] as? [[String: Any]], !outputArr.isEmpty {
            if let reconstructed = reconstructContentFromOutput(outputArr) {
                content = reconstructed
            }
        }
        // Extract any inline base64 image data URIs off the main thread.
        // Replaces ![alt](data:image/...;base64,...) with ![alt](imgcache://TOKEN)
        // so SwiftUI never receives 500 KB strings in content during layout passes.
        content = InlineImageStore.extractAndReplace(content: content)

        var timestamp = Date()
        if let ts = msg["timestamp"] as? Double {
            timestamp = ts > 1_000_000_000_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }

        let model = msg["model"] as? String ?? msg["modelName"] as? String
        let done = msg["done"] as? Bool ?? true
        let parentId = msg["parentId"] as? String
        let childrenIds = msg["childrenIds"] as? [String] ?? []
        let models = msg["models"] as? [String] ?? []

        // Parse files
        var files: [ChatMessageFile] = []
        if let rawFiles = msg["files"] as? [[String: Any]] {
            for file in rawFiles {
                let fileType = file["type"] as? String
                let fileUrl = file["url"] as? String ?? file["id"] as? String
                let fileName = file["name"] as? String
                let contentType = file["content_type"] as? String
                    ?? (file["meta"] as? [String: Any])?["content_type"] as? String
                files.append(ChatMessageFile(
                    type: fileType, url: fileUrl, name: fileName, contentType: contentType
                ))
            }
        }

        // Parse sources
        var sources: [ChatSourceReference] = []
        if let rawSources = msg["sources"] as? [[String: Any]] {
            for src in rawSources {
                var baseSource = (src["source"] as? [String: Any]) ?? [:]
                for key in ["id", "name", "title", "url", "link", "type"] {
                    if let value = src[key], baseSource[key] == nil { baseSource[key] = value }
                }

                let metadataRaw = src["metadata"]
                let metadataList: [[String: Any]]
                if let list = metadataRaw as? [[String: Any]] { metadataList = list }
                else if let single = metadataRaw as? [String: Any] { metadataList = [single] }
                else { metadataList = [] }

                let documents = (src["document"] as? [Any]) ?? []
                let loopCount = max(1, max(documents.count, metadataList.count))

                for i in 0..<loopCount {
                    let meta = i < metadataList.count ? metadataList[i] : [:]
                    let document = i < documents.count ? documents[i] : nil

                    var url: String?
                    for k in ["source", "url", "link"] {
                        if let v = meta[k] as? String, v.hasPrefix("http") { url = v; break }
                    }
                    if url == nil, let v = baseSource["url"] as? String, v.hasPrefix("http") { url = v }

                    let title: String? = (meta["name"] as? String) ?? (meta["title"] as? String)
                        ?? (baseSource["name"] as? String) ?? (baseSource["title"] as? String)

                    let snippet: String? = (document as? String)?
                        .trimmingCharacters(in: .whitespaces)
                    let srcId = (meta["source"] as? String) ?? (meta["id"] as? String) ?? (baseSource["id"] as? String)

                    let isDuplicate = sources.contains { ($0.url != nil && $0.url == url) || ($0.id != nil && $0.id == srcId) }
                    if !isDuplicate {
                        var metaDict: [String: String] = [:]
                        for (k, v) in meta { if let s = v as? String { metaDict[k] = s } }

                        sources.append(ChatSourceReference(
                            id: srcId, title: title, url: url,
                            snippet: (snippet?.isEmpty ?? true) ? nil : snippet,
                            type: (baseSource["type"] as? String) ?? (meta["type"] as? String),
                            metadata: metaDict.isEmpty ? nil : metaDict
                        ))
                    }
                }
            }
        }

        let followUps = msg["followUps"] as? [String] ?? msg["follow_ups"] as? [String] ?? []

        // Parse embeds
        let embeds: [String] = {
            if let arr = msg["embeds"] as? [String] {
                return arr.filter { !$0.isEmpty }
            }
            return []
        }()

        // Parse error
        var error: ChatMessageError?
        if let errObj = msg["error"] as? [String: Any] {
            error = ChatMessageError(content: errObj["content"] as? String)
        }

        // Parse usage
        var usage: [String: Any]?
        if let rawUsage = msg["usage"] as? [String: Any], !rawUsage.isEmpty {
            usage = rawUsage
        }

        // Parse statusHistory
        var statusHistory: [ChatStatusUpdate] = []
        if let rawHistory = msg["statusHistory"] as? [[String: Any]] {
            for item in rawHistory {
                var statusItems: [ChatStatusItem] = []
                if let rawItems = item["items"] as? [[String: Any]] {
                    for rawItem in rawItems {
                        statusItems.append(ChatStatusItem(
                            title: rawItem["title"] as? String,
                            link: rawItem["link"] as? String
                        ))
                    }
                }
                statusHistory.append(ChatStatusUpdate(
                    action: item["action"] as? String,
                    status: item["status"] as? String,
                    description: item["description"] as? String,
                    done: item["done"] as? Bool,
                    hidden: item["hidden"] as? Bool,
                    urls: item["urls"] as? [String] ?? [],
                    items: statusItems,
                    count: item["count"] as? Int,
                    query: item["query"] as? String,
                    queries: item["queries"] as? [String] ?? []
                ))
            }
        }

        // Parse annotation
        var annotation: MessageAnnotation?
        if let rawAnnotation = msg["annotation"] as? [String: Any] {
            var rating: Int?
            if let r = rawAnnotation["rating"] as? Int { rating = r }
            let tags = rawAnnotation["tags"] as? [String] ?? []
            let reason = rawAnnotation["reason"] as? String
            let comment = rawAnnotation["comment"] as? String
            var detailRating: Int?
            if let details = rawAnnotation["details"] as? [String: Any],
               let dr = details["rating"] as? Int {
                detailRating = dr
            }
            annotation = MessageAnnotation(
                rating: rating, tags: tags, reason: reason,
                comment: comment, detailRating: detailRating
            )
        }

        // Parse feedbackId
        let feedbackId = msg["feedbackId"] as? String

        // Parse meta — used for internal sub-agent messages
        // e.g. { "internal": true, "type": "subagent", "delegation_id": "deleg_..." }
        var isInternalMessage = false
        var subagentDelegationId: String?
        if let metaDict = msg["meta"] as? [String: Any] {
            isInternalMessage = metaDict["internal"] as? Bool ?? false
            if isInternalMessage {
                subagentDelegationId = metaDict["delegation_id"] as? String
            }
        }

        // Preserve the raw output array (v0.7+) so it can be re-emitted verbatim
        // on every sync. This prevents the server's canonical format from being
        // corrupted when the app re-serializes a node it loaded from the server.
        let rawOutput = msg["output"] as? [[String: Any]] ?? []

        return HistoryNode(
            id: id,
            parentId: parentId,
            childrenIds: childrenIds,
            role: role,
            content: content,
            timestamp: timestamp,
            model: model,
            done: done,
            files: files,
            sources: sources,
            followUps: followUps,
            statusHistory: statusHistory,
            error: error,
            usage: usage,
            embeds: embeds,
            models: models,
            annotation: annotation,
            feedbackId: feedbackId,
            isInternalMessage: isInternalMessage,
            subagentDelegationId: subagentDelegationId,
            output: rawOutput
        )
    }
}
