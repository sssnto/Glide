# Glide 1.2.0（1）本地来源开发验证

日期：2026-10-15。本次为开发验证，未上传 TestFlight／App Store。沿用并保留工作区此前的 1.1.0 缓冲恢复修订。

## 自动检查

| 检查 | 本次结果 | 范围 |
| --- | --- | --- |
| Swift Package 核心测试 | 86 / 86 通过 | 原有 80 项与新增 6 项：稳定本地身份、文件范围与递归、旧模型兼容、损坏恢复、旧数据迁移、未来 schema 保护 |
| iOS Simulator Debug 编译 | 通过 | SwiftUI、文件选择器、目录提供方与播放集成 |
| 通用 iOS Release 编译 | 通过，未签名 | Xcode 27，目标 iOS 17+；未包含模拟器调试夹具 |
| 发布静态预检 | 通过 | 识别 1.2.0（1），无收费入口 |
| 本地闭环界面测试 | 通过 | `testLocalImportMountedDirectoryAndRestart`，专用 iPhone 17 Pro／iOS 27 模拟器；修订后再次通过，确认定位到目标时间、删除副本及重启 |
| 现有播放与来源回归 | 3 / 3 通过 | 进度条、下一条预加载、来源地址校验；定位修订后收紧目标范围并再次通过进度条用例 |

累计 4 个界面用例通过；最终 `Timeline-R7.xcresult` 为两项定位相关复测，2 / 2 通过。首次安装流程另在清空本次专用 QA 应用数据后通过，未清理或覆盖其他模拟器。

核心测试中实际创建临时目录、普通文件及链接，覆盖系统 `/var`／`/private/var` 路径别名，不仅比较手写 URL。恢复测试实际损坏主文件和备份；迁移测试使用独立 UserDefaults suite，拒绝损坏记录。核心测试不覆盖 UIKit、系统授权和 AVPlayer。

界面夹具仅在 `DEBUG && targetEnvironment(simulator)` 下启用，通过 `--glide-local-fixture` 调用正式导入／挂载服务。素材来自应用内演示视频；导入重名视频、拒绝含非视频文件的整批选择、创建一层子目录。后续退出夹具启动参数，再验证收藏与授权路径跨进程恢复。夹具位于应用自己创建的目录，不能代替外部文件提供方授权验收。

开发验证发现并修正两项应用问题：本地队列范围比较未统一系统路径别名；录屏显示预览出现时会干扰拖动，未到达目标位置。后者改用不参与布局的悬浮预览，并独立跟踪拖动状态，测试改为核对目标时间范围。另修正测试准备：移除锁定视图偏好的启动参数、重跑时回到根目录、使用片库总数替代懒加载可见卡片数。

## 重现

核心测试：`swift test`。静态检查：`python3 Scripts/release_preflight.py`。

本地界面闭环：

```sh
xcodebuild -project Glide.xcodeproj -scheme Glide -configuration Debug \
  -destination 'platform=iOS Simulator,name=Glide 1.2 QA' \
  -parallel-testing-enabled NO \
  -only-testing:GlideUITests/GlideUITests/testLocalImportMountedDirectoryAndRestart test
```

首次验证使用独立的空白模拟器；重复运行前应只重建专用测试设备，避免覆盖日常使用的模拟器。此长流程会删除它导入的一个演示副本，且会保留另外两个副本与演示目录。

本机编译与 XCTest 结果位于 `/tmp/Glide120/`，不纳入版本库。核心日志为 `/tmp/Glide120-core.log`；首次安装完整流程为 `LocalSources-R5.xcresult`，播放与来源三项回归为 `Regression-R3.xcresult`，最终定位复测为 `Timeline-R7.xcresult`。Release 日志为 `/tmp/Glide120-release-build.log`，XcodeBuildMCP 的界面日志另保存在用户 Library/Developer/XcodeBuildMCP 下。

[本次通过用例保存的本地目录截图](Glide-1.2.0-本地目录.png)。

## 发布前实际设备验收

1. 从「文件」选一组本地视频，确认复制、重名保留、播放、封面和删除副本。取消选择不产生空来源。用不可读取的文件验证整批失败反馈；原文件保留。
2. 从真实文件提供方授权一个含子目录的目录，收藏、固定子目录并退出 App；重新打开后浏览和播放，撤销授权后显示错误，再重新授权原目录。
3. 用 iCloud 仅云端文件及第三方提供方各试一次，验证下载等待、失败和重新打开。系统行为依提供方变化，不把模拟器内目录成功等同于该项通过。
4. 使用横／竖视频拖动时间轴，确认画面方向、预览、松手定位、取消和快速换片。AVPlayer 不支持的文件给出播放错误，不宣称自动转码或广格式兼容。
5. 升级前准备已有 Jellyfin 来源、收藏、常用目录与电影／剧集进度，升级后核对其保留情况。WebDAV 本批不新增能力；既有真实 NAS 兼容性未重新认证。

这些项目需实际设备和用户文件授权；本次未将它们标为通过。
