import Foundation

@main struct Checks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
    static func model(_ fields: [[String: Any]]) -> AIModel {
        AIModel(id: "craft-model", name: "Craft Demo", rawModelItem: ["info": ["meta": ["chat_variables_schema": ["fields": fields]]]])
    }
    static func form(_ fields: [[String: Any]], values: [String: Any] = [:], chat: String? = "craft-chat", scope: String? = "synthetic-scope") -> ChatVariableForm {
        ChatVariableForm(model: model(fields), values: values, chatID: chat, scope: scope)
    }
    static func main() async throws {
        let required: [[String: Any]] = [["key": "topic", "required": true, "label": "Craft topic"]]
        check(form(required).needsInput, "required gate")
        check(form([["key": "optional"]]).needsInput, "native empty optional form gate")
        check(!form([]).needsInput, "ordinary model")
        check(!form(required, values: ["topic": "paper"]).needsInput, "saved value")
        check(!form([["key": "enabled", "type": "checkbox", "required": true, "default": false]]).needsInput, "false is a value")
        check(!form([["key": "count", "type": "number", "required": true, "default": 0]]).needsInput, "zero is a value")
        check(form(required, values: ["topic": NSNull()]).needsInput, "null not a value")
        check(form(required, values: ["topic": ""]).needsInput, "empty not a value")
        check(form([["key": "x", "default": "fallback"]], values: ["x": ""]).fields[0].defaultValue == "fallback", "empty uses default")
        check(form([["key": "x", "default": "fallback"]], values: ["x": "stored"]).fields[0].defaultValue == "stored", "saved wins")
        check(form([["key": "a"], ["key": "a"], [:], ["key": ""]]).fields.count == 1, "malformed and duplicate keys")
        check(form([["key": "x", "type": "future"]]).fields[0].type == .textarea, "unknown type text fallback")
        let allTypes = ["text", "textarea", "select", "number", "checkbox", "date", "datetime-local", "color", "email", "month", "range", "tel", "time", "url", "map"]
        for type in allTypes { check(form([["key": "x", "type": type]]).fields[0].type.rawValue == type, "native type " + type) }
        let typed = form([["key": "enabled", "type": "checkbox", "default": false], ["key": "count", "type": "number", "min": 0, "max": 8, "default": 0], ["key": "topic", "required": true]])
        check(typed.fields[0].defaultValue == "false", "boolean form value")
        check(typed.fields[1].defaultValue == "0", "number form value")
        let values = try typed.merging(["enabled": "false", "count": "0", "topic": "paper\r\nfolds"], into: ["other": ["list": [1, 2]]])
        check(values["enabled"] as? Bool == false, "native boolean")
        check(values["count"] as? Double == 0, "native number")
        check(try form([["key": "scale", "type": "range", "step": 0.25]])
            .merging(["scale": "0.75"], into: [:])["scale"] as? Double == 0.75, "fractional range value")
        check(values["topic"] as? String == "paper\nfolds", "normalize CRLF")
        check((values["other"] as? [String: [Int]])?["list"] == [1, 2], "preserve unknown structured values")
        for invalid in ["not-number", "nan", "inf", "-1", "9"] {
            do { _ = try typed.merging(["topic": "paper", "count": invalid], into: [:]); check(false, "accepts invalid number") }
            catch { check(true, "reject invalid number") }
        }
        do { _ = try form(required).merging([:], into: [:]); check(false, "accepts missing required") }
        catch { check(true, "missing required rejected") }
        let cached = try JSONDecoder().decode(AIModel.self, from: JSONEncoder().encode(model(required)))
        check(ChatVariableForm(model: cached, values: [:], chatID: nil, scope: nil).needsInput, "cache keeps schema")
        check(cached.rawModelItem == nil, "does not persist full raw model")
        check(model(required) != model([]), "schema changes invalidate model equality")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model([]))) as! [String: Any]
        legacy.removeValue(forKey: "chatVariablesSchema")
        check(try JSONDecoder().decode(AIModel.self, from: JSONSerialization.data(withJSONObject: legacy)).chatVariablesSchema == nil, "old cache still decodes")
        var request = ChatCompletionRequest(model: "craft-model", messages: [])
        check(request.toJSON()["chat_variables"] == nil, "saved requests omit fallback")
        request.variables = ["{{CURRENT_DATE}}": "2026-01-01"]
        request.chatVariables = ["topic": "paper", "enabled": false]
        check((request.toJSON()["chat_variables"] as? [String: Any])?["topic"] as? String == "paper", "temporary fallback")
        check((request.toJSON()["variables"] as? [String: String])?["{{CURRENT_DATE}}"] == "2026-01-01", "system vars independent")

        let harness = Harness(), original = form(required)
        try await harness.saveChatVariables(["topic": "paper"], form: original)
        check(harness.manager!.apiClient.writes == 1, "one explicit save")
        check(harness.conversation!.chatVariables["topic"] as? String == "paper", "commit after save")
        check(harness.conversation!.chatVariables["other-model"] != nil, "fresh merge preserves other model")
        check(!harness.isSavingChatVariables, "busy reset")
        harness.manager!.apiClient.fail = true
        do { try await harness.saveChatVariables(["topic": "wood"], form: original); check(false, "failure expected") }
        catch { check(harness.conversation!.chatVariables["topic"] as? String == "paper", "failed save keeps committed state") }
        harness.manager!.apiClient.fail = false
        harness.isSavingChatVariables = true
        do { try await harness.saveChatVariables(["topic": "wood"], form: original); check(false, "duplicate") } catch { check(harness.manager!.apiClient.writes == 2, "duplicate save rejected") }
        harness.isSavingChatVariables = false
        harness.manager!.onFetch = { harness.manager!.apiClient.network.conversationCacheScope = "other-account" }
        do { try await harness.saveChatVariables(["topic": "wood"], form: original); check(false, "account changed") } catch { check(harness.manager!.apiClient.writes == 2, "account switch during GET stops write") }
        harness.manager!.apiClient.network.conversationCacheScope = "synthetic-scope"
        harness.manager!.onFetch = nil
        harness.manager!.apiClient.onSave = { harness.conversationId = "other-chat" }
        do { try await harness.saveChatVariables(["topic": "wood"], form: original); check(false, "chat changed") } catch { check(harness.conversation!.chatVariables["topic"] as? String == "paper", "late save not inserted into other chat") }
        let draft = Harness(); draft.conversation = nil; draft.conversationId = nil
        try await draft.saveChatVariables(["topic": "paper"], form: form(required, chat: nil))
        check(draft.manager!.apiClient.writes == 0 && draft.manager!.fetches == 0, "new draft stays local until send")
        check(draft.pendingChatVariables["topic"] as? String == "paper", "draft values retained")
        draft.conversation = Chat(); draft.conversationId = "local:demo"
        try await draft.saveChatVariables(["topic": "paper"], form: form(required, chat: "local:demo"))
        check(draft.manager!.apiClient.writes == 0, "temporary never creates server chat")
        check(draft.conversation!.chatVariables["topic"] as? String == "paper", "temporary values retained")
        draft.chatVariablesDraftGeneration = 1
        do { try await draft.saveChatVariables(["topic": "wrong draft"], form: form(required, chat: "local:demo")); check(false, "reused draft") }
        catch { check(draft.conversation!.chatVariables["topic"] as? String == "paper", "reset draft rejects stale form") }
        let streaming = Harness(); streaming.isStreaming = true
        do { try await streaming.saveChatVariables(["topic": "paper"], form: original); check(false, "streaming save") }
        catch { check(streaming.manager!.fetches == 0, "streaming prevents save") }
        let creating = Harness(); creating.isCreatingConversation = true
        do { try await creating.saveChatVariables(["topic": "paper"], form: original); check(false, "create overlapping save") }
        catch { check(creating.manager!.fetches == 0, "creation prevents overlapping save") }
        let wire = WireClient()
        try await wire.updateChatVariables(id: "craft-chat", values: values)
        let body = try JSONSerialization.jsonObject(with: wire.network.body!) as! [String: Any]
        check(wire.network.path == "/api/v1/chats/craft-chat", "native save path")
        check((body["chat"] as? [String: Any])?.isEmpty == true, "variable-only patch leaves history untouched")
        check((body["variables"] as? [String: Any])?["enabled"] as? Bool == false, "wire boolean preserved")
        check((body["variables"] as? [String: Any])?["count"] as? Int == 0, "wire number preserved")
        check(await ConversationCache.shared.invalidations == 1, "cache invalidation after save")
        wire.network.onWrite = { wire.network.conversationCacheScope = "other-account" }
        do { try await wire.updateChatVariables(id: "craft-chat", values: values); check(false, "late wire save") }
        catch { check(true, "wire scope change detected") }
        print("\(count) checks passed")
    }
}
