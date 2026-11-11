# Glide 2.0.0 发布材料

准备日期：2026-11-11。工程版本 **2.0.0（1）**，正式应用 Bundle ID 为 `com.songpeng.glide`。Apple 美区公开查询为 **1.15.0**，所以默认说明覆盖 1.16 阶段的方向／NAS 改进和 2.0 新工作台；中国区查询无记录，不据此推断下架。见 [公开状态](checks/public-state.json)。

## 可直接复制的字段

| 字段 | 文件 | 实际长度 |
| --- | --- | --- |
| 名称 | [正文](zh-Hans/name.txt) | 11 / 30 字符 |
| 副标题 | [正文](zh-Hans/subtitle.txt) | 12 / 30 字符 |
| 推广文本 | [正文](zh-Hans/promotional-text.txt) | 80 / 170 字符 |
| 此版本的新增内容 | [正文](zh-Hans/release-notes.txt) | 448 / 4000 字符 |
| 商店描述 | [正文](zh-Hans/description.txt) | 1189 / 4000 字符 |
| 关键词 | [正文](zh-Hans/keywords.txt) | 92 / 100 UTF-8 字节 |

也提供 [短版更新说明](zh-Hans/release-notes-short.txt)、[英文审核备注](review-notes-en.txt)、[TestFlight 测试内容](zh-Hans/testflight-what-to-test.txt)、[截图方案](screenshot-brief.md)及[结构化字段](metadata-zh-Hans.json)。

[即将发布公告](zh-Hans/preview-announcement.txt)现在可用；[正式上架公告](zh-Hans/announcement.txt)仅在 2.0 实际公开上架后使用。[GitHub Release 正文](zh-Hans/github-release-notes.txt)已准备，未替你创建正式发行记录或标签。

支持 URL：https://glide.sssnto.cn/support.html

隐私政策 URL：https://glide.sssnto.cn/privacy.html

营销 URL：https://glide.sssnto.cn/

字段上限按 Apple 的 [版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)与[应用信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)核对；长度与文件校验值见 [verification.json](verification.json)。关键词按实际能力编写，没有搜索量或排名保证。

## 提交范围

当前版本已完成候选编译、287 项核心回归、5 条界面主流程及最后 2 条针对性复核，见 [验收记录](../../Testing/Glide-2.0/README.md)。主要为独立模拟器包证据；正式主应用的升级、真实来源、实体机与分发归档仍需按实际结果验收。本次准备材料和 GitHub／官网更新，不代替你上传、提交审核或发布 App。

请使用主应用 Release 构建 `com.songpeng.glide`，选择 App Store Connect 中实际已上传并处理完成的 2.0.0 构建；工程当前构建号为 1，不代表后台已经有可选构建。不要提交 `com.songpeng.glide.v2preview` 独立预览包。

官网现在将 2.0 标为“即将发布”，1.15.0 标为当前商店版。真实上架后再同步官网的已发布状态，避免旧版下载页提前宣称 2.0 可下载。

## 独立 Jellyfin 插件存储库

[GlideToolkit 独立仓库](https://github.com/sssnto/GlideToolkit)与 [1.1.1 安装包](https://github.com/sssnto/GlideToolkit/releases/tag/v1.1.1)已发布。在 Jellyfin 控制台的插件存储库中添加：

```text
https://raw.githubusercontent.com/sssnto/GlideToolkit/main/manifest.json
```

进入目录安装 Glide Video Toolkit 1.1.1.0 后重启 Jellyfin。现有手动安装 1.1.0 的用户首次需要主动选择新版安装；保留配置、任务和备份。目标仍为 Jellyfin 12.2 / Linux Docker，1.1.1 沿用 1.1.0 旋转逻辑。本轮未操作真实 NAS。

插件 80 项核心回归、公开 ZIP／清单校验及全新本地 Jellyfin 的存储库安装、重启加载已通过，记录见 [核心](checks/plugin-core.json)、[公开安装包](checks/plugin-public.json)和[目录安装](checks/plugin-catalog-install.json)。
