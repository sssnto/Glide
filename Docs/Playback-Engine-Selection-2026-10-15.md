# 播放内核评估：1.2.1 调研与接口边界

日期：2026-10-15。下文保留 1.2.1 调研记录；最新 1.3.0 已接入固定 MobileVLCKit 3.7.3 的本地兼容路线，见 [功能规格](Glide-1.3.0-Functional-Spec.md)和[开发验收](Testing/Glide-1.3.0-compatibility-2026-10-15.md)。正式分发、网络与高级输出门槛仍须分别关闭。

## 已完成的工程准备

`PlaybackEngine` 定义装载／停止、播放／暂停／倍速、定位、状态、实际首帧、通用音轨／字幕、预加载、画面输出与本地预览。`NativePlaybackEngine` 承接 AVPlayer；`PlaybackController` 保留用户意图、Jellyfin 协商与自动恢复、观看进度和音频会话所有权。

渲染通过 `PlaybackPresentation` 交给 `VideoSurface`；原生层与未来自定义 UIView 的接入位独立。自定义渲染目前没有产品实现。预加载带内核身份；本轮仍仅有 AVPlayer。画中画只在适配器能提供系统播放层时接入。实际首帧依据显示层，不能把 readyToPlay 或 isPlayable 代替出画面证据。异步装载、定位、格式检查、时间轴预览都有失效边界；退出后不得回写下一条视频。

## 候选方案的公开材料

以下是本次读取的仓库声明，并非商业分发的许可结论；分发前需要对确定的版本、构建参数及全部传递依赖分别核对。

| 候选 | 本次看到的分发／依赖线索 | 下一步 |
| --- | --- | --- |
| AVPlayer | 项目已采用系统 AVFoundation／AVKit；具体容器、编码和输出受系统与设备限制 | 保留原生路线，先记录实测失败样例，再验证兼容路线 |
| KSPlayer | 当前 main 的 Package.swift 声明 Swift tools 6.2，包含二进制框架及 FFmpegKit 依赖；仓库 LICENSE 为 GPLv3；关联 FFmpegKit README 描述默认 GPL 构建及另一 LGPL 方案 | 先确定可分发的依赖组合与固定版本，不能把“有 SPM 包”等同于直接可替换 |
| VLCKit | 官方 README 声明 LGPLv2.1 或之后版本，提供 MobileVLCKit 的 CocoaPods／Carthage 集成说明；本项目此前已移除相关依赖 | 在独立验证目标评估包体、生命周期、轨道、定位和系统输出；不能直接恢复旧集成并当作已验收 |
| libmpv | 官方 Copyright 描述默认 GPLv2 或之后版本，以及受条件限制的 LGPL 构建路径 | 固定源码、构建选项和 FFmpeg 等依赖后再验证；不把单个构建开关视作完整许可审查 |

原始材料：[KSPlayer Package.swift](https://raw.githubusercontent.com/kingslay/KSPlayer/main/Package.swift)、[KSPlayer LICENSE](https://raw.githubusercontent.com/kingslay/KSPlayer/main/LICENSE)、[FFmpegKit README](https://github.com/kingslay/FFmpegKit)、[VLCKit README](https://raw.githubusercontent.com/videolan/vlckit/master/README.md)、[mpv Copyright](https://raw.githubusercontent.com/mpv-player/mpv/master/Copyright)。这些链接指向可变分支，不能充当未来锁定依赖的版本凭据。

## 进入兼容内核实施的验收门槛

1. 固定候选版本和完整依赖，记录许可、包体与构建方式；独立验证工程可重复编译。
2. 使用相同原创样例记录首帧、时钟、定位、连续定位取消、音轨／字幕、退出重开；覆盖 MKV／AVI 及原生失败样例。
3. 对 ASS／PGS、多声道、硬件与软件解码、网络随机读取分别验证，不由容器名推导支持。
4. 真机记录起播、内存、功耗、后台、画中画、AirPlay、HDR 输出；模拟器结果不外推为真机能力。
5. 验证 Jellyfin 恢复与本地安全授权；失败路径能清理资源，原生路线继续通过回归。

本轮样例生成脚本为 `Scripts/generate_playback_fixtures.py`；FFmpeg 仅用于开发验证素材生成，没有打包进应用。完整长期范围仍见 [SenPlayer 对齐路线](SenPlayer-Capability-Parity-Roadmap-2026-10-15.md)。

## 后续实施：独立候选验证

固定 MobileVLCKit 3.7.3，增加 `Experiments/CompatibilityPlayer` 独立应用及可重复生成工程脚本，复用生产 `PlaybackEngine` 契约。主工程不链接第三方 SDK。验证覆盖前 8 个原生基线文件及新增 ASS／双音轨 MKV，包含暂停、倍速、定位取消、立即退出与重开；启动缺库与底层异步停止修订均记录在 [验证报告](Testing/CompatibilityLab-2026-10-15.md)。

候选验证不改变 1.2.1 的原生支持边界。下一步进入主应用之前，仍需完整分发材料、真机生命周期／性能／输出及原生回归；目前不宣称兼容内核已可随正式版分发。

## 1.3.0 本地接入决定

在独立 ASS／定位／生命周期验证后，主应用接入共享适配器和固定 SDK，提供系统／兼容选择与失败重试入口。只有无请求头的本地 file URL 使用兼容路线；Jellyfin 在线流和 WebDAV 仍用原生路线。真机独立程序已完成 50 次开关和 1800 秒 1080p SDR 长播，实际主应用交互另行记录。SDK 架构裁剪与源码引用已固定，开源页与基础许可文本已随包加入。

这次选择关闭本地接入的工程门槛，不关闭完整格式与高级输出承诺：传递组件分发材料、人工听音、真实用户片源、iPad 真机及计划公开的视听专项仍是后续验收。上文“主工程不链接 SDK”等描述仅对应 1.2.1 历史阶段。
