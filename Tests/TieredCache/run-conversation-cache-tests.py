"""Run the production cache/parser algorithms against fresh synthetic fixtures on macOS.
Usage: python3 Tests/TieredCache/run-conversation-cache-tests.py /path/to/scratch-directory
"""
from pathlib import Path
import os
import re
import subprocess
import sys
root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
if out == root or root in out.parents:
    raise SystemExit("Use a scratch directory outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
service = root / "Open UI/Core/Services"
sources = ["ConversationCache.swift", "CachedConversationSnapshot.swift", "DetailsBlockScanner.swift", "DetailsBlockScanner+Bytes.swift", "DetailsBlockScanner+Scan.swift", "DetailsBlockScanner+Code.swift"]
for name in sources:
    source = (service / name).read_text()
    if name == "ConversationCache.swift":
        # Pause the private encoder before preparation to test cancellation races deterministically.
        signature = "        func prepare(_ entry: Entry, id: String, limit: Int) throws -> Prepared {"
        assert source.count(signature) == 1
        source = source.replace(signature, signature.replace(" throws", " async throws") + "\n            await PreparationGateForTesting.shared.wait()")
    (out / name).write_text(source)
with (out / "ConversationCache.swift").open("a") as cache:
    cache.write("\nextension ConversationCache { func flushForTesting() async { for task in Array(pendingStores.values) { await task.value } } }\n")
tool = (root / "Open UI/Shared/Components/ToolCallView.swift").read_text()
parser = tool[tool.index("actor MessageParseCache {"):tool.index("// MARK: - Rich UI")]
if "enum RichUIHeightCache" in parser:
    parser = parser[:parser.index("enum RichUIHeightCache")]
(out / "Parser.swift").write_text("import Foundation\n" + parser + "\nstruct TerminalFileAttachment { init(result: String?, arguments: String?) {} }\nstruct ChatMessageFile { var type: String; var url: String; var name: String?; var contentType: String? }\n")
history = (root / "Open UI/Core/Models/MessageHistory.swift").read_text()
methods=[]
for name in ["reconstructContentFromOutput", "partsText", "stringifyValue", "isTerminalStatus", "durationString", "toolLabel", "openAIToolSummary", "htmlEntityEncode"]:
    start=history.index("static func " + name)
    start=history.rfind("\n", 0, start)+1
    end=re.search(r"^    }$", history[start:], re.M).end()+start
    methods.append(history[start:end])
(out / "Output.swift").write_text("import Foundation\nnonisolated enum MessageHistory {\n" + "\n".join(methods) + "\n}\n")
(out / "Stubs.swift").write_text("""import Foundation
actor PreparationGateForTesting {
    static let shared = PreparationGateForTesting()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() { held = true }
    func wait() async {
        if held { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        held = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
nonisolated struct ConversationIndex: Codable, Sendable { var conversations: [String] = [] }
enum APIError: Error {
    case responseDecoding(underlying: Error, data: Data?)
    case httpError(statusCode: Int, message: String?, data: Data?)
    var requiresReauth: Bool { if case .httpError(let code, _, _) = self { return code == 401 }; return false }
    static func from(_ error: Error) -> APIError { error as? APIError ?? .responseDecoding(underlying: error, data: nil) }
}
""")
(out / "Checks.swift").write_text((root / "Tests/TieredCache/ConversationCacheTests.swift").read_text())
args=["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules")]
args += [str(out / name) for name in sources + ["Parser.swift", "Output.swift", "Stubs.swift", "Checks.swift"]]
args += ["-o", str(out / "checks")]
subprocess.run(args, check=True)
env=dict(os.environ, TMPDIR=str(out))
subprocess.run([str(out / "checks"), str(out / "cases")], env=env, check=True)
