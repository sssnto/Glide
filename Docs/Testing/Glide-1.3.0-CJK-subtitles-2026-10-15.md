# 1.3.0 (2) 本地中文字幕方框修复

用户报告本地视频字幕显示为空心方框。此前 1.3.0 的 ASS 验证使用英文 Arial 文本，未覆盖 CJK 缺字问题。

## 复现与原因

原创 `12-cjk-ass.mkv` 在原字体配置下，英文 `Glide CJK ASS` 正常，中文“中文字幕正常显示”显示为八个方框。选中字幕并暂停定位后截图及 OCR 均确认这一点。

- 复现结果：`/tmp/GlideCJK/Before-Selected.xcresult`。
- [修复前画面](Glide-1.3.0-CJK-before.png)。
- 首轮 `/tmp/GlideCJK/Before.xcresult` 没有稳定开启字幕，不用于证明缺字。

固定 SDK 的 `modules/codec/libass.c` 在 Apple 平台把默认字体家族设为 `Helvetica Neue`，没有提供默认字体文件。libass 0.17.3 的 CoreText 提供者会查找系统后备字体，但新版 Apple 系统存在第三方字体库无法读取中文字体的问题。这与此次样例的缺字现象一致，尚未取得用户原片核对其具体字幕编码和字体。

上游资料：[libass #845](https://github.com/libass/libass/issues/845)、[Apple 字体讨论](https://developer.apple.com/forums/thread/758189)、[libass 字体选择实现](https://github.com/libass/libass/blob/0.17.3/libass/ass_fontselect.c)。

## 修复

随包加入 Noto Sans CJK SC Regular 2.004 派生的 `Glide Subtitle Fallback`，覆盖 44,810 个 Unicode 映射、65,535 个字形。完整 OTF 约 15.6 MiB，不依赖网络下载。该字体包含简繁中文及其他 CJK 字形；不宣称支持所有 Unicode 字符。

- 使用公开 CoreText API 在进程内注册字体，供普通文本字幕的 FreeType 渲染使用。
- `--freetype-font` 指向独立的 `Glide Subtitle Fallback` 排印家族。
- `--ssa-fontsdir` 指向随包字体目录，libass 直接读取字形。
- 字体的旧式家族字段提供 `Helvetica Neue` 兼容别名，以匹配 libVLC 3 硬编码的默认家族；排印家族、PostScript 名称、CFF 名称使用 Glide 自有名称。libass 在原字体缺字时可使用默认字体，不需覆盖 ASS 字体标签、位置或颜色。
- 保留原始字形与许可证信息；设置的“开源组件”加入 OFL 全文。
- 主工程和独立实验工程都打包同一字体目录。MobileVLCKit 二进制未修改。

来源、校验和与构建工具版本见 `Dependencies/SubtitleFont.json`。`Scripts/prepare_subtitle_font.py` 检验原字体 SHA-256 后生成资源；重复构建输出 SHA-256 一致。

## 验证范围

使用原创素材，不包含用户视频。`Scripts/generate_cjk_subtitle_fixtures.py` 在原有 11 个样例之外添加：

| 文件 | 场景 | 预期字幕 |
|---|---|---|
| 12-cjk-ass.mkv | ASS，Arial 缺少 CJK 字形 | 中文字幕正常显示 |
| 13-cjk-ass.mkv | ASS，虚构的缺失字体 | 繁體字幕正常顯示 |
| 14-cjk-srt.mkv | UTF-8 SRT 内嵌字幕 | 中文字幕正常显示 |

UI 测试从主应用本地目录打开视频，明确选中内嵌字幕、暂停定位，在实际渲染截图中通过 Vision 识别完整中文。仅检查轨道存在或选中状态不能证明字形渲染正确。

## 实际结果

iPhone 17 Pro 专用模拟器，iOS 27.0（24A434），主应用 Debug、ad-hoc 签名。

| 用例 | 结果 | 原始结果包 |
|---|---|---|
| 简体中文 ASS，Arial 字体 | 通过；完整识别“中文字幕正常显示” | `/tmp/GlideCJK/After-ASS.xcresult` |
| 繁体中文 ASS，虚构缺失字体 | 通过；完整识别“繁體字幕正常顯示” | `/tmp/GlideCJK/After-Traditional-SRT.xcresult` 中的 `testCompatibilityMissingFontTraditionalASS` |
| UTF-8 中文 SRT | 通过；完整识别“中文字幕正常显示” | `/tmp/GlideCJK/After-SRT-Retry.xcresult` |
| 英文 ASS、关闭字幕、选择音轨 | 通过；字幕开启时 OCR 命中，关闭后 OCR 不命中；音轨选中状态更新 | `/tmp/GlideCJK/After-English-Final.xcresult` |

画面：[简体 ASS](Glide-1.3.0-CJK-after.png)、[繁体 ASS](Glide-1.3.0-CJK-traditional.png)、[中文 SRT](Glide-1.3.0-CJK-srt.png)。三张截图均人工核对文字。

SRT 首轮在滚动到字幕选项前失败，未执行 OCR；同一轮繁体 ASS 已通过。该次工具调用 300 秒超时后，等待底层测试结束并读取 xcresult，未将整个结果包写成通过。UI 测试随后改为先展开中等高度的设置面板，再滚动 Form；SRT 重试通过。

英文回归首轮点按了在底部被裁切的音轨行，选中检查未通过；录像显示该行没有完整进入视口。测试增加完整可见检查，首次视口边界设得比最终行底部严格 6 pt，第二轮在点按前被测试断言阻止；调整底部安全边界后最终整项通过。未为这些测试定位问题修改播放器逻辑。

本次四项通过结果及此前失败尝试统一保存在 [结构化验证记录](Glide-1.3.0-CJK-results.json)，不把失败尝试从记录中删除。

Release 1.3.0（2）归档成功：`/tmp/GlideCJK/Glide-1.3.0-2.xcarchive`。归档字体和 OFL SHA-256 与锁定清单一致，MobileVLCKit 可执行文件与此前验收归档完全一致。应用文件总计 57,699,655 字节，新增字体文件 16,437,648 字节（约 15.7 MiB）；此处不是 App Store 下载大小。

独立 QA 版本 1.3.0（2）已签名构建、安装到已连接 iPhone 13 Pro Max，并成功正常启动；QA 与 Release 包含相同字体。此次未通过真机截图验证用户原片，需由用户在该 QA 版本重新播放原文件确认。历史长播和 90 项 Core 测试未重复运行，不将其计为此次构建的新结果。
