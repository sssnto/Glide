# 兼容播放内核独立验证（2026-10-15）

这是对齐 SenPlayer 路线中 M0／M2 的开发验证。Glide 主应用仍为 1.2.1（1），默认 AVPlayer；新建的 CompatibilityLab 为 0.1（1），不属于已发布功能。

## 依赖和复现

固定 MobileVLCKit 3.7.3 官方归档，SHA256：`0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9`。运行时内核自报 `3.0.23 Vetinari (3.0.23-2-47-g3f8bd11fd0)`；SDK 版本与 libVLC 版本分别记录。

独立工程生成与原创样例见 [验证程序说明](../../Experiments/CompatibilityPlayer/README.md)。主工程没有 MobileVLCKit 链接项；本次真机 Release 构建产物的 Frameworks 目录为空，`otool -L` 未列出该库。只将原有 PlaybackResource／LocalFileAccess 移到共享文件，便于同一资源契约用于两个工程。

素材使用 FFmpeg 8.0.1 testsrc2／sine 和自写字幕生成，320×180、15 fps、约 20 秒。原生基线的前 8 个文件原样复用；新增单／双音轨 ASS MKV。FFmpeg 仅在开发机生成素材，没有作为工具打包到 Glide。

## 本次退出问题与修订

1. 用户报告中的进程为 `CompatibilityLab`，终止原因是 `DYLD / Library missing`。工程原来只链接 SDK，遗漏了嵌入；现已增加 Embed Frameworks 与构建时缺库检查。
2. 后续启动暴露当前 iOS SDK 的 UIScene 要求；验证应用补齐 scene delegate 和 window 生命周期。
3. 轨道信息就绪与真正出画面分开：start-paused 准备阶段使用媒体轨道／时长；首帧要求当前媒体 displayedPictures、可见窗口和有效尺寸，再要求本会话新产生的 PNG 含测试图案。
4. 快速退出测试发现 `stop()` 是异步操作。过早销毁播放器会在 `libvlc_media_player_destroy → pthread_join` 阻塞主线程；即便收到停止通知，底层线程也可能仍在进行 UIKit 清理。因此立即清除业务状态、取消旧定位，每次装载使用独立画布；旧播放器、画布与文件访问租约保留至停止完成，再在后台释放底层播放器。测试要求旧会话全部释放，不能通过保留所有旧播放器回避问题。

SDK 实现依据：[3.7.3 VLCMediaPlayer.m](https://github.com/videolan/vlckit/blob/3.7.3/Sources/VLCMediaPlayer.m)。上述线程结论也由两次本机采样栈验证；首次生命周期用例失败被保留在中间 xcresult 中。

## 验证结果

最终覆盖 **5 个独立界面用例**，分三组运行，均通过。不能累加中间轮次得到更大的用例数量。主应用 Release 构建通过，本次核心回归 **89 项通过（86 Swift Testing + 3 XCTest）**。完整脱敏结果见 [结果 JSON](CompatibilityLab-results.json)，原创素材与校验见 [样例清单](CompatibilityLab-fixtures.json)。

| 用例 | 结果与证据 | 最终结果包 |
| --- | --- | --- |
| 常见容器 | H.264／AAC MP4、HEVC／AAC MP4、H.264／AAC MKV、MPEG-4／MP3 AVI 均生成实际画面 | `Matrix-Controls-R5.xcresult` |
| 异常与改名 | 改后缀 MKV、多音轨 MP4 出画面；截断 MP4、纯音频 MP4 没有被判为视频成功 | 同上 |
| 控制 | 预备暂停、播放／暂停、两条音轨切换、字幕开关、连续定位取消、2× 时钟通过；定位到 5.0 s，1.2 s 内推进 2.41 s | 同上 |
| 生命周期 | 立即／50 ms／100 ms 退出后状态清空；MKV → AVI 重开出画面；旧定位不回写；旧播放器全部清理。三次业务 stop 返回为 5.66／9.49／0.11 ms | `Lifecycle-Visual-R4.xcresult` |
| ASS 视觉 | 单／双音轨 MKV 在选择字幕并显式定位到 2 s 后，通过屏幕 OCR 与人工截图核对，显示黄色粗体文字和黑色底框 | `ASS-Seek-R7.xcresult` |

以上结果包均在 `/tmp/GlideCompatibility/`；它们是本机开发产物，不纳入 Git。截图：[单音轨 ASS](CompatibilityLab-ASS-single.png)、[双音轨 ASS](CompatibilityLab-ASS-dual.png)。

**本节保留 R4–R7 首批历史结果。** 在不额外定位的 R6 中，单音轨字幕显示，双音轨文件的起始长字幕未显示；R7 证明定位后能渲染，不代表当时已修复起播。后续起播、切轨、倍速和暂停定位的修订及最终状态见 [ASS 增量记录](CompatibilityLab-ASS-2026-10-15.md)，不能继续把本节的五个用例作为最新结果。复杂稀疏字幕与跨集偏好仍须扩展样例，不计作完整 ASS 已对齐。

## 验证边界

- 音轨索引切换通过只证明选中状态，尚未完成实际声道输出／音质对照。
- 截断文件与纯音频的预期是没有视频画面；这些用例通过不能写成文件可作为视频播放。
- 解码 PNG 不足以证明字幕出现在屏幕上，ASS 样式必须另外检查系统屏幕截图。
- 本轮为 Apple Silicon、iOS 27.0 模拟器；不推导真机硬件解码、4K／HDR／杜比、功耗或系统输出能力。计时包含轮询、准备及截图等待，不能作为冷启动性能承诺。
- 尚未验证 PGS／SUP、外挂字幕、字体附件、复杂 ASS 特效、服务器网络随机读取、Jellyfin 恢复、预加载、PiP／AirPlay 或安全授权失效。
- 未并入生产应用、未修改商店文案、未提交或发布版本。

## 包体和分发材料

官方压缩归档 263,874,748 字节。独立的未签名真机 Release 应用（包含测试素材）为 108,754,961 字节，其中嵌入框架为 97,898,633 字节、测试素材 10,234,411 字节。该框架仍包含 armv7／armv7s／arm64；这些是未裁剪本机产物的体积，不能视为最终 arm64 IPA 或商店下载大小。

归档带 `COPYING.txt`（LGPL 2.1 文本）与示例工程许可。当前材料尚不足以冻结全部传递组件、对应源码和可重复构建／分发方式；本轮只记录候选材料，不得由一个许可标签推定整个分发包已完成审查。详细哈希、架构与体积见 [依赖审计](CompatibilityLab-dependency-audit.json)和[体积审计](CompatibilityLab-size-audit.json)。

## 下一批进入主应用前的工作

先冻结可重复构建与分发组合，补 arm64 真机的退出、起播、内存、温度与系统输出验证，再按明确格式范围接入本地来源的兼容内核选择与失败回退。完成后才形成 1.3 的用户测试构建；WebDAV 增强继续暂缓。网络来源、字幕扩展和其他 M2 余项分批推进。
