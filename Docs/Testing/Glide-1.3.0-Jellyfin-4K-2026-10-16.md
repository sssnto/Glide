# 1.3.0（3）Jellyfin 原画 4K 缓冲修复

日期：2026-10-16。开发验证版，未发布。

## 用户诊断

两份输入内容相同，来自 iPhone 13 Pro Max、iOS 27.0、1.3.0（2）。用户反馈同一局域网 Wi-Fi 下声画频繁停顿。

- 原画直放，AVPlayer，未发生服务器视频转码或清晰度恢复切换。
- 2160×3840，H.264 Main、Level 5.2、8-bit SDR。
- 目标缓冲 30 秒，实际前向可用缓存约 1.057 秒。
- 记录 3 次短停，已完成的累计缓冲约 0.677 秒。
- `observedBitrate` 约 50.04 Mbps，表示传输观测值；输入缺少片源码率、帧率和掉帧数据。

已去除会话 ID 的 [原诊断](Glide-1.3.0-4K-user-diagnostic.json) 保留其余数值。现有信息支持“浅缓存伴随短停”的排查方向，尚不能确定用户网络带宽余量或排除其他解码性能因素。

## 改动

原逻辑只在单次已结束的缓冲持续至少 1.5 秒后提高缓存目标，用户报告的多次短停可能始终达不到该条件。单纯设置 `preferredForwardBufferDuration` 也不保证 AVPlayer 已经拥有对应时长的缓存。Apple 将该属性定义为偏好，较高值会增加资源需求：[官方说明](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration?changes=_11)。

在原生适配器中增加缓存续播等待：

- 适用于已实际播放过画面的网络原画／重封装／音频转换视频；长边至少 3840，或声明码率至少 20 Mbps。竖屏 4K 同样覆盖。
- 缓冲耗尽通知或等待状态且前向可用缓存不足 2 秒时，暂缓当前 AVPlayerItem 续播，保留用户播放意图与原路由。
- 目标为 6 秒可连续播放的媒体内容，倍速增加目标，最多 12 秒；文件尾部按剩余时长收敛。平台缓存已满时，可在至少 2 秒的有效缓存后恢复。
- 主动等待最多 15 秒，之后交回 AVPlayer 自动等待；有 5 秒冷却。原有持续卡死恢复看门狗继续工作。
- 暂停、拖动、停止、切文件和旧加载失效都取消等待，旧任务不能恢复新会话。当前流蓄缓存时取消下一条预备读取。
- 本地文件、普通低码率流、未知时长直播、外部播放与正在定位的输入不进入该等待。

诊断 schema 7 分别记录来源声明码率、来源帧率、AVPlayer 传输观测速率和指示码率，增加原生停顿、丢帧、主动填充次数、最近一次续播缓存和等待原因。原生统计负值表示未知，导出时保留为空。源码参考：[AVPlayerItemAccessLogEvent](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent)。

## 实际验证

新增原创素材生成器 `Scripts/generate_network_4k_fixture.py`：2160×3840、H.264 Main／5.2、8-bit SDR、约 24 fps、约 21.48 Mbps、60 秒、AAC。只提交生成脚本和结果，不将约 154 MiB 素材加入仓库。

`Scripts/fixture_server.py` 通过真实 MP4 的 HTTP Range 原画直放供流，每 2 MiB 注入网络间歇，其中一个间歇为 8 秒。每次协商具有独立素材源 ID，重试或重叠范围等待同一释放时刻，避免取消请求绕过测试延迟。

主应用 DEBUG 的固定 loopback 验证入口使用生产 `PlaybackController`、`NativePlaybackEngine`、`VideoSurface`；静音，读取原创样例，不接触用户媒体。该入口在 Release 中排除。

| 验证 | 结果 |
|---|---|
| Core 回归 | 94 项通过：90 项 Swift Testing、4 项 XCTest，包含新增竖屏 4K、高码率、尾部、倍速、容量边界与元数据兼容用例 |
| 真实 4K 网络专项 | `Network-R2.xcresult` 通过，生产控制器 7 项检查通过 |
| 实际输出与路由 | 2160×3840 AVC，原画直放，恢复切换次数 0 |
| 续播时可用缓存 | 6.451 秒；后续时钟正常推进 |
| 主动暂停 | 在填充等待中暂停，超过 15 秒旧等待时限后仍保持暂停 |
| 暂停拖动与恢复 | 保持暂停定位到 20 秒，主动恢复后推进到 22 秒 |

原始结果：`/tmp/Glide4K/Network-R2.xcresult`。[结构化记录](Glide-1.3.0-4K-network-results.json)、[画面](Glide-1.3.0-4K-network.png)。测试设备为专用 iPhone 17 Pro 模拟器、iOS 27.0（24A434）。

该轮人工注入的网络间歇造成一次累计约 20.49 秒缓冲，包含 AVPlayer 自身等待；15 秒只限制应用主动蓄缓存阶段。此数据验证等待行为与原画路由保持，没有用户原片修复前后的卡顿时长 A/B 数据。

首轮 `Network-R1.xcresult` 已完成原画／实际 4K／缓存续播检查，但第二次播放没有稳定耗尽缓存，未完成暂停取消检查。修订供流的重复触发条件后，R2 完成全部检查；不将首轮记为通过。

普通流回归 `/tmp/Glide4K/Native-Regression.xcresult` 两项通过：延迟 HLS 恢复后保留原流且只协商一次；视频信息、原路径展示、30 秒缓冲目标及 schema 7 诊断正常。当前原生控制逻辑同时覆盖普通流和新 4K 路径。

Release 归档 `/tmp/Glide4K/Glide-1.3.0-3.xcarchive` 通过，验证 DEBUG 网络入口未进入发布可执行文件，上一构建的字幕字体仍在包内且 SHA-256 一致。独立「Glide 兼容验证」1.3.0（3）已签名构建、安装并在已连接 iPhone 13 Pro Max 正常启动。

统一 [验证索引](Glide-1.3.0-4K-validation-summary.json)；[原创素材校验和及 ffprobe](Glide-1.3.0-4K-fixture.json)。用户原片仍需在手机验证版复测，模拟器结果不代表 iPhone 4K 60 fps 性能验收；持续下载吞吐不足以覆盖片源码率时，缓存等待不能代替网络或服务器改进。
