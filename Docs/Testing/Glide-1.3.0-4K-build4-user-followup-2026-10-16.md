# 1.3.0（4）用户原片复测：仍然频繁缓冲

日期：2026-10-16。输入为用户提供的播放诊断，以及“文件约 600 MB、时长四五分钟”的补充。原文件不能从当前 Mac 访问。

结论：构建（4）的主动预装载与缓存等待没有解决该片源的实际问题。模拟器专项通过只说明测试条件下的控制行为正确，不能据此将此问题关闭。

## 已知事实

- iPhone 13 Pro Max、iOS 27.0；原生 AVPlayer 原画直放，2160×3840 H.264 Main／5.2、50 fps、SDR。
- 首帧约 2.53 秒；原生报告 7 次停顿、2 个丢帧。
- 已结束的缓冲共 55.578 秒，正在进行的缓冲 27.287 秒，合计约 82.865 秒。
- 主动缓存等待触发 2 次，两次都出现 `network_rebuffer_deadline`；最近一次等待 15.076 秒后只有 1.215 秒连续可播放缓存，没有达到约 6 秒的目标。
- 当前状态为原生等待 `AVPlayerWaitingToMinimizeStallsReason`，缓存未满，`likelyToKeepUp = false`。因此当前快照已经不处于应用主动暂停等待阶段，AVPlayer 自身仍在等待。
- 最新 access-log 事件报告约 309.820 MB 传输字节、25.275 Mbps 观测吞吐；来源声明码率约 28.654 Mbps。这组观测吞吐低于声明值，但不等于 Wi-Fi 链路的容量测试结果，也不足以定位到 Wi-Fi、NAS 读取、Jellyfin HTTP 响应或 AVPlayer 范围读取中的某一环节。
- 单凭传输字节数不能推算唯一文件下载百分比，也不能判定存在重复读取：访问日志没有给出各请求的文件区间与去重字节数。

已移除会话标识的 [用户原诊断](Glide-1.3.0-4K-build4-user-diagnostic.json)。

## 文件大小与码率

按十进制 MB 估算，600 MB 在 240～300 秒内播放，对应全文件平均约 16～20 Mbps，约 2～2.5 MB/s；这不是实际峰值码率。用户给出的大小与时长均为近似值，和日志中声明的约 28.7 Mbps 有差异，因此不能把后者直接视为核实过的全文件平均码率。

Apple 将 `observedBitrate` 定义为已下载媒体的经验吞吐，将 `indicatedBitrate` 定义为服务器声明的播放所需吞吐；两者都不是独立的网络测速。参考：[observedBitrate](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent/observedbitrate)、[indicatedBitrate](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent/indicatedbitrate)。

这些数据更支持继续检查媒体数据供给与读取链路；丢帧很少不能严格排除文件或原生解码问题。

## 下一步对照

使用已经具备的功能：视频详情“下载原文件”→“加入下载队列”→下载完成后从“离线”播放，并在播放设置明确选择“系统播放”。该下载入口读取 Jellyfin 的原文件下载端点，不请求视频转码。

- 同一系统内核、同一原文件、同一时间位置离线流畅：支持把排查范围集中到远程供流／读取，而不是仅凭编码格式推测内核不支持；仍不能单独确定是哪段网络或哪种 HTTP 读取行为。
- 离线仍停顿：需要检查原文件时间戳、封装、码流与原生播放表现，避免继续围绕网络调缓存。
- 对照必须使用系统播放；改用 VLC 会同时改变传输和解码实现，无法单独隔离网络因素。

后续用户按该对照步骤反馈“离线播放不卡顿”。没有附带新的离线诊断，因此将其记录为用户反馈，不能独立核验此次内核与完整播放时长。该结果支持优先处理远程供流与读取路径；尚不能细分到 Wi-Fi、NAS、服务器或 AVPlayer 范围读取中的某一环节。后续实现见 [构建（5）原画传输恢复](Glide-1.3.0-Original-Transport-2026-10-16.md)。
