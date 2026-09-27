import Foundation
import CryptoKit

enum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }

// Only the request builder is substituted. Parsing, history reconstruction,
// cache, URLSession download/progress/cancellation and auth checks are production code.
final class FixtureNetwork: @unchecked Sendable {
    let baseURL: URL
    let session = URLSession(configuration: .ephemeral)
    var conversationCacheScope: String? = "synthetic-account"
    init(_ url: URL) { baseURL = url }
    func buildRequest(path: String, queryItems: [URLQueryItem], timeout: TimeInterval) throws -> URLRequest {
        var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        url.path = path
        url.queryItems = queryItems
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = timeout
        request.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
        return request
    }
}
final class APIClient: Sendable { let network: FixtureNetwork; init(_ url: URL) { network = FixtureNetwork(url) } }

@main enum Tests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String = #function, line: Int = #line) {
        checks += 1
        precondition(value, "\(message) line \(line)")
    }
    static func hash(_ url: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256()
        while let chunk = try stream.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let api = APIClient(base)
        func json(_ path: String) async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(path))
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        _ = try await json("fixture/reset")
        let chats = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: [String: Any]]
        let chat = chats["synthetic-files"]!["chat"] as! [String: Any]
        let history = chat["history"] as! [String: Any]
        let messages = history["messages"] as! [String: [String: Any]]
        let content = MessageHistory.parseNode(id: "answer", from: messages["answer"]!).content
        let parsed = ToolCallParser.parseOrdered(content)
        check(parsed.allToolCalls.count == 4)
        let files = parsed.allToolCalls.compactMap(\.terminalFile)
        check(files.count == 4)
        let video = files[0]
        check(video.name == "motion.mp4" && video.isMedia && files[1].isMedia && !files[2].isMedia)
        check(video.sessionId == "synthetic-files" && video.serverId == "demo-terminal")
        check(video.size == 52_500_000 && video.inline)
        let ref: [String: Any] = ["source": "open_terminal", "type": "file", "terminal_selector": "demo-terminal", "path": "/workspace/motion.mp4"]
        func file(_ updates: [String: Any] = [:]) -> TerminalFileAttachment? {
            TerminalFileAttachment(result: String(data: try! JSONSerialization.data(withJSONObject: ref.merging(updates) { _, new in new }), encoding: .utf8))
        }
        check(file() != nil && file(["displayed": false]) != nil)
        check(file(["exists": false]) == nil && file(["source": "other"]) == nil && file(["type": "directory"]) == nil)
        for id in ["", ".", "..", "https://example.test", "../x", "x/y", "x?y", "x#y", "%2F"] { check(file(["terminal_selector": id]) == nil) }
        check(file(["name": "../../safe.mp4"])?.name == "safe.mp4")
        check(file(["full_path": "/workspace/resolved.mp4"])?.path == "/workspace/resolved.mp4")
        check(TerminalFileAttachment(result: "not JSON") == nil)
        check(TerminalFileAttachment(event: ["path": video.path], serverId: nil, sessionId: "synthetic-files") == nil)
        let live = TerminalFileAttachment(event: ["path": video.path], serverId: video.serverId, sessionId: "synthetic-files")!
        check(TerminalFileAttachment.merged([video, live, file()!], sessionId: "synthetic-files").count == 1)
        check(TerminalFileAttachment.merged([video, file(["session_id": "different"])!], sessionId: nil).count == 2)
        let ordinary = chats["synthetic-ordinary"]!["chat"] as! [String: Any]
        let ordinaryMessages = ordinary["messages"] as! [[String: Any]]
        let ordinaryResult = ToolCallParser.parseOrdered(MessageHistory.parseNode(id: "answer", from: ordinaryMessages[1]).content)
        check(ordinaryResult.allToolCalls.first?.embeds.first?.contains("Sample table") == true)
        check(ordinaryResult.allToolCalls.first?.terminalFile == nil)
        for _ in 0..<200 { _ = ToolCallParser.parseOrdered(content) }
        check((try await json("fixture/metrics")["requests"] as! [String: Int]).isEmpty, "Metadata reconstruction is network-free")
        print("PASS: saved structured output, descriptors, live merge, session isolation; zero metadata requests")

        let download = try await api.downloadTerminalAttachment(video, messageId: "answer", scope: "synthetic-account") { _, _ in }
        check(download.byteCount > 49_000_000 && download.byteCount < 56_000_000)
        check(try hash(download.url) == hash(URL(fileURLWithPath: CommandLine.arguments[2])))
        let cached = try await api.downloadTerminalAttachment(video, messageId: "answer", scope: "synthetic-account") { _, _ in }
        check(download.url == cached.url)
        var metrics = try await json("fixture/metrics")
        check(metrics["requests"] as! [String: Int] == ["motion.mp4": 1])
        check((metrics["bytes"] as! [String: Int64])["motion.mp4"] == download.byteCount)
        let text = try await api.downloadTerminalAttachment(files[2], messageId: "answer", scope: "synthetic-account") { _, _ in }
        check(try String(contentsOf: text.url, encoding: .utf8) == "A freshly invented sample document.\n")
        check((try await json("fixture/metrics")["requests"] as! [String: Int])["tone.m4a"] == nil)
        _ = try await api.downloadTerminalAttachment(files[2], messageId: "another-message", scope: "synthetic-account") { _, _ in }
        api.network.conversationCacheScope = "another-account"
        _ = try await api.downloadTerminalAttachment(files[2], messageId: "answer", scope: "another-account") { _, _ in }
        api.network.conversationCacheScope = "synthetic-account"
        check((try await json("fixture/metrics")["requests"] as! [String: Int])["notes.txt"] == 3)
        print("PASS: actual 50 MB disk download, byte/hash match, cache reuse, independent attachments")

        for (name, status) in [("missing.mp4", 404), ("disconnected.mp4", 503), ("denied.mp4", 403), ("redirect.mp4", 302)] {
            do {
                _ = try await api.downloadTerminalAttachment(file(["path": "/workspace/" + name, "session_id": "synthetic-files"])!, messageId: "errors", scope: "synthetic-account") { _, _ in }
                check(false)
            } catch TerminalFileError.unavailable(let code) { check(code == status) }
        }
        do {
            _ = try await api.downloadTerminalAttachment(file(["session_id": "wrong-chat"])!, messageId: "wrong", scope: "synthetic-account") { _, _ in }
            check(false)
        } catch TerminalFileError.unavailable(let code) { check(code == 403) }
        api.network.conversationCacheScope = "other-account"
        do {
            _ = try await api.downloadTerminalAttachment(video, messageId: "answer", scope: "synthetic-account") { _, _ in }
            check(false)
        } catch TerminalFileError.changedAccount { check(true) }
        api.network.conversationCacheScope = "synthetic-account"
        let slow = file(["path": "/workspace/slow.mp4", "session_id": "synthetic-files"])!
        let task = Task { try await api.downloadTerminalAttachment(slow, messageId: "cancel", scope: "synthetic-account") { _, _ in } }
        try await Task.sleep(for: .milliseconds(500))
        do {
            _ = try await api.downloadTerminalAttachment(slow, messageId: "cancel", scope: "synthetic-account") { _, _ in }
            check(false)
        } catch TerminalFileError.busy { check(true) }
        task.cancel()
        do { _ = try await task.value; check(false) }
        catch is CancellationError { check(true) }
        catch let error as URLError { check(error.code == .cancelled) }
        let retry = file(["path": "/workspace/retry.mp4", "session_id": "synthetic-files"])!
        do {
            _ = try await api.downloadTerminalAttachment(retry, messageId: "retry", scope: "synthetic-account") { _, _ in }
            check(false)
        } catch TerminalFileError.unavailable(let code) { check(code == 500) }
        let recovered = try await api.downloadTerminalAttachment(retry, messageId: "retry", scope: "synthetic-account") { _, _ in }
        check(try hash(recovered.url) == hash(download.url))
        do {
            _ = try await api.downloadTerminalAttachment(file(["path": "/workspace/oversized.mp4", "session_id": "synthetic-files"])!, messageId: "large", scope: "synthetic-account") { _, _ in }
            check(false)
        } catch TerminalFileError.tooLarge { check(true) }
        metrics = try await json("fixture/metrics")
        check((metrics["requests"] as! [String: Int])["redirect-target"] == nil)
        check((metrics["bytes"] as! [String: Int64])["slow.mp4"]! < download.byteCount)
        check((metrics["requests"] as! [String: Int])["retry.mp4"] == 2)
        print("PASS: HTTP errors, auth/session rejection, account changes, cancellation, duplicate taps, retry, byte limit, redirects")
        print("PASS: \(checks) checks")
        print(String(data: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), encoding: .utf8)!)
    }
}
