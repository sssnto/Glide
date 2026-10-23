#!/usr/bin/env python3
"""Check the buildless public site before synchronizing the Pages repository."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import json
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / "Website"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.ids = set()
        self.links = []
        self.errors = []
        self.h1 = 0
        self.title = False
        self.description = False
        self.viewport = False
        self.canonical = None
        self.main = False
        self.lang = False

    def handle_starttag(self, tag, attributes):
        a = dict(attributes)
        if "id" in a:
            if a["id"] in self.ids:
                self.errors.append("duplicate id: " + a["id"])
            self.ids.add(a["id"])
        self.h1 += tag == "h1"
        self.title |= tag == "title"
        self.main |= tag == "main"
        self.lang |= tag == "html" and a.get("lang") == "zh-CN"
        self.description |= tag == "meta" and a.get("name") == "description" and bool(a.get("content"))
        self.viewport |= tag == "meta" and a.get("name") == "viewport"
        if tag == "link" and a.get("rel") == "canonical":
            self.canonical = a.get("href")
        if tag == "img" and ("alt" not in a or "width" not in a or "height" not in a):
            self.errors.append("image needs alt and intrinsic dimensions")
        for key in ("href", "src"):
            if a.get(key):
                self.links.append(a[key])
        for key in ("aria-controls", "aria-labelledby"):
            for ident in a.get(key, "").split():
                self.links.append("#" + ident)


def check():
    pages = {}
    for path in sorted(ROOT.glob("*.html")):
        page = Page(path)
        page.feed(path.read_text(encoding="utf-8"))
        pages[path] = page
    errors = []
    local_links = 0
    for path, page in pages.items():
        failures = list(page.errors)
        if not all((page.h1 == 1, page.title, page.description, page.viewport, page.main, page.lang)):
            failures.append("missing document semantics or metadata")
        if path.name != "404.html":
            expected = "https://glide.sssnto.cn/" + ("" if path.name == "index.html" else path.name)
            if page.canonical != expected:
                failures.append("incorrect canonical URL")
        for href in page.links:
            url = urlsplit(href)
            if url.scheme or url.netloc:
                continue
            local_links += 1
            target = ROOT / unquote(url.path.lstrip("/")) if url.path.startswith("/") else path.parent / unquote(url.path)
            if not url.path:
                target = path
            if target.is_dir():
                target /= "index.html"
            target = target.resolve()
            if not target.is_relative_to(ROOT.resolve()) or not target.is_file():
                failures.append("missing local target: " + href)
                continue
            if url.fragment:
                ids = pages[target].ids if target in pages else {e.get("id") for e in ET.parse(target).iter()} if target.suffix == ".svg" else set()
                if unquote(url.fragment) not in ids:
                    failures.append("missing anchor: " + href)
        errors.extend(f"{path.name}: {message}" for message in failures)
    if (ROOT / "CNAME").read_text().strip() != "glide.sssnto.cn":
        errors.append("CNAME changed")
    sitemap = ET.parse(ROOT / "sitemap.xml")
    if len(list(sitemap.getroot())) != 4:
        errors.append("sitemap must cover the four public pages")
    if not (ROOT / ".nojekyll").is_file():
        errors.append("missing .nojekyll")
    report = {"passed": not errors, "pages": len(pages), "localReferences": local_links,
              "publicBytes": sum(p.stat().st_size for p in ROOT.rglob("*") if p.is_file()),
              "errors": errors, "scope": "Static integrity checks; does not replace browser visual or interaction QA"}
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(check())
