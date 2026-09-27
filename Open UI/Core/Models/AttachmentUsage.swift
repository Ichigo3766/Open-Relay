import Foundation

nonisolated struct AttachmentUsage: Equatable, Sendable {
    var fileContext = true
    var tools = true

    init(capabilities: [String: String]? = nil, builtinTools: [String: Bool] = [:], functionCalling: String? = nil) {
        fileContext = !["false", "0"].contains(capabilities?["file_context"] ?? "")
        tools = !["false", "0"].contains(capabilities?["builtin_tools"] ?? "")
            && builtinTools["knowledge"] != false && functionCalling != "legacy"
    }

    func title(fullContext: Bool) -> String {
        guard fileContext else { return tools ? "Tools Only" : "File Context Disabled" }
        return fullContext ? "Entire Document" : "Focused Retrieval"
    }
}
