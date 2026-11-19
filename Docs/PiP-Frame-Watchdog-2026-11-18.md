# 画中画返回桌面约六秒后中断

## 问题路径

用户反馈：开启画中画后回到桌面，播放几秒后窗口消失，返回 Glide 显示暂停。

`PlaybackController` 的原有看门狗在播放器时钟仍处于播放、原始 `AVPlayerLayer` 没有首帧状态时开始累计时间，超过六秒就记录 `video_frame_timeout` 并触发重新打开媒体或暂停。它排除了 AirPlay，未排除画中画。

苹果明确说明：PiP 使用独立的显示画面，进入 PiP 后 AVFoundation 停止向传入的原始 `AVPlayerLayer` 提供视频帧。因此原图层不能继续作为 PiP 视频正常与否的依据。原判定会把正常的渲染交接误当作黑屏恢复，打断当前画中画。这条代码路径与用户报告的延迟及暂停状态吻合；尚未取得此次真机诊断，不宣称排除了所有其他中断原因。

依据：[Adopting Picture in Picture in a custom player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)，Create the PiP controller 段落。

## 修改

- 将原有六秒无画面检测提取为生产代码使用的 `PlaybackFrameWatchdog`。
- 画中画启动中或已启动时停止累计原图层缺帧时间；退出 PiP 后从新的观察窗口重新计时。
- 保留普通内嵌播放超过六秒无画面的恢复逻辑，保留实际网络卡顿的时钟和缓冲检测。
- 保留暂停、缓冲、AirPlay、重新出现原始画面时清除旧计时的规则。
- 诊断增加 `pip_start_requested`、`pip_started`、`pip_stopped`、`pip_start_failed`、`pip_detach`、`background_pip_continue`、`pause_background`、`pause_audio_interruption` 和 `pause_requested` 等固定事件代码，不记录媒体地址、账号或令牌。

未修改音频中断处理策略、视频编码、画中画系统能力、字幕渲染或媒体文件。

## 回归

先保留旧判定，将真实生产计时逻辑接入测试：6 项中普通黑屏、原画面恢复、暂停／缓冲和 AirPlay 的 4 项通过；PiP 持续播放及进入／退出 PiP 的 2 项失败，共 6 个断言问题，复现了误超时。

加入 PiP 排除和清除计时后，6 项全部通过；全量核心测试为 11 项 XCTest 与 303 项 Swift Testing，共 314 项通过。

这些是时间与渲染目标的逻辑回归，没有伪装成真实系统 PiP。当前 iOS 27.1 Duo 模拟器已确认不支持 PiP，真实画中画切换和后台长期播放仍由用户在线下实体 Duo 复测。

最终构建、签名及 dSYM 检查见 `Testing/PiP-Watchdog-2026-11-18/summary.json`。版本为 2.0.1（11），用户已有连接及媒体不受影响。

## 线下复测

用同一视频开启画中画，回到桌面至少播放一分钟，再返回 Glide，检查窗口、画面和播放进度。通过后再测试打开游戏及顶部固定播放。

如果仍中断，请在返回 Glide 后直接导出播放诊断，避免先重试或换片覆盖当前事件；新增事件可区分原图层超时、系统音频中断、PiP 自行停止及应用后台暂停。
