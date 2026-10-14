"""Run actual completion-error, orphan-resolution, and draft-consumption code."""
from pathlib import Path
import argparse, subprocess, sys
repo = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument("output", type=Path)
p.add_argument("--source-root", type=Path, default=repo)
a = p.parse_args(); out = a.output.resolve()
if out == repo or repo in out.parents:
    raise SystemExit("Use an output directory outside the checkout.")
r = Path(__file__).parent; source = a.source_root
vm = source / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift"
subprocess.run([sys.executable, str(r / "ack-runner.py"), str(vm),
    str(source / "Open UI/Features/Chat/ViewModels/ChatViewModel+CatchUp.swift"),
    str(source / "Open UI/Core/Networking/APIError.swift"), str(out / "recovery")], check=True)
subprocess.run([sys.executable, str(r / "draft-runner.py"), str(vm), str(out / "drafts")], check=True)
subprocess.run([sys.executable, str(r / "recovery-runner.py"), str(source), str(out / "recovery-store")], check=True)

subprocess.run([sys.executable, str(r / "race-runner.py"), str(source), str(out / "send-races")], check=True)
