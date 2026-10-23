#!/usr/bin/env python3
"""Compare the unversioned public Pages files with this checkout's Website."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
from urllib.error import URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1] / "Website"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path)
args = parser.parse_args()


def verify(path):
    name = path.relative_to(ROOT).as_posix()
    try:
        request = Request("https://glide.sssnto.cn/" + name,
                          headers={"User-Agent": "Glide-Website-Verification/1.0"})
        with urlopen(request, timeout=25) as response:
            data = response.read()
            return {"file": name, "status": response.status, "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "matchesSource": data == path.read_bytes()}
    except (URLError, TimeoutError, OSError) as error:
        return {"file": name, "matchesSource": False, "error": str(error)}


with ThreadPoolExecutor(max_workers=4) as executor:
    results = list(executor.map(verify, sorted(p for p in ROOT.rglob("*") if p.is_file())))
report = {"site": "https://glide.sssnto.cn/", "timestamp": datetime.now(timezone.utc).isoformat(),
          "passed": all(r["matchesSource"] for r in results), "files": results,
          "scope": "Unversioned public URLs, bytes and SHA-256; does not render or interact with the site"}
if args.output:
    args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"passed": report["passed"], "files": len(results),
                  "matched": sum(r["matchesSource"] for r in results),
                  "unmatched": [r for r in results if not r["matchesSource"]]}, indent=2))
sys.exit(0 if report["passed"] else 1)
