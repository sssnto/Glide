# Glide 1.11.0 发布材料

准备日期：2026-10-23（Asia/Shanghai）。代码基线 `c35bee1`，应用版本 **1.11.0（4）**。Apple 公开查询当前商店版本为 **1.4.0**，因此更新说明覆盖 1.5—1.11 累积改动，而非仅内容地图和 ASS 修复。

材料面向简体中文 App Store，另附英文审核备注、TestFlight 测试内容、上架公告及截图文案。TXT 只含字段正文，可直接复制；名称与副标题是建议，不改变应用内显示名或后台现有名称。

## 可填写字段

| App Store Connect 字段 | 文件与建议值 | 实际长度／限制 |
| --- | --- | --- |
| 名称 | [Glide 视频播放器](zh-Hans/name.txt) | 11／30 字符 |
| 副标题 | [本地与 NAS 片库，按时间选片](zh-Hans/subtitle.txt) | 16／30 字符 |
| 推广文本 | [promotional-text.txt](zh-Hans/promotional-text.txt) | 98／170 字符 |
| 此版本的新增内容 | [release-notes.txt](zh-Hans/release-notes.txt) | 598／4000 字符 |
| 描述 | [description.txt](zh-Hans/description.txt) | 1216／4000 字符 |
| 关键词 | [keywords.txt](zh-Hans/keywords.txt) | 99／100 UTF-8 字节 |
| 审核备注 | [review-notes-en.txt](review-notes-en.txt) | 见 [verification.json](verification.json)，按 4000 UTF-8 字节校验 |
| 版本 | 1.11.0 | 与项目一致 |
| 构建 | 4 | 本地已验收构建；后台可选构建以实际上传处理结果为准 |
| 支持 URL | https://glide.sssnto.cn/support.html | 本次核对可访问 |
| 隐私政策 URL | https://glide.sssnto.cn/privacy.html | 本次核对可访问 |
| 营销 URL | https://glide.sssnto.cn/ | 本次核对可访问 |

字段限制已按 [Apple 平台版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)与[应用信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)核对。关键词使用协议、格式和功能词，不加入竞品名，不承诺已取得搜索量或排名验证。保持品牌名 Glide 也可；无需为使用其余文案而必须改名。

## 文案定位

先讲“更少挑选、更多观看”：按时间选片、私人频道、内容地图与时刻收藏；再说明 Emby／SMB、链接、字幕与原生播放改进。没有将整次更新写成字幕补丁，也没有把历史版本的全深色外观当作当前卖点。

介绍以已实现能力为准。内容地图明确来源条件；字幕明确原字体需要实际提供；PGS 指向 Jellyfin 与服务端提取；不承诺全格式、全 HDR、全来源地图或无缝循环。当前不包含 Plex、飞牛、云盘、IPTV、在线字幕搜索、自然语言画面搜索或跨设备频道／时刻同步。

## 审核与对外使用

- [英文审核备注](review-notes-en.txt)说明无需 Glide 账号的原创离线演示、内容地图、时刻、频道和文件导入入口，引用真实界面名称；不是 DEBUG 启动参数或本机验证服务器地址。
- 远程来源需要可访问的媒体服务器。若审核需要完整体验这些功能，应在后台单独提供专用审核服务器及账号；本包未包含凭据，不编造可用账号，不使用仅当前 Mac 可访问的测试地址。审核联系人沿用后台真实资料。
- [TestFlight 测试内容](zh-Hans/testflight-what-to-test.txt)覆盖从 1.4.0 升级后的连接、片库、选片、频道、地图、字幕与播放，不等同于重新执行了全部设备／来源矩阵。
- [正式上架公告](zh-Hans/announcement.txt)在 1.11.0 实际上架后使用。推广文本也应与新版上架同步使用，避免在旧版产品页提前宣称新能力已经可下载。
- [六张截图文案与选图方案](screenshot-brief.md)是拍摄方案，尚未制作正式商店截图，不将开发验收图描述为最终商店素材。

结构化字段见 [metadata-zh-Hans.json](metadata-zh-Hans.json)，实际长度、来源核对、公开 URL 与材料指纹见 [verification.json](verification.json)。

## 当前状态

已有构建 4 的核心、实际片源、原样 ASS、界面回归及 Release 归档／签名／dSYM 证据，见[最终验收](../../Testing/Glide-1.11.0-ASSFont-2026-10-23/README.md)。本次只编写材料，未修改播放器、重新归档、填写后台、上传构建或提交审核。

官网已更新并将商店 1.4.0 与开发版 1.11.0 分开说明。等 1.11.0 实际公开上架后，再同步其商店版本与开发预览标签；这次未提前修改线上发布状态。
