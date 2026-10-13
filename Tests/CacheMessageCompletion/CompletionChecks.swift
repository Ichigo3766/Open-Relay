import Foundation

@main struct CompletionChecks {
    static func check(_ chat: [String: Any], _ expected: Bool, _ label: String) throws {
        // Exercise the immutable Foundation representation used by Response.init(data:id:).
        let data = try JSONSerialization.data(withJSONObject: chat)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(Subject.hasUnfinishedMessages(parsed) == expected, label)
    }

    static func main() throws {
        try check([:], false, "missing messages")
        try check(["history": NSNull(), "messages": NSNull()], false, "null containers")
        try check(["history": ["messages": []], "messages": "invalid"], false, "wrong containers")
        for value: Any in [true, NSNull(), "false", 2] {
            try check(["history": ["messages": ["a": ["done": value]]]], false, "not unfinished")
        }
        try check(["history": ["messages": ["a": ["done": false]]]], true, "unfinished history")
        try check(["messages": [["done": false]]], true, "unfinished flat array")
        try check(["messages": [["done": 0]]], true, "preserve Foundation numeric Bool bridging")
        try check(["messages": [["done": true], [:]]], false, "completed or absent done")
        try check(["history": ["messages": ["a": ["done": true]]],
                   "messages": [["done": false]]], true, "flat fallback must still be checked")
        try check(["history": ["messages": ["a": ["done": false]]],
                   "messages": [["done": true]]], true, "history takes precedence")
        try check(["history": ["messages": ["a": NSNull()]],
                   "messages": [["done": false]]], true, "invalid history must not hide flat state")
        try check(["history": ["messages": ["a": NSNull(), "b": ["done": false]]]],
                  true, "invalid sibling must not hide unfinished history")
        try check(["messages": [NSNull(), ["done": false]]], true, "invalid sibling must not hide unfinished flat message")
        try check(["history": ["messages": ["a": NSNull(), "b": ["done": true]]],
                   "messages": [NSNull(), ["done": true]]], false, "invalid and completed elements")
        var nodes: [String: Any] = [:]
        var flat: [Any] = []
        for i in 0..<10_000 {
            let node: [String: Any] = ["id": "synthetic-\(i)", "done": true,
                                      "content": "Invented cardboard telescope.", "extra": ["nested": [1, 2, 3]]]
            nodes["synthetic-\(i)"] = node
            flat.append(node)
        }
        try check(["history": ["messages": nodes], "messages": flat], false, "large completed chat")
        nodes["synthetic-inactive-branch"] = ["done": false]
        try check(["history": ["messages": nodes], "messages": flat], true, "unfinished inactive branch")
        nodes.removeValue(forKey: "synthetic-inactive-branch")
        flat.append(["done": false])
        try check(["history": ["messages": nodes], "messages": flat], true, "unfinished final flat message")
        print("Completion policy: 20 synthetic cases passed")
    }
}
