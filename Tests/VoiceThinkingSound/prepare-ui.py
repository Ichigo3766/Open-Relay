#!/usr/bin/env python3
"""Copy only public production sources and synthetic fixtures to a scratch project."""
import argparse
from pathlib import Path
import shutil

here = Path(__file__).resolve().parent
root = here.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--output-dir", type=Path, required=True)
out = parser.parse_args().output_dir.resolve()
if out.exists():
    raise SystemExit("Choose a new scratch directory; existing files will not be replaced.")
shutil.copytree(here / "NativeUI", out)
voice = root / "Open UI/Features/VoiceCall"
for source in ["Engine/Audio/CallThinkingSound.swift", "Engine/VoiceCallSettings.swift",
               "Engine/VoiceCallSettings+Advanced.swift", "Engine/VAD/TurnDetector.swift",
               "Engine/VAD/EndOfTurnPolicy.swift", "Views/VoiceCallSettingsView.swift"]:
    shutil.copy2(voice / source, out / "Host" / Path(source).name)
print("Prepared isolated native UI project.")
