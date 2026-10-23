#!/usr/bin/env python3
"""Copy the checked Website into a clean checkout of the existing Pages repo.

Does not commit, push, alter Pages settings, or remove unrelated files.
"""
import argparse
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--checkout", required=True, type=Path)
args = parser.parse_args()
target = args.checkout.resolve()


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(target), *arguments], text=True).strip()


if Path(git("rev-parse", "--show-toplevel")).resolve() != target:
    raise SystemExit("Use the root of a separate Pages checkout")
remote = git("remote", "get-url", "origin")
if remote not in ("https://github.com/sssnto/glide-privacy.git", "git@github.com:sssnto/glide-privacy.git"):
    raise SystemExit("Refusing an unexpected publishing repository")
if git("status", "--porcelain"):
    raise SystemExit("Publishing checkout has local changes; review them first")
if (target / "CNAME").read_text().strip() != "glide.sssnto.cn":
    raise SystemExit("Existing custom domain differs; refusing to replace it")
subprocess.run(["python3", str(root / "Scripts/check_website.py")], check=True)
files = sorted(p for p in (root / "Website").rglob("*") if p.is_file())
for source in files:
    if source.is_symlink():
        raise SystemExit("Symlinks are not public site assets")
    destination = target / source.relative_to(root / "Website")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
print(f"Copied {len(files)} public files to {target}; review git diff, then commit and push explicitly.")
