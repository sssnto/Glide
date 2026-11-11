# Glide · 私人媒体，自在观看

Glide 是 iPhone 与 iPad 上的 SwiftUI 私人媒体播放器，连接本地视频、Jellyfin、Emby、SMB 和 WebDAV，提供系统与兼容播放、统一搜索、离线行程、精彩片段和方向整理。

当前开发版本：**2.0.0（1）「观看优先」候选**。App Store 公开查询于 2026-11-11 返回美区 **1.15.0**；2.0 正准备发布，具体可用性以商店为准。

[官网](https://glide.sssnto.cn/) · [支持](https://glide.sssnto.cn/support.html) · [隐私政策](https://glide.sssnto.cn/privacy.html) · [App Store](https://apps.apple.com/app/id6814679647)

## 2.0 的变化

- **观看**：继续观看优先，集中按时间选片、私人频道和媒体来源。
- **片库**：缩减重复标题和工具区，突出作品名、季集、片长与来源；辅助字号采用左图右文。
- **收藏**：收藏视频先出现，可切换观看历史，保留时刻与精彩片段集。
- **任务**：下载与 Jellyfin 旋转队列集中查看，按进行中、需处理和全部筛选。
- **原位整理**：在原视频网格直接勾选，保留当前方向预览；保存后更新缩略图与方向状态。
- 沿用系统蓝与自动明暗，保留音轨、字幕、倍速、双指缩放及系统／兼容播放路线。

[完整设计规范](Docs/Design/Glide-2.0/Design-Spec.md) · [候选说明](Docs/Design/Glide-2.0/Release-Notes.md) · [实际界面与验收](Docs/Testing/Glide-2.0/README.md) · [2.0 发布材料](Docs/Publishing/2.0.0/README.md)

## 主要能力

| 场景 | 能力 |
| --- | --- |
| 媒体来源 | 本地导入／授权目录、Jellyfin、Emby、SMB 2/3、WebDAV、HTTP(S) 与 STRM |
| 找片与编排 | 跨来源搜索、来源／版本选择、按时长选片、私人频道与剧集顺序 |
| 离线观看 | 下载队列、按时间和容量准备行程、出发前检查、离线播放与续播 |
| 片段回看 | 内容地图、章节、时刻、起止片段、跨视频合集与独立进度 |
| 播放控制 | 系统与 VLC 兼容内核、轨道切换、倍速、缩放、文字字幕定位与循环 |
| 字幕 | 外挂与双字幕、原样 ASS／SSA 字体颜色及特效、具备提取条件的 Jellyfin PGS |
| 方向整理 | 播放器内预览；可写 WebDAV 保存／还原；Jellyfin 插件服务器处理、原位多选与串行队列 |

方向保存覆盖符合条件的 MP4／MOV／M4V。WebDAV 需要下载、设备处理及回传；Jellyfin 配套插件在用户自己的服务器处理。插件当前 **Glide Toolkit 1.1.1** 面向 Jellyfin 12.2 的 Linux／NAS Docker 环境，需要匹配版本、用户授权和可写媒体目录。SMB 与 Emby 暂不提供相同原文件方向保存。

[方向整理说明](Docs/Glide-1.16.0-Video-Rotation.md) · [Jellyfin 服务器处理](Docs/Glide-1.16.0-Jellyfin-Server-Rotation.md) · [批量队列](Docs/Glide-1.16.0-Batch-Rotation.md) · [插件安装与打包](https://github.com/sssnto/GlideToolkit)

## 开发与验证

- iOS 17 或更高版本；本轮使用 Xcode 27.1，iPhone 17／iOS 26.3.1 模拟器验收。
- 首次运行 `python3 Scripts/prepare_compatibility_sdk.py` 准备固定 MobileVLCKit SDK，然后打开现有 `Glide.xcodeproj`，选择 `Glide` scheme。无需 `pod install`；真机运行时选择自己的开发团队。独立验证可用 `GlideCompatibilityQA` scheme。
- 准备脚本保留并校验 MobileVLCKit 的 dSYM UUID、规范公开头文件引用；生成的 SDK、构建缓存、签名和归档不上传到仓库。分发时可运行 `python3 Scripts/release_preflight.py --archive "/绝对路径/Glide.xcarchive"` 检查实际归档。
- `swift test -j 1` 运行核心规则回归；`python3 Scripts/release_preflight.py` 执行静态发布预检。
- 2.0 已通过 287 项核心回归、5 条界面主流程及最后 2 条针对性复核；真实来源、主应用升级、实体机和分发归档仍需按实际结果验收。

2.0 不改变现有来源、收藏、进度、离线和服务器备份格式。用户已完成 1.16 阶段真机方向保存及原网格勾选测试；2.0 的主要新增验收是信息架构与界面路径，不能替代完整的真实媒体矩阵。

## 网站与发布

`Website/` 是可审阅的官网源文件。实际 GitHub Pages 部署使用既有仓库 `sssnto/glide-privacy` 的 `main` 根目录及域名 `glide.sssnto.cn`。

- `python3 Scripts/check_website.py`：文档语义、本地资源、锚点与域名检查。
- `python3 Scripts/sync_website.py --checkout <Pages检出目录>`：同步经过检查的网站，不自动提交或推送。
- `python3 Scripts/verify_website_deployment.py --output <结果文件>`：比对公开 URL 字节与源文件。

官网的“即将发布”与“商店已发布”分开标示，应用实际上架后再更新公开版本状态。发布字段、审核路径与更新公告见 [2.0 发布材料](Docs/Publishing/2.0.0/README.md)。

Glide 不提供影视片源或在线字幕搜索。请仅连接并处理有权访问的内容。

## 独立 Jellyfin 插件

插件源码、版本和安装包在 [sssnto/GlideToolkit](https://github.com/sssnto/GlideToolkit) 独立维护。Jellyfin 管理员可在“插件 → 存储库”添加：

```text
https://raw.githubusercontent.com/sssnto/GlideToolkit/main/manifest.json
```

随后在插件目录安装 Glide Video Toolkit 并重启 Jellyfin。已有手动安装的 1.1.0 首次迁移请主动选择 1.1.1.0 安装，保留配置、任务记录及备份；之后可使用 Jellyfin 的插件更新机制。详见独立仓库安装指南。

客户端通过 `Server` 子模块固定配套源码。需要构建插件或运行服务端回归时，先执行 `git submodule update --init Server`；仅构建 iOS 应用不依赖此子模块。
