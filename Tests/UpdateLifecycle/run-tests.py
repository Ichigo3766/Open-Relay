"""Exercise the production automatic-update task bodies with synthetic checkers."""
from pathlib import Path
import argparse
import os
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument("output", type=Path)
p.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
a = p.parse_args()
repo, out = a.source_root.resolve(), a.output.resolve()
if out == repo or repo in out.parents:
    raise SystemExit("Build output must be outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
source = (repo / "Open UI/App/Open_UIApp.swift").read_text()


def block(start):
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[brace + 1:end - 1]


marker = source.index("// Check for app updates (App Store)")
root_start = source.rfind(".task", 0, marker)
root = block(root_start)
marker = source.find("// Re-check for app + server updates")
foreground = block(source.index("Task {", marker)) if marker >= 0 else ""
# Shorten only the existing presentation delay. All task bodies and checks are production code.
root, foreground = [s.replace("1_200_000_000", "50_000_000") for s in (root, foreground)]
root = re.sub(r"(?<![\w.])(dependencies|scenePhase)\b", r"self.\1", root)
foreground = re.sub(r"(?<![\w.])dependencies\b", "self.dependencies", foreground)
template = Path(__file__).with_name("checks.swift").read_text()
template = template.replace("// ROOT_WORK", root).replace("// FOREGROUND_WORK", foreground)
template = template.replace("// PHASE_TASK", "true" if ".task(id: scenePhase)" in source[root_start:root_start + 80] else "false")
(out / "checks.swift").write_text(template)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / "module-cache"), TMPDIR=str(out))
subprocess.run(["swiftc", "-parse-as-library", "-O", "-module-cache-path", str(out / "module-cache"),
                str(out / "checks.swift"), "-o", str(out / "checks")], check=True, env=env)
subprocess.run([str(out / "checks")], check=True, env=env)
