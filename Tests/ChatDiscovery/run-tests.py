"""Compile actual request and model-discovery methods with invented transports."""
from pathlib import Path
import argparse, subprocess, sys
repo = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument("output", type=Path)
p.add_argument("--source-root", type=Path, default=repo)
a = p.parse_args(); out = a.output.resolve()
if out == repo or repo in out.parents:
    raise SystemExit("Use an output directory outside the checkout.")
for runner, source, target in [
    ("network-runner.py", "Open UI/Core/Networking/NetworkManager.swift", "network"),
    ("model-runner.py", "Open UI/Features/Chat/ViewModels/ChatViewModel.swift", "models")]:
    subprocess.run([sys.executable, str(Path(__file__).with_name(runner)),
                    str(a.source_root / source), str(out / target)], check=True)
