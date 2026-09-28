import Foundation

// Unrelated channel rendering is not part of these model serialization checks.
struct ChannelMessage: Hashable, Sendable {
    static func fromJSON(_ json: [String: Any]) -> ChannelMessage? { nil }
}

// Knowledge attachment serialization is outside this model-editor harness.
struct ChatMessageFile: Hashable, Sendable {
    var type: String?
    var url: String?
    var name: String?
    var id: String? = nil
    var context: String? = nil
    var serverDictionary: [String: Any] { [:] }
}

@main struct Checks {
    @MainActor static func main() throws {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(name)") }
        }
        func equal(_ first: [String: Any], _ second: [String: Any]) -> Bool {
            NSDictionary(dictionary: first).isEqual(to: second)
        }
        let meta: [String: Any] = [
            "actionIds": ["demo-action"], "skillIds": ["demo-skill"],
            "terminalId": "demo-terminal",
            "chat_variables_schema": ["fields": [["key": "topic", "type": "text", "required": true]]],
            "i18n": ["fr": ["description": "Exemple"]],
            "capabilities": ["vision": true, "future_capability": false],
            "builtinTools": ["time": true, "future_tool": true],
            "defaultFeatureIds": ["web_search", "future_feature"],
            "knowledge": [["id": "demo-knowledge", "type": "collection", "name": "Sample", "extra": true]],
            "tts_voice": "demo-voice", "future": ["list": [1, NSNull(), true]],
        ]
        let params: [String: Any] = [
            "temperature": 0.4, "custom_number": 4096, "custom_flag": true,
            "custom_object": ["type": "json_object"], "custom_list": ["one", "two"],
            "custom_null": NSNull(), "custom_string": "true", "empty_string": "",
            "logit_bias": ["123": 1.5], "format": ["type": "object"], "think": "high",
        ]
        let json: [String: Any] = ["id": "demo-model", "name": "Synthetic model", "meta": meta, "params": params]
        var model = ModelDetail(json: json)!
        let canonicalMeta = model.buildMetaPayload()
        check(equal(canonicalMeta["i18n"] as! [String: Any], meta["i18n"] as! [String: Any]), "upstream metadata preservation remains intact")
        check(equal(model.buildParamsPayload(), params), "unmodified parameters preserve values and JSON types")
        check(model.buildMetaPayload()["skillIds"] as? [String] == ["demo-skill"], "skill IDs stay separate from actions")
        model.name = "Renamed"
        check(equal(model.toUpdatePayload()["meta"] as! [String: Any], canonicalMeta), "rename preserves native metadata serialization")
        check(equal(model.toUpdatePayload()["params"] as! [String: Any], params), "rename preserves parameters")
        model.capVision = false
        let caps = model.buildMetaPayload()["capabilities"] as! [String: Any]
        check(caps["vision"] as? Bool == false && caps["future_capability"] as? Bool == false, "capability edit retains unknown sibling")
        model.builtinTime = false
        let tools = model.buildMetaPayload()["builtinTools"] as! [String: Any]
        check(tools["time"] as? Bool == false && tools["future_tool"] as? Bool == true, "builtin toggle retains unknown sibling")
        model.defaultFeatureWebSearch = false
        check(model.buildMetaPayload()["defaultFeatureIds"] == nil, "upstream capability-aware default-feature serialization remains intact")
        model.ttsVoice = ""
        check(model.buildMetaPayload()["tts"] == nil && model.buildMetaPayload()["tts_voice"] == nil, "upstream native voice clearing remains intact")
        model.advTemperature = nil
        check(model.buildParamsPayload()["temperature"] == nil, "choosing Default removes explicit parameter")
        model.customParams.removeAll { $0.key == "custom_flag" }
        check(model.buildParamsPayload()["custom_flag"] == nil, "removing a custom parameter is deliberate")
        model.customParams.append((key: "new_object", value: #"{"enabled":true,"count":2}"#))
        check((model.buildParamsPayload()["new_object"] as? [String: Any])?["count"] as? Int == 2, "new JSON parameter retains object type")
        model.customParams.append((key: "new_text", value: "ordinary text"))
        check(model.buildParamsPayload()["new_text"] as? String == "ordinary text", "plain text parameter remains supported")
        check(model.buildParamsPayload()["custom_string"] as? String == "true", "unchanged string that resembles JSON stays a string")
        let reopened = ModelDetail(json: model.toUpdatePayload())!
        check(equal(reopened.buildMetaPayload(), model.buildMetaPayload()), "second save keeps edited metadata")
        check(equal(reopened.buildParamsPayload(), model.buildParamsPayload()), "second save keeps edited parameters")
        let skillsOnly = ModelDetail(json: ["id": "skills", "name": "Skills only", "meta": ["skillIds": ["demo-skill"]]])!
        check(skillsOnly.actionIds.isEmpty, "skills-only model does not select message actions")
        check(skillsOnly.buildMetaPayload()["skillIds"] as? [String] == ["demo-skill"], "skills-only model survives save")
        var removed = ModelDetail(json: json)!
        removed.skillIds = []
        check(removed.buildMetaPayload()["actionIds"] as? [String] == ["demo-action"], "removing skill does not remove action")
        check(removed.buildMetaPayload()["skillIds"] as? [String] == [], "skill removal persists")
        removed.actionIds = []
        check(removed.buildMetaPayload()["actionIds"] as? [String] == [], "action removal persists independently")
        var form = ModelDetail(json: model.toUpdatePayload())!
        form.preserveUneditedConfiguration(from: ModelDetail(json: json)!)
        check(equal(form.buildParamsPayload(), model.buildParamsPayload()), "editor carries original baseline into rebuilt form")
        check(equal(form.buildMetaPayload(), model.buildMetaPayload()), "editor preserves original metadata baseline")
        var typed = ModelDetail(json: json)!
        typed.customParams[typed.customParams.firstIndex { $0.key == "custom_flag" }!].value = "1"
        let changedType = try JSONSerialization.data(withJSONObject: typed.buildParamsPayload()["custom_flag"]!, options: .fragmentsAllowed)
        check(String(decoding: changedType, as: UTF8.self) == "1", "explicit Boolean-to-number edit changes JSON type")
        check(typed.customParams.first { $0.key == "custom_string" }?.value == #""true""#, "JSON-looking strings are displayed unambiguously")
        typed.customParams[typed.customParams.firstIndex { $0.key == "custom_string" }!].value = "true"
        let changedStringType = try JSONSerialization.data(withJSONObject: typed.buildParamsPayload()["custom_string"]!, options: .fragmentsAllowed)
        check(String(decoding: changedStringType, as: UTF8.self) == "true", "removing string quotes explicitly changes type to Boolean")
        let new = ModelDetail(id: "new", name: "New model")
        check(JSONSerialization.isValidJSONObject(new.toCreatePayload()), "new model has valid JSON defaults")
        print("\(checks - failures)/\(checks) model checks passed")
        if failures > 0 { exit(1) }
    }
}
