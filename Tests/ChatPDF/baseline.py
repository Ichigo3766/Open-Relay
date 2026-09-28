"""Exercise the old PDF method against a synthetic server without the nonexistent route."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
api = subprocess.check_output(["git", "show", "4151a735512d5d6dbc9fd1962fa806517a0d4ea7:Open UI/Core/Networking/APIClient.swift"], cwd=root, text=True)
method = api.split("    func downloadChatAsPDF(", 1)[1].split("    // MARK: - AI Note Features", 1)[0]
code = '''
import Foundation
enum APIError: Error { case responseDecoding(underlying: Error, data: Data?) }
enum Method { case post }
final class Network {
    var paths: [String] = []
    func requestRaw(path: String, method: Method? = nil, body: Data? = nil, timeout: Double? = nil) async throws -> (Data, Int) {
        paths.append(path)
        guard path == "/api/v1/chats/synthetic" else { throw NSError(domain: "Synthetic404", code: 404) }
        return (Data(#"{"chat":{"title":"Paper craft","messages":[{"role":"user","content":"Fold a star."}]}}"#.utf8), 200)
    }
}
final class APIClient { let network = Network()
    func downloadChatAsPDF(''' + method + '''
}
@main struct Main {
    static func main() async throws {
        let api = APIClient()
        do { _ = try await api.downloadChatAsPDF(chatId: "synthetic"); fatalError("Expected missing route failure") }
        catch { precondition((error as NSError).code == 404) }
        precondition(api.network.paths == ["/api/v1/chats/synthetic", "/api/v1/utils/pdf"])
        print("Baseline reproduces unsupported PDF route and duplicate chat fetch")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="relay-pdf-baseline-") as directory:
    path = Path(directory)
    (path / "Main.swift").write_text(code)
    subprocess.run(["swiftc", "-parse-as-library", str(path / "Main.swift"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
