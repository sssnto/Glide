# Glide 1.4.0 发布材料

准备日期：2026-10-16（北京时间）。代码基线：7c0a1f3。面向简体中文商店，附英文审核备注。

Apple 公开查询接口当前返回上架版本 1.1.0，因此这份更新说明覆盖 1.2–1.4 的累计改动，包含本地导入、兼容播放、字幕和新界面。材料状态为待使用；具体构建与商店发布状态以 App Store Connect 为准。

## 填写到 App Store Connect

各 TXT 只包含字段正文，可整段复制。名称是本次商店定位建议，包内显示名继续为 Glide；本材料没有修改应用代码或后台名称。

| 字段 | 建议内容或文件 | 长度校验 |
| --- | --- | --- |
| 名称 | [Glide 视频播放器](zh-Hans/name.txt) | 11 / 30 字符 |
| 副标题 | [本地与 Jellyfin 片库，滑动连播](zh-Hans/subtitle.txt) | 20 / 30 字符 |
| 推广文本 | [promotional-text.txt](zh-Hans/promotional-text.txt) | 93 / 170 字符 |
| 此版本的新增内容 | [release-notes.txt](zh-Hans/release-notes.txt) | 329 / 4000 字符 |
| 描述 | [description.txt](zh-Hans/description.txt) | 792 / 4000 字符 |
| 关键词 | [keywords.txt](zh-Hans/keywords.txt) | 99 UTF-8 字节；按 100 字节保守校验 |
| 支持 URL | https://glide.sssnto.cn/support.html | 实测 HTTP 200 |
| 隐私政策 URL | https://glide.sssnto.cn/privacy.html | 实测 HTTP 200；内容需同步下文新版 |
| 营销 URL | https://glide.sssnto.cn/ | 沿用现有站点 |
| 版本号 | 1.4.0 | 与项目一致 |

关键词按现有能力筛选，不使用竞品名或尚未实现的 SMB、FTP、网盘、IPTV 等能力。它们是搜索词候选，没有取得搜索量或排名数据。推广文本用于表达下载价值；Apple 明确说明它不影响搜索排名。[字段规范](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)、[名称及副标题规范](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)、[Apple 产品页建议](https://developer.apple.com/app-store/product-page/)。

## 推广文本

本地视频、Jellyfin 片库，一个播放器。上下滑动接着看，顺序连播或随机重温；竖版封面更好找，倍速、音轨、字幕一触可达。Jellyfin 影片可下载后离线观看，让自己的片库随时开播。

## 此版本的新增内容

这次更新，让本地视频和私人片库都更顺手。

• 全新深色界面：优化字号与信息层级，同屏浏览更多媒体。
• 竖版封面浏览：媒体库、目录与家庭视频统一采用竖版预览；进入后默认展示媒体，顶部可切换目录。
• 本地视频来源：支持导入视频文件和添加本地目录，浏览、搜索、收藏自己的视频，顺序或随机连播。
• 本地兼容播放：可切换播放器，并保留观看位置与暂停状态。
• 中文字幕修复：改善部分本地视频字幕显示为方框的问题。
• 播放操作更直接：倍速、音轨和字幕集中在底部，影片信息与视频规格展示更清楚。
• Jellyfin 播放改进：优化原画兼容传输，修复部分视频未显示兼容重试入口的问题。
• 浏览体验优化：改善封面加载、列表稳定性、iPad 布局和系统大字号体验。

## 审核、测试与对外介绍

- [英文审核备注](review-notes-en.txt)：包含无需账号的离线演示步骤、本地导入位置及播放器边界，可粘贴到审核备注字段。
- [TestFlight 测试内容](zh-Hans/testflight-what-to-test.txt)：供测试员核对目录、字幕、兼容切换和 Jellyfin 播放。
- [对外介绍短文](zh-Hans/announcement.txt)：正式上架后用于社区或更新公告。
- [截图标题与选图方案](screenshot-brief.md)：六张图的主标题、副文案与拍摄画面。
- [布局参考](reference/preview.png)：实际模拟器截图，供选图和制图使用，含验证用名称。
- [结构化中文字段](metadata-zh-Hans.json)与[核对记录](verification.json)。

审核联系人沿用 App Store Connect 现有资料。若审核需要体验远程 Jellyfin 功能，应在后台提供可访问的演示服务器及专用审核账号；本包不包含账号密码，也不能把本机 127.0.0.1 验证服务填给审核人员。

## 配套站点文件

[site/privacy.html](site/privacy.html) 包含本地导入、目录授权与设备存储说明；[site/support.html](site/support.html) 已补充本地兼容播放、Jellyfin 缓冲与中文字幕的帮助。其余站点文件保留现有版本，便于一起同步。具体变化见 [站点更新说明](site-update-notes.md)。

核对时线上支持页和隐私页可访问，但尚未出现本地视频和目录授权说明。site 目录是可部署的本地更新稿，需要同步到现有网站；准备材料不代表已完成网站部署。

## 正式发布时仍需落实

| 项目 | 当前事实与发布时的操作 |
| --- | --- |
| 正式归档 | 项目为 1.4.0（1），本地静态发布预检通过。正式构建使用 Glide / Release / com.songpeng.glide；已安装的“Glide 兼容验证”属于独立 QA 包。归档后需对实际 archive 执行 release_preflight.py --archive，核对应用与 MobileVLCKit dSYM。 |
| 最终真机验收 | 现有核心逻辑和针对性 UI 测试通过；最终 QA 包已安装，最后的自动启动被锁屏拒绝。正式 Release 包仍需实际打开，复核本地导入、字幕、兼容切换及用户 Jellyfin 原片。 |
| 商店截图 | 本包提供文案和布局参考；现有图含 Fixture 名称，来源页需补拍。iPad 参考图为 11 英寸尺寸，需准备正式 13 英寸截图组。尺寸见截图方案。 |
| 公开支持与隐私 | 将本包 site 更新稿同步上线，并在后台核对实际隐私说明与 App Privacy 信息。 |

当前未在 App Store Connect 创建或填写版本、上传构建、提交审核或发布。本包的用途是提供可直接复用的文字及配套素材说明。
