#!/usr/bin/env python3
"""Run failed-send regression checks with synthetic services, without an iOS runtime."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECKOUT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ("tmp", "module-cache"):
        (output / name).mkdir(exist_ok=True)
    env = dict(os.environ, TMPDIR=str(output / "tmp"), CLANG_MODULE_CACHE_PATH=str(output / "module-cache"))

    def run(command, expected=0):
        result = subprocess.run(command, env=env, capture_output=True, text=True, check=False)
        print(result.stdout, end="")
        if result.returncode != expected:
            print(result.stderr, file=sys.stderr, end="")
            raise RuntimeError(f"Unexpected exit code {result.returncode}; expected {expected}")
        return {"exit_code": result.returncode, "stdout": result.stdout}

    def build(name, working_tree=False):
        destination = output / name
        command = [sys.executable, str(HERE / "generate.py"), str(CHECKOUT), str(destination)]
        if working_tree:
            command.append("--working-tree")
        run(command)
        run(["swiftc", "-module-cache-path", str(output / "module-cache"), "-o", str(destination / "checks"),
             *[str(path) for path in sorted(destination.glob("*.swift"))]])
        return str(destination / "checks")

    baseline = build("baseline")
    results = {"baseline_reproduction": run([baseline])}
    print("Expected baseline safety-contract failure:")
    results["baseline_expected_failure"] = run([baseline, "--fixed"], expected=1)
    candidate = build("current", working_tree=True)
    results["current_safety_contract"] = run([candidate, "--fixed"])
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
