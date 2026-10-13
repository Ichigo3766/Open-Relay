"""Compile the production completion predicate; use only freshly invented JSON."""
from pathlib import Path
import argparse
import subprocess

root = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument("output", type=Path)
p.add_argument("--source", type=Path, default=root / "Open UI/Core/Services/ConversationCache.swift")
p.add_argument("--benchmark", type=Path, help="Generated synthetic fixture")
a = p.parse_args()
out = a.output.resolve()
if out == root or root in out.parents:
    raise SystemExit("Generated files must be outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
s = a.source.read_text()
start = s.index("    nonisolated private static func hasUnfinishedMessages(")
end = s.index("\n    }", start) + 6
helper = s[start:end].replace("nonisolated private static", "static")
(out / "Subject.swift").write_text("import Foundation\nstruct Subject {\n" + helper + "\n}\n")
subprocess.run(["swiftc", "-O", "-whole-module-optimization", "-parse-as-library", "-module-cache-path", str(out / "modules"),
                str(out / "Subject.swift"), str(Path(__file__).with_name("CompletionBenchmark.swift" if a.benchmark else "CompletionChecks.swift")),
                "-o", str(out / "checks")], check=True)
subprocess.run([str(out / "checks"), *([str(a.benchmark.resolve())] if a.benchmark else [])], check=True)
