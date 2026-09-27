"""Generate fresh, non-personal media; requires ffmpeg on PATH."""
import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
folder = parser.parse_args().directory
folder.mkdir(parents=True, exist_ok=True)


def ffmpeg(*arguments):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", *arguments], check=True)


ffmpeg("-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "60",
       "-c:v", "libx264", "-preset", "veryfast", "-b:v", "7000k", "-minrate", "7000k",
       "-maxrate", "7000k", "-bufsize", "14000k", "-x264-params", "nal-hrd=cbr:force-cfr=1",
       "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
       str(folder / "motion.mp4"))
ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "10",
       "-c:a", "aac", str(folder / "tone.m4a"))
ffmpeg("-f", "lavfi", "-i", "color=c=blue:s=320x180", "-frames:v", "1", str(folder / "sample.png"))
(folder / "notes.txt").write_text("A freshly invented sample document.\n")
