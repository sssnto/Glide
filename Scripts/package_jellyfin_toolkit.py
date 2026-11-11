#!/usr/bin/env python3
"""Package the independently versioned Glide Toolkit submodule."""
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
script = repo / 'Server/scripts/package.py'
if not script.is_file():
    raise SystemExit('Initialize the plugin first: git submodule update --init Server')
subprocess.run([sys.executable, str(script)], check=True)
