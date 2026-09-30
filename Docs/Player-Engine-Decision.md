# Glide 原生播放器方案

当前决策（2026-09-30）：所有播放统一使用 AVPlayer / AVPlayerLayer / AVKit。已移除 MobileVLCKit、CocoaPods 编译集成、VLC 画面和轨道状态，不要求安装第三方播放器库。

## 播放路径

1. 本地演示与兼容的离线文件直接交给 AVPlayer。
2. Jellyfin 通过 PlaybackInfo 协商系统可播放的原画、重封装或 HLS；直接播放配置仅声明当前设备支持的编码。
3. 原画无画面、失败或持续缓冲时有界地尝试兼容流、1080p H.264/AAC、720p H.264/AAC；恢复保留位置和播放意图。只有成功出画面后才记住需要视频转码的路线，记忆 24 小时后过期。
4. WebDAV 通过系统 AVAssetResourceLoader 与认证 Range 请求播放。它没有 Jellyfin 服务器转码能力。
5. Jellyfin 不兼容的离线文件尝试联网获取兼容流；没有网络时需要系统支持的文件。不能承诺系统直接支持 MKV、ASS/PGS 或所有 HDR / Dolby Vision profile。

## 原生优化

- 首帧：观察 AVPlayerLayer.isReadyForDisplay，同时核对当前 item，避免用音频时钟判定视频成功。定时观察仅作为补充。
- 缓冲：起播先使用 2 秒缓冲偏好；出画面后按倍速增加媒体缓存目标，1× 为 15 秒、2× 为 30 秒。保留系统自动等待机制；实际缓存由 loadedTimeRanges 决定。
- 定位：续播等待资源就绪并完成精确定位再播放；手动定位使用小幅时间容差，取消被新请求覆盖的 seek，回调核对会话与定位标识。
- 状态：缓冲等待延迟 350 ms 确认；短暂倍速／定位状态变化不计为网络卡顿。已出画面后不展示中央准备提示。
- 操作：上下刷片、左右倍速、长按快进／快退、轻点控制台、锁定、缩放和平移保持原有交互；画中画、AirPlay 和文件内轨道选择使用系统能力。

## 验证边界

核心测试覆盖缓冲和兼容策略；模拟器测试覆盖交互、定位、本地播放和 Jellyfin fixture 自动恢复。真实服务器的转码速度、4K 硬解、HDR / Dolby Vision、蜂窝网络与外部播放需按 [实机计划](Testing/原生播放器回归测试计划.md) 验收。

参考：[AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)、[首帧可显示状态](https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay)、[精确定位与容差](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:))、[缓冲偏好](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration)。
