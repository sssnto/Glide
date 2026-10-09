# Glide 1.1.0（2）HDR 色彩回归

## 问题与证据

用户在 1.1.0（1）实机测试中报告部分视频整体偏绿。提供的诊断：iPhone14,3／iOS 27.0；源 HEVC Main 10、10-bit、HDR10、3840×1920；交付「服务器流（方式待确认）」；事件包含 `hls_single_variant`，`playlistMode=media`；输出尺寸仍为 3840×1920，首帧约 25.85 秒。没有输出编码、传递函数与色彩矩阵，不能据此断言服务器已执行或未执行色调映射，也不能把问题归因于杜比视界 Profile 5。

代码可确认两处风险：H.264 协商没有 SDR／8-bit 条件；单路 HLS 展开只检查主列表声明，没有检查源媒体是否为 HDR，可能把声明 SDR 而片段仍携带 PQ 的服务器流送入播放器。

对实际服务器 12.1.0 进行元数据与主列表验证：该集为 MKV 内的 HEVC Main 10、PQ／BT.2020、HDR10，未报告杜比视界 profile。旧协商为 TS／H.264；新协商为 fMP4／H.264、HEVC，转码原因由包含视频编码不支持变为容器与声音编码不支持。服务器仍报告 `SupportsDirectStream=false`，不能仅凭协商宣称实际视频码流复制成功。新主列表提供第一路 HEVC／PQ、第二路 H.264／SDR；即使请求只写 HEVC，仍返回两路。这符合 Jellyfin 在 HDR 复制流后提供 H.264 SDR 兼容入口的行为。验证仅请求元数据与列表文本，没有取得原片音视频片段；测试会话随后停止并注销，没有更改服务器全局配置。

## 客户端修订

1. 自动 HLS 和原画兼容采用 fMP4 与当前设备可解码的视频编码，已知 HEVC／HDR 来源请求 HEVC。只有完整主列表第一路明确声明 HEVC 与 PQ／HLG，且设备支持 HEVC 时，提前设置 AVPlayerItem 的 `startsOnFirstEligibleVariant`，请求从第一条可用路线起播；保留音轨、字幕与原生格式校验。SDR、首路 SDR、未知／歧义列表不启用此偏好。该属性只影响初始选择，系统仍可能在播放中换流，不能宣称全程锁定 HDR 或保证起播更快。原文件直放仍优先，强制兼容转换仍有既有的 1080p／720p 上限。
2. H.264 CodecProfile 明确 SDR、最大 8-bit 和原生支持的 AVC profile；1080p／720p URL 明确 H.264 与 `h264-rangetype=SDR`。已知 HDR→H.264 路线禁止视频码流复制，保留原有会话与认证参数。HEVC／copy 路线不强制转 SDR。
3. HDR 来源不再展开单路主播放列表，由 AVPlayer 保留正常 HLS 验证。误标输出可触发现有有界恢复。
4. 输出格式检查移到首帧后独立任务，先检查 AVPlayerItem 正在呈现的视频轨，再读取文件型 asset 的视频轨。HDR 服务器流另使用短暂的原生 10-bit／wide-color 解码帧输出读取附件，随后移除输出；不录制、保存或上传画面。已读取的 AVC/PQ、AVC/HLG，或明确请求 SDR 却仍收到 PQ／HLG 的解码帧，触发有界兼容恢复。没有格式信息时不猜测画面是否偏色，不对视频套绿色补偿滤镜。
5. 设置页到播放诊断／视频信息／字幕导入，在设置页退出后再呈现目标页面，避免两个呈现状态同时改变而导致目标页面未打开。
6. 诊断 schema 4 增加源传递函数／原色／色彩空间、请求目标编码／动态范围、实际输出原色／矩阵，以及色彩证据来自压缩轨还是解码帧（`outputColorEvidence`）。请求 SDR 不代表服务器已经正确色调映射，格式仍不可用时记录 `output_color_unavailable`／`output_codec_unavailable`，实际输出字段可为空；解码帧色彩是在 AVFoundation 输出端读取的，可能已经经过系统色彩转换；不能用它证明服务器原始片段已完成色调映射，也不能证明像素肉眼无偏色。不把请求目标编码冒充实际输出编码；仍不导出 URL、令牌或片名。

## 开发验证

- 最终 74 项核心测试通过（原有 67 项，加本轮 7 项），覆盖 SDR／8-bit 协商、HDR 主列表保护、URL 参数隔离、实际输出色彩判定边界、HEVC 请求与编码专属范围隔离、HDR 初始选流与歧义列表拒绝。
- iOS 27.0 HDR/HLS 合成回归 `testAutomaticPlaybackRecovery` 通过（119.744 秒），验证实际首帧／缓冲、保留 HDR 主列表、请求目标 SDR 与可读取的原生解码帧 SDR 色彩证据。早期用例因为强求恢复而失败：iOS 27.0 接受了该合成主列表并在原生解码输出端返回 SDR，不能要求它必须转码。另发现 asset 轨检查拿不到格式、部分轨信息提前终止帧检查，以及设置页跳转冲突，均已修订。
- iOS 27.0 断帧合成回归 `testAutomaticPlaybackRecovery` 通过（97.353 秒），验证音频时钟有效却没有画面时有界恢复至 1080p、实际首帧／缓冲、记住可用路线后再次播放；同次控制台自动隐藏／短点唤起通过（44.887 秒）。这些是选取用例的实际结果，不代表完整 UI 套件通过。
- 控制台重跑曾因 2 秒自动隐藏间隔短于 XCTest 点击后的可访问性快照等待而失败（56.080 秒）；测试专用间隔调整为 6 秒，仍要求自动隐藏后一次短点恢复存在且可点击的控制按钮。最新代码重跑通过（54.823 秒、0 失败、`TEST SUCCEEDED`）；产品手势未因这一测试计时调整而修改。
- 最终真机 Release 未签名编译通过；产物 Info.plist 为 1.1.0（2），本地发布预检通过。

HDR 与断帧界面用例通过后，新增了实际 HEVC／HDR 首路的初始偏好；这两个单路 H.264 合成 fixture 不进入新增分支。新增分支已做核心规则与 Release 编译验证；原片实机验收属于下方用户反馈，不计作自动化验证。

HDR 合成 fixture 模拟声明 SDR 的主列表与 PQ 标记的片段，允许原生正常出画或经兼容路线恢复；断帧 fixture 用合法音频时钟、没有可解码画面来验证自动恢复。它们验证协议请求、主列表保护、原生输出诊断和恢复流程，不是真实 HEVC→SDR 色调映射服务，不能证明用户原片色彩已正确。

## 原片复测

- 用 Xcode 运行 1.1.0（2），先按默认偏好播放同一集，观察肤色、灰色和白色、暗部是否恢复；在偏色最明显的位置对照 Jellyfin 官方客户端。播放设置 → 播放诊断导出 schema 4；核对 `playlistMode=master`、源 PQ／BT.2020，以及实际输出与证据字段。如果首路 HEVC／HDR 被请求优先起播，事件会包含 `hls_hdr_initial_variant`，此事件本身不证明实际选流或肉眼色彩正常。
- 测声音／字幕改变、上下切集、再次打开与拖动。原生 HEVC 路线、SDR 转码路线分别记录诊断。
- 若仍偏绿，提供 schema 4 诊断及 Jellyfin 的脱敏转码日志。检查的是服务器实际 FFmpeg 色调映射与输出，不能仅凭客户端 `requestedOutputRange=SDR` 宣称成功。应用没有修改服务器全局配置。

## 用户测试反馈

2026-10-09，用户在上述修订后确认「ok，测试完成」，并授权将代码提交到 GitHub。本轮实机复测按用户确认记录为完成，此前等待复测的状态已关闭；未收到新的诊断或转码日志，因此不扩展为所有格式、设备与网络环境均已验收。GitHub 提交与 App Store 上传／发布分别记录。

## 官方依据

- [Jellyfin StreamBuilder](https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Model/Dlna/StreamBuilder.cs)：VideoRangeType 条件参与码流兼容判断和编码范围选项。
- [Jellyfin DynamicHlsHelper](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Helpers/DynamicHlsHelper.cs)：HDR 视频复制路线的主列表可能附加 H.264 SDR 兼容入口，不能假设请求 HEVC 后只有一路。
- [Apple startsOnFirstEligibleVariant](https://developer.apple.com/documentation/avfoundation/avplayeritem/startsonfirsteligiblevariant)：请求以主列表第一条可用路线开始；播放中仍可换流，可能影响起播性能。
- [Apple HLS authoring specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html)：HDR 编码、初始化信息和播放列表动态范围声明需一致。
- [Jellyfin 硬件加速与色调映射](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/)：HDR／Dolby Vision 转 SDR 依赖服务器色调映射支持。

- [AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)：读取原生解码输出的像素缓冲，帧附件属于该输出端的色彩信息。
