# 1.3.0（8）原画兼容入口与协商修订

日期：2026-10-16。开发验证版，未发布。

## 用户原片复测

用户反馈构建（7）仍持续卡顿，设置中没有“尝试原画兼容”。所附诊断为原生 2160×3840、H.264 Main／5.2、SDR、50 fps、声明约 28.775 Mbps 的原画直放：`nativeStalls = 51`、丢帧 116、当前缓存 0、`recoveryCount = 0`。主动等待曾到达约 15.109 秒，续播前只有约 1.190 秒缓存；缓冲次数 21、已完成缓冲总时长约 36.893 秒。最近 30 个事件均被重复的原生停顿通知占据。

[原始技术诊断](Glide-1.3.0-build7-user-diagnostic.json)。下载统计包含范围读取与重读，不能据此计算原文件下载完成比例。42.884 Mbps 的观测速率也不证明供流持续稳定。该记录未包含当时协商响应与早期事件，无法确定本次究竟因初始能力标记被跳过，还是试用失败后返回直放；不能将这两种代码路径中的任何一种冒充原片实证。

## 代码问题与修订

此前将 `SupportsDirectStream` 当成跨协商的固定能力，既用它阻止高负载资源的预先尝试，也据此隐藏手动入口；一次自动尝试过后也会隐藏入口。另一个过严条件是仅接受 PlaybackInfo 返回 URL 已含 `VideoCodec=copy`：Jellyfin 的 `StreamInfo.BuildParams` 可以返回候选编码列表，而真正是否复制由后续编码请求处理，不能把候选编码直接当作已经发生的视频转码。

参考固定版本的官方源代码：[MediaInfoHelper 协商标记](https://github.com/jellyfin/jellyfin/blob/v10.10.7/Jellyfin.Api/Helpers/MediaInfoHelper.cs)、[StreamInfo 地址生成](https://github.com/jellyfin/jellyfin/blob/v10.10.7/MediaBrowser.Model/Dlna/StreamInfo.cs)、[EncodingHelper 视频复制](https://github.com/jellyfin/jellyfin/blob/v10.10.7/MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs)。这些说明接口语义，不代表已经确认用户服务器的具体版本或该次响应。

构建（8）的行为：

- 4K／声明码率至少 20 Mbps 的 Jellyfin 直放资源仍在出首帧前尝试一次原画分段，不再用上一次的 Direct Stream 标记否决下一次协商。
- 在同源、已协商的 HLS 地址上，若视频候选包含原片的原生 H.264／HEVC 编码，明确请求 `VideoCodec=copy` 与 `AllowVideoStreamCopy=true`；保留认证、会话、媒体版本和音频参数。明确禁止复制、需要字幕烧录、候选不含原编码、非 HLS 或地址缺失时拒绝试用。请求体继续关闭视频转码，源视频不降档。
- 仍使用 AVPlayer。兼容流未出首帧而失败时，返回直放一次，保留进度／倍速／播放意图。自动恢复预算与用户主动重试分开：失败后直放设置仍保留“重试原画兼容”，每次点击只发起一次，进行中禁止重叠请求。
- 直放时显示尝试／重试入口；试用失败时明确提示当前仍为直放；实际兼容流显示首帧后，设置显示“原画兼容已开启”。画中画等暂不能切换的状态显示禁用入口，不借能力猜测永久隐藏。
- 离线优先、手动转在线、播放中完成下载后的网络意图继续保留。
- 诊断 schema 9 增加 `directStreamFlag`、`originalTransportAttempts`、`originalTransportOutcome` 与不含文本／URL 的 `originalTransportFailure`。结果字段独立于事件环形记录，首帧成功清理临时错误时仍保留上次试用失败的技术原因。连续重复事件合并，原生总停顿数继续使用 AVPlayer 统计。

## 验证计划与边界

沿用原创 2160×3840、50 fps、约 29.7 Mbps 的 60 秒片源；本机服务仅绑定 127.0.0.1。补充能力标记 false＋候选编码列表、兼容地址缺失后人工重试、明确禁止复制、分段加载失败、原画副本转在线等场景。请求端断言关闭视频编码，分段地址断言显式请求视频复制。

Core 已通过 100 项（96 项 Swift Testing、4 项 XCTest），日志 `/tmp/Glide4K/core-build8-r2.log`。

播放器专项 `/tmp/Glide4K/Transport-Build8-R1.xcresult` 通过（152.076 秒），25 项生产控制器检查通过。初次响应标记为 false、兼容地址列出 `h264,hevc` 候选时，实际请求明确变为 `VideoCodec=copy`，原生输出保持 2160×3840，并越过开播停顿位置。初始路径没有直放媒体请求、缓冲或自动恢复。自动失败后人工重试成功且保留暂停和位置；明确禁止复制的响应没有发起分段请求；无可用地址时只自动尝试一次、保留手动入口和稳定失败原因。下载与在线切换的既有回归也通过。[专项报告](Glide-1.3.0-build8-transport-results.json)、[完成画面](Glide-1.3.0-build8-transport.png)。

独立真机验证包 1.3.0（8）已构建成功，并安装至此前配对的 iPhone 13 Pro Max；安装不等于原片播放验证。

Release 归档 `/tmp/Glide4K/Glide-1.3.0-8-final.xcarchive` 通过，发布预检确认实际主应用和 MobileVLCKit 的 dSYM UUID 匹配；DEBUG 测试入口未进入发布二进制，中文后备字体仍匹配锁定清单。[归档审计](Glide-1.3.0-build8-release-audit.json)。该归档未签名，仅验证发布配置，本次未上传 App Store Connect。

实际设置菜单交互 `/tmp/Glide4K/Menu-Build8-R1.xcresult` 通过（85.836 秒）：在 DirectStream=false 时首次试用入口可点击；服务端首次不提供兼容地址后，“重试原画兼容”仍可点击；第二次点击成功播放原画重封装并显示已开启状态。原路径展示、诊断不导出路径、30 秒缓冲偏好与 schema 9 均通过。[失败后入口截图](Glide-1.3.0-build8-menu-retry.png)、[成功诊断](Glide-1.3.0-build8-menu-diagnostic.json)。诊断保留 2 次试用、当前 active，以及前次地址缺失的技术原因，没有把旧错误当成当前失败。

独立真机包更新后已成功启动，无需用户再次配合解锁才能完成本轮安装。原片仍需在该验证包中直接在线打开；已有离线副本时点“在线播放”。本轮未更改系统网络环境，也没有把平均网络速度或模拟器出画结果当作原片卡顿已解决的证据。

没有用户原片或其 NAS 的 Mac 访问权限，模拟器协议样例不能替代构建（8）的原片复测。[统一验证索引](Glide-1.3.0-build8-validation-summary.json)。
