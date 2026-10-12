"""Compile public structural-parser/cache sources with synthetic inputs."""
from pathlib import Path
import os
import argparse
import subprocess

p = argparse.ArgumentParser()
p.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
p.add_argument("output", type=Path)
args = p.parse_args()
out = args.output.resolve()
repo = Path(__file__).resolve().parents[2]
if out == repo or repo in out.parents:
    raise SystemExit("Keep generated binaries and module caches outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
(out / "tmp").mkdir(exist_ok=True)
os.environ["TMPDIR"] = str(out / "tmp") + "/"
tool = (args.root / "Open UI/Shared/Components/ToolCallView.swift").read_text()
source = tool[tool.index("actor MessageParseCache {"):tool.index("// MARK: - Rich UI")]
if "static func containsStructuralMarkers(" not in source:
    start = tool.index("    private var isPlainText: Bool {")
    predicate = tool[start:].splitlines()[1].strip()
    source += "\nextension MessageParseCache { nonisolated static func containsStructuralMarkers(_ content: String) -> Bool { !(" + predicate + ") } }\n"

if "enum RichUIHeightCache" in source:
    source = source[:source.index("enum RichUIHeightCache")]
(out / "Parser.swift").write_text("import Foundation\n" + source + "\nstruct TerminalFileAttachment { init(result: String?, arguments: String?) {} }\nstruct ChatMessageFile { var type: String; var url: String; var name: String?; var contentType: String? }\n")

view = (args.root / "Open UI/Features/Chat/Views/ChatDetailView.swift").read_text()
start = view.index("                    let contentsToParse: [String] = windowMessages.compactMap")
end = view.index("                    await MessageParseCache.shared.warmBatch", start)
selection = view[start:end]
start = view.index("    static func resolveRelativeURLs(")
end = view.index("\n    }\n", start) + len("\n    }\n")
resolver = view[start:end]
(out / "Selection.swift").write_text("import Foundation\nenum SyntheticRole { case user, assistant }\nstruct SyntheticMessage { var role: SyntheticRole; var content: String }\nenum IsolatedAssistantMessage {\n" + resolver + "\n}\nfunc warmInputs(_ windowMessages: [SyntheticMessage]) -> [String] {\n let serverBase = \"https://example.test\"\n" + selection + "\nreturn contentsToParse\n}\n")

names = ["DetailsBlockScanner.swift", "DetailsBlockScanner+Bytes.swift", "DetailsBlockScanner+Scan.swift", "DetailsBlockScanner+Code.swift"]
for name in names:
    (out / name).write_text((args.root / "Open UI/Core/Services" / name).read_text())
(out / "Checks.swift").write_text((Path(__file__).parent / "ParseCacheChecks.swift").read_text())
subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules")]
               + [str(out / name) for name in names + ["Parser.swift", "Selection.swift", "Checks.swift"]]
               + ["-o", str(out / "checks")], check=True)
raise SystemExit(subprocess.run([str(out / "checks")]).returncode)
