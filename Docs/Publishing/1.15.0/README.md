# Glide 1.15.0 发布材料

准备日期：2026-11-07（Asia/Shanghai）。面向简体中文商店，附英文审核备注。项目和今天的正式应用归档均为 **1.15.0（3）**，Bundle ID 为 `com.songpeng.glide`。

Apple 美区公开查询当前返回 **1.11.0**，因此默认更新说明覆盖 **1.12—1.15 的累计变化**。中国区查询无记录，不能据此推断下架；后台版本、构建处理和提交状态本次未读取。原始核对见 [公开状态](checks/public-state.json)。

## 直接填写到 App Store Connect

TXT 文件只包含字段正文。名称、副标题是建议，保持现有商店名称 Glide 也可。

| 字段 | 文件／建议值 | 长度／上限 |
| --- | --- | --- |
| 名称 | [Glide 视频播放器](zh-Hans/name.txt) | 11／30 字符 |
| 副标题 | [统一搜索片库，随身离线回看](zh-Hans/subtitle.txt) | 13／30 字符 |
| 推广文本 | [promotional-text.txt](zh-Hans/promotional-text.txt) | 92／170 字符 |
| 此版本的新增内容（默认） | [release-notes.txt](zh-Hans/release-notes.txt) | 606／4000 字符 |
| 描述 | [description.txt](zh-Hans/description.txt) | 1463／4000 字符 |
| 关键词 | [keywords.txt](zh-Hans/keywords.txt) | 90／100 UTF-8 字节 |
| 审核备注 | [review-notes-en.txt](review-notes-en.txt) | 3147／4000 UTF-8 字节 |
| 版本 | 1.15.0 | 与工程和归档一致 |
| 构建 | 3 | 在后台选择实际已上传并处理完成的正式构建 |
| 支持 URL | https://glide.sssnto.cn/support.html | HTTP 200 |
| 隐私政策 URL | https://glide.sssnto.cn/privacy.html | HTTP 200 |
| 营销 URL | https://glide.sssnto.cn/ | HTTP 200 |

字段上限按 [Apple 版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)和[应用信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)核对，长度已自动校验，见 [verification.json](verification.json)。关键词按真实能力选择，未获得搜索量或排名数据，不作排名承诺。另附 [仅包含 1.15 改动的短版](zh-Hans/release-notes-1.15-only.txt)，默认仍使用累计版。

## 推荐推广文本

把自己的片库随身带走。统一搜索本地视频、Jellyfin、Emby 与已下载内容，收藏精彩片段，准备离线行程包；推荐信息更清楚，双指缩放更顺畅，iPhone Duo 展开观看也更从容。

## 其余材料

- [TestFlight 测试内容](zh-Hans/testflight-what-to-test.txt)：覆盖从 1.11.0 升级、跨来源搜索、离线行程、片段、推荐、缩放与适配。
- [上架公告](zh-Hans/announcement.txt)：正文使用“已发布”，只在实际公开上架后使用。
- [六张截图文案与拍摄方案](screenshot-brief.md)：优先展示搜索、片段与离线；这是方案，没有将开发验收图包装为新完成的正式商店 PNG。
- [结构化商店字段](metadata-zh-Hans.json)：便于复制或后续导入。
- [发布核对记录](release-readiness.md)：区分归档检查、历史功能验收和后台发布状态。

## 提交时使用

1. App Store Connect 选择 1.15.0，填写默认累计更新说明、推广文本及需要更新的商店字段，选择后台可用的构建 3。
2. 审核备注提供无需账号的原创离线演示路径，以及统一搜索、片段和行程包的实际入口。审核联系人使用后台真实资料；远程功能若需要审核账号，应另外提供可访问的专用服务器，不能使用本机 localhost 验证服务或私人凭据。
3. 截图按后台对应设备组准备。实际公开上架后，再使用上架公告并同步官网版本；本次已确认官网仍标记 1.11.0。

本次完成材料与只读核对，没有修改应用功能、版本号、商店后台或线上网站，也没有上传、提交审核、推送代码或打标签。构建 3 的实际后台状态以 App Store Connect 为准。

下载 ZIP 包保留本目录的商店文字与本次检查文件；历史验收链接指向项目仓库的 `Docs/Testing`。
