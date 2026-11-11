"""Reproduce the original 5-minute video with two synthetic audio tracks for Duo QA."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1] / "Glide/Resources"
subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-stream_loop", "24",
    "-i", str(root / "demo0.mp4"), "-f", "lavfi", "-i", "sine=frequency=240:sample_rate=44100",
    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "300",
    "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "32k",
    "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=Original-Low",
    "-metadata:s:a:1", "language=zho", "-metadata:s:a:1", "title=Original-High",
    "-movflags", "+faststart", str(root / "duo-continuity.mp4"),
], check=True)
