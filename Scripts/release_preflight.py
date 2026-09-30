#!/usr/bin/env python3
"""Fail fast before a public Glide release; never reads credentials."""
from pathlib import Path
import plistlib
import re
import sys

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / "Glide/Info.plist").read_bytes())
project = (root / "Glide.xcodeproj/project.pbxproj").read_text()
site = root / "Website"
problems = []

def resolved(key: str, setting: str) -> str:
    value = str(info.get(key, ""))
    if value != f"$({setting})":
        return value
    values = set(re.findall(rf"\b{setting} = ([^;]+);", project))
    if len(values) != 1:
        problems.append(f"{setting} 的构建配置不一致")
        return value
    return values.pop()

version = resolved("CFBundleShortVersionString", "MARKETING_VERSION")
build = resolved("CFBundleVersion", "CURRENT_PROJECT_VERSION")

if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    problems.append("版本号必须为 x.y.z")
if not build.isdigit():
    problems.append("构建号必须为整数")
if 'ProView.swift' in project or 'ProStore.swift' in project:
    problems.append("延期的收费代码仍在构建目标中")
if 'Glide Pro 与恢复购买' in (root / 'Glide/Views/SettingsView.swift').read_text():
    problems.append("设置中仍显示收费入口")
for name in ("index.html", "privacy.html", "support.html", "style.css", "CNAME"):
    if not (site / name).is_file():
        problems.append(f"缺少站点文件：{name}")
if (site / "CNAME").read_text().strip() != "glide.sssnto.cn":
    problems.append("自定义域名配置不一致")
for name in ("privacy.html", "support.html"):
    if "133317737@qq.com" not in (site / name).read_text():
        problems.append(f"{name} 缺少支持邮箱")

print(f"Glide {version} ({build}) 发布预检")
if problems:
    for problem in problems:
        print("待处理：" + problem)
    sys.exit(1)
print("本地静态检查通过；仍须人工核对隐私问卷、公开页面和真机回归。")
