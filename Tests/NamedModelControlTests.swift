import Foundation

@main
struct NamedModelControlTests {
    static func main() throws {
        let json = #"""
        {"data":[{"id":"kite-model","info":{"params":{"model_controls":{
          "effort":{"display":"slider","label":"Effort","default":"medium","options":{"low":{"label":"Low"},"medium":{"label":"Medium"},"high":{"label":"High"}}},
          "style":{"label":"Style","options":{"brief":{"label":"Brief","params":{"max_tokens":128,"temperature":0.2}},"full":{"label":"Full"}}}
        }},"meta":{"i18n":{"fr":{"model_controls.effort.label":"Effort traduit","model_controls.effort.options.medium.label":"Moyen","model_controls.style.description":"Description traduite"}}}}}]}
        """#.data(using: .utf8)!
        let controls = NamedModelControl.decode(json, locales: ["fr-CA", "fr"])["kite-model"]!
        precondition(controls.map(\.id) == ["effort", "style"])
        precondition(controls[0].options.map(\.id) == ["low", "medium", "high"])
        precondition(controls[0].label == "Effort traduit" && controls[0].defaultLabel == "Default · Moyen")
        precondition(controls[1].description == "Description traduite")
        let cached = try JSONDecoder().decode([NamedModelControl].self, from: JSONEncoder().encode(controls))
        precondition(cached == controls)
        let singleton = #"{"id":"single","params":{"model_controls":{"a":{"label":"Quoted \"label\"","options":{"x":{"label":"Café"}}}}}}"#.data(using: .utf8)!
        precondition(NamedModelControl.decode(singleton, locales: [])["single"]?.first?.label == "Quoted \"label\"")
        let existing: [String: Any] = ["ui": ["theme": "sample", "params": ["temperature": 0.4, "future": true, "model_controls": ["kite-model": ["effort": "low", "unknown": "keep"], "other": ["style": "full"]]]]]
        let ui = NamedModelControl.settingsUI(existing, modelID: "kite-model", controlIDs: ["effort", "style"], selections: ["style": "brief"])
        let params = ui["params"] as! [String: Any]
        let choices = params["model_controls"] as! [String: [String: String]]
        precondition(choices["kite-model"] == ["unknown": "keep", "style": "brief"])
        precondition(choices["other"] == ["style": "full"] && ui["theme"] as? String == "sample")
        precondition(params["temperature"] as? Double == 0.4 && params["future"] as? Bool == true)
        let defaults = UserDefaultParams(from: ui)
        precondition(defaults.hasAnyOverride)
        precondition(defaults.toRequestParams()["model_controls"] as? [String: [String: String]] == choices)
        let decoded = try JSONDecoder().decode(UserDefaultParams.self, from: JSONEncoder().encode(defaults))
        precondition(decoded.modelControls == choices)
        print("Named model control order, translations, settings preservation and request/cache round trips passed.")
    }
}
