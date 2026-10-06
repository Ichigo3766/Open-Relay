import Foundation

// MARK: - Group 4: code utilities + Gravatar

extension APIClient {
    /// POST /api/v1/utils/code/format (admin) — Black-formats Python; returns the code unchanged
    /// when there is nothing to do. Throws with Black's message on a syntax error.
    func formatPythonCode(_ code: String) async throws -> String {
        let json = try await network.requestJSON(path: "/api/v1/utils/code/format", method: .post, body: ["code": code])
        return json["code"] as? String ?? code
    }

    /// POST /api/v1/utils/code/execute — runs Python on the server's Jupyter (web CodeBlock).
    /// `data:image/png;base64,…` lines in stdout become images, like the web.
    func executeCodeOnServer(_ code: String) async -> PythonExecutionResult {
        do {
            let out = try await network.requestJSON(path: "/api/v1/utils/code/execute", method: .post,
                                                    body: ["code": code], timeout: 300)
            var stdout = out["stdout"] as? String ?? ""
            var images: [String] = []
            for line in stdout.components(separatedBy: "\n") where line.hasPrefix("data:image/png;base64") {
                images.append(String(line.split(separator: ",", maxSplits: 1).last ?? ""))
                stdout = stdout.replacingOccurrences(of: line + "\n", with: "").replacingOccurrences(of: line, with: "")
            }
            if let result = out["result"] as? String, !result.isEmpty {
                if result.hasPrefix("data:image/png;base64") {
                    images.append(String(result.split(separator: ",", maxSplits: 1).last ?? ""))
                } else {
                    stdout += (stdout.isEmpty || stdout.hasSuffix("\n") ? "" : "\n") + result
                }
            }
            let stderr = out["stderr"] as? String ?? ""
            return PythonExecutionResult(status: stderr.isEmpty ? .success : .error,
                                         stdout: stdout, stderr: stderr, images: images)
        } catch {
            return PythonExecutionResult(status: .error, stdout: "", stderr: error.localizedDescription, images: [])
        }
    }

    /// GET /api/v1/utils/gravatar?email= → the Gravatar URL for that address.
    func getGravatarURL(email: String) async throws -> String {
        let (data, _) = try await network.requestRaw(path: "/api/v1/utils/gravatar",
                                                     queryItems: [URLQueryItem(name: "email", value: email)])
        if let s = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String { return s }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
    }
}
