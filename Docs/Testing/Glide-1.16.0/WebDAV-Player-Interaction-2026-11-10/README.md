# WebDAV 播放交互与目录封面 · 1.16.0（7）

## 改动

正常播放器不再跳到独立的目录选择工具。当前直接播放的 WebDAV MP4／MOV／M4V 在播放设置首行显示“视频方向与保存”，左右旋转立即作用于现有画面和 ASS 画布，控制器不旋转；无需下载或重新解析文件后才预览。点击保存并确认后才读取、校验、备份和替换当前文件，完成后重新读取正确方向，保留进度、播放／暂停状态、倍速和内嵌音轨／字幕选择。当前会话提供从备份还原。

方向控制区与播放器实际分配空间，不遮挡播放按钮和进度条；横屏使用紧凑操作行。入口对 Jellyfin、Emby、SMB、本地／离线副本、STRM、画中画和外部播放隐藏。原有独立工具继续作为 DEBUG 验收入口，原文件保存格式和保护条件未放宽。

WebDAV 目录优先使用封面图片，没有时从视频取帧；目录只有子目录时继承后代视频的封面。优先复用目录索引，缺失时限量向下查找；仅为可见目录加载，限制并发和取帧时长，JPEG 缓存按来源、账号、视频及修改时间隔离。当前取帧使用系统可解码的视频；候选无法解码时尝试其他候选，仍不可用或没有媒体的目录保留占位图。播放器保存后更新封面请求版本。

## 验收证据

- **265 项核心测试通过**，包括当前 WebDAV 原文件绑定、外部来源与离线副本拒绝、封面向下继承、显式封面优先、循环／越界／遍历上限，以及原有目录缓存和 WebDAV 方向写入保护。见 [日志](Logs/Core.log)。
- iPhone 17 模拟器、iOS 26.3.1、Xcode 27.1：**2 项 UI 测试通过**。完整路径为：两类目录封面均显示 → 播放当前视频 → 设置首行进入方向操作 → 确认没有连接或路径选择 → 右转 90° → 同一打开次数和 AVPlayerLayer → 播放按钮与进度条仍可触达 → 确认备份并保存 → 打开次数增加一次且临时方向归零 → 从备份还原。见 [日志](Logs/Simulator-UI.log)、[旋转画面](Screenshots/Player-Rotation.png)、[还原](Screenshots/Player-Restore.png)、[直属和多层目录封面](Screenshots/Folder-Covers.png)。
- UIKit 几何探针 **14 项通过**：旋转交换内部视口、保留播放层和 player、ASS 与视频同步、旋转后捏合不反复修改解码器几何、复位还原视口，以及原有缩放回归。480 次缩放中解码器 frame／bounds／transform 重复写入均为 0。这不是视频帧率测试，也不是所有片源的性能保证。见 [报告](VideoZoomQA.json)。
- 封面验证记录实际解码出两帧，包含只存在后代视频的目录，见 [脱敏记录](WebDAVArtworkQA.json)。原始视频来自仓库原创 demo，不使用私人片源。

初期测试发现本机服务不支持开放结尾 Range／未截断超长 Range，修正测试服务后才取得真实封面。另发现半屏设置中的底部按钮裁切、方向面板遮挡播放控件及额外 clipping 影响触控，已移到设置首行并为面板分配实际布局空间。失败尝试不计为通过，截图与日志对应最终通过路径。

核心测试验证保存后除方向矩阵外其余字节保留；本次完整 UI 使用一个暂停于约 3 秒的原创短片。多音轨选择恢复已实现，但本次样例没有多音轨，不把它计为多音轨真机验收。真实 NAS 的原子替换与还原能力见前序构建 5 记录，本次不自动修改用户既有片源。

1.16.0（7）主应用已完成签名检查、安装及成功启动，既有连接与片库保留。正式 Release 编译、深度签名检查和静态发布预检通过，结果见 `Validation.json` 与 `Logs/`。新交互在模拟器实际操作验收，未将安装成功记为真机物理触控验收。当前未提交、推送、打 tag、上传商店或更新官网。[最终源码摘要](Source-Snapshot.json)、[功能说明](../../../Glide-1.16.0-WebDAV-Player-Interaction.md)。

## 重跑

启动 `python3 Scripts/rotation_webdav_fixture.py`，仅监听 127.0.0.1:8828，使用原创短片与虚拟认证。以 CompatibilityQA、独立 bundle `com.songpeng.glide.webdavqa`、单个模拟器和关闭并行测试运行：

`TEST_RUNNER_GLIDE_WEBDAV_PRESENTATION_FIXTURE=1` 对应 `testWebDAVInlineRotationAndInheritedFolderCovers`；`TEST_RUNNER_GLIDE_ZOOM_FIXTURE=1` 对应 `testVideoZoomGeometryContract`。

完整核心回归：`GLIDE_ROTATION_HTTP_FIXTURE=1 swift test --scratch-path /tmp/GlideRotationCore`。
