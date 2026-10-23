# Glide 1.5.0 验收记录

日期：2026-10-19。状态：实施及验收中，**尚未批准发布**。用户反馈没有可用的 SMB 服务器，已授权在当前 Mac 创建只读测试服务并直接执行 iPhone 局域网验证。品牌 NAS 的兼容性仍与该合成服务结果分开记录。发布门槛以 [产品计划](../../Glide-1.5.0-Product-Plan-2026-10-19.md) 为准。

## 已确认结果

| 项目 | 结果与证据范围 |
| --- | --- |
| 核心逻辑 | 107 项通过：7 项 XCTest、100 项 Swift Testing；包括旧来源解码迁移、路径范围、特殊字符、身份隔离与读取停滞状态机。 |
| 严格并发与最低系统 | 所有 Core 源码及生产 SMB provider／ObjC 桥接通过 Swift 6 complete concurrency、arm64 iOS 17 simulator 类型检查；这项检查使用最小应用依赖桩，不等于完整应用的 Swift 6 迁移。完整工程仍使用原有语言设置。 |
| 固定 SDK | MobileVLCKit 3.7.3 自带 libsmb2 4.0.0；四个未修改公开头文件校验、设备 arm64 与模拟器 arm64／x86_64 所需 22 个导出符号通过。见 [ABI 报告](SMB-SDK-ABI-2026-10-19.json)。 |
| iPad 界面 | SMB 测试连接、保存、默认媒体、目录切换及实际播放通过；WebDAV 原生播放与横屏通过；Jellyfin 范围、搜索、排序、固定目录及重启恢复通过。见 [选定用例结果](UI-Regression-iPad-2026-10-19.json)。 |
| 中文字幕 | 生产 SMB 播放界面中显式选择内嵌字幕，简体 ASS、缺失指定字体的繁体 ASS、中文 SRT 均通过截图 OCR；[简体 ASS](Screenshots/SMB-CJK-12-cjk-ass.png)、[繁体 ASS](Screenshots/SMB-CJK-13-cjk-ass.png)、[中文 SRT](Screenshots/SMB-CJK-14-cjk-srt.png)。素材未把字幕设为默认，因此验证步骤显式选择字幕。 |
| 非关键帧与进度 | 55.231、71.5、300.75 秒暂停定位及进度持久化／重建媒体库恢复通过；另验 54.88、71.5、300.75 秒继续播放定位。见 [精度报告](SMB-Precision-iPad-2026-10-19.json)。 |
| iPhone 局域网 | 独立「Glide NAS 验证」1.5.0 (2) 在 iPhone 13 Pro Max／iOS 27.0 上通过八项应用内验证：WebDAV 原生播放与定位；SMB 保存、1000 条目、范围读取及四种素材播放／暂停定位。见 [真机报告](SMB-WebDAV-LAN-iPhone-2026-10-19.json)。1080p 首帧约 1.16 秒、4K HEVC 约 0.74 秒；首帧输入量分别约 11.8 MB／6.0 MB，小于完整文件。退出后服务端没有遗留会话。 |
| 最终界面回归 | 本地导入、重名副本删除、目录及重启恢复通过（约 101 秒）；SMB 正常界面中 1080p、MKV、4K 起播及 70% 暂停定位通过（约 84 秒）。六个选定回归用例均有明确通过记录；Jellyfin 原画兼容、重试及离线保留另有 [25 项详细检查](Jellyfin-Original-Transport-iPad-2026-10-19.json)。 |
| 正式归档 | 最终构建 2 的归档、严格签名验证和发布静态检查通过，应用与 MobileVLCKit 的 dSYM UUID 均匹配。见 [符号报告](Archive-Symbols-2026-10-19.json) 和 [构建报告](Build-Validation-2026-10-19.json)。未上传 App Store Connect。 |

以上 iPad 为 iPad Pro 12.9 英寸第六代 **iOS 26.3.1 模拟器**，不是实体 iPad。历史结果包中包含此前失败的其他用例，JSON 仅摘录明确通过的用例，不能将整包视作全绿。

真机通过报告时间为 2026-10-19 05:38:33 UTC。此前 iOS 曾返回 `-1009 / localNetworkProhibited`，用户确认本地网络及 WLAN 权限并手动重试后通过；没有证据将其归因为 SMB、服务端或特定系统缺陷。真机验证包早于最后增加的来源列表无障碍标识，播放代码一致。

## 压力验收及剩余门槛

完整合成服务压力测试已通过。以 [压力报告](SMB-Stress-iPad-2026-10-19.json) 的 `passed`、各检查项和 RSS 记录为准；最终报告包含 20 次连续定位、50 次打开／退出、五轮中断恢复、完整 30 分钟播放与停止后的连接释放；早期失败尝试已用于定位修复。压力报告记录连续媒体时间 1800.001 秒、60 次 RSS 采样；预热 5 分钟后约 211–294 MiB，拟合斜率约 0.14 MiB／分钟，未观察到显著持续线性增长。此为本次模拟器进程观测，不等于真机泄漏结论。

尚待收尾／外部验证：

- 用户 iPhone 到本机创建的 Samba／WebDAV 服务已完成实际连接与播放。真实品牌 NAS、休眠唤醒及物理设备上的长播／网络恢复仍未验证，继续用 [真实 NAS 验收表](Real-NAS-Acceptance.md) 分别记录，不把合成服务结果作为品牌兼容性结论。
- 实体 iPad 网络播放及物理设备内存／热表现。当前模拟器 RSS 只能说明此次模拟器进程的变化，不能作为真机内存或泄漏证明。

## 测试环境和复现

压力测试共享只绑定 Mac 的 `127.0.0.1`；用户要求的 iPhone 验收另创建 `glide150-lan-samba`，只绑定 Mac 当前局域网 IP 的 1449 端口。两者均不使用用户个人目录或 NAS。Samba 镜像固定为 `dperson/samba@sha256:66088b78a19810dd1457a8f39340e95e663c728083efa5fe7dc0d40b2478e869`，实际服务器 4.13.7。`/tmp/Glide150/share` 以只读方式挂载到 `/mount`。

| 端口 | 专用容器 | 场景 |
| --- | --- | --- |
| 1445 | glide150-samba | SMB2/3 普通账号、允许访客、客户端要求加密、五轮中断恢复 |
| 1446 | glide150-smb2 | 服务端最大 SMB 2.1 |
| 1447 | glide150-signed | SMB3、服务端强制签名、拒绝访问的 private 共享 |
| 1448 | glide150-sealed | SMB3、服务端要求加密 |
| 15445 | 阻塞 TCP fixture | 只接受连接不响应 SMB，用于取消／超时测试 |

测试凭据仅为本次生成的假账号，未接入任何用户账号。普通账号为 `glide`，密码为 `glide150-fixture`；访客共享名为 `guest`。固定镜像的 `/usr/bin/samba.sh` 参数设定共享为只读、最低协议 SMB2；其他三个容器分别增加最大协议、强制签名和强制加密约束。`private` 仅允许不存在的 `other` 身份，以验证权限失败与错误密码区别。

原创素材与既有项目生成器：

- `1080p.mp4`：1920×1080、H.264/AAC、约 60 秒，27,198,085 字节。
- `11-hd-dual-ass.mkv`：1080p H.264、两条 AAC、ASS，27,916,261 字节。
- `4k-hevc.mp4`：3840×2160、HEVC/AAC、24 fps、约 60 秒，91,357,974 字节。由原创测试图生成，实际通过 ffprobe 确认编码；早期同名错误样例未纳入最终 HEVC 结果。
- `longplay.mp4`：原创 1080p 素材重复拼接，约 35 分钟、908 MiB；为未读完整文件时的断网测试和持续长播提供足够长度。
- 三级目录下 1000 个条目；中文、空格、`#% @+&`、不同目录同名视频；同名 JPG 和目录封面。
- 中文 ASS／SRT 由项目 `Scripts/generate_cjk_subtitle_fixtures.py` 生成；没有使用用户私人影视文件。

核心测试：

```sh
swift test --jobs 2 --scratch-path /tmp/Glide150/CoreBuild
python3 Scripts/verify_smb_sdk.py
```

完整压力验证使用 `GlideCompatibilityQA` 构建，启动参数为 `--glide-smb-probe --glide-smb-stress -cellularPlayback NO`。启动后记录模拟器 UUID 与应用 PID，在另一个终端运行：

```sh
python3 Scripts/verify_smb_playback.py \
  --simulator <SIMULATOR-UUID> --pid <APP-PID> \
  --output Docs/Testing/Glide-1.5.0/SMB-Stress-iPad-2026-10-19.json
```

驱动脚本检查专用容器的固定镜像与只读挂载后才执行中断，最后恢复服务并检查连接释放。它不会连接或停止用户的 NAS。单独非关键帧验证改用 `--glide-smb-probe --glide-smb-seek-probe`。表单和字幕界面测试须设置测试运行环境 `GLIDE_SMB_FIXTURE=1`。

Mac 仅 8 GB 内存，使用单一模拟器、构建并发 2。首帧记录包含模拟器和本机 Docker 开销，不能直接推广为真实 Wi-Fi／NAS 性能；受控 NAS 首帧目标仍需按素材码率和实际吞吐验收。

## 本轮定位并修复的问题

- 旧片库后台刷新误取消新 SMB 来源认证：只将目录扫描注册到浏览取消范围，登录测试由自己的任务取消。
- 普通账号错误状态被后续 socket 重置覆盖：优先保留已完成 SMB 回调的认证／权限分类。
- 非关键帧暂停续播返回前一个关键帧：SMB 使用绝对时间定位，保留本地播放已有定位策略。
- 网络断开后输入时钟仍走：同时观察输入字节和实际显示帧，允许已有缓存播放后再给出恢复入口。
- 继续播放状态下网络定位不稳定：读取目标暂停帧后再恢复播放意图；显式保留重试位置，定位失败不静默回到开头。

## 发布范围

SMB 与 WebDAV 同时提供。SMB 是本版新增，WebDAV 沿用既有系统播放路线；SMB 入口使用 VLC，不将 PiP／AirPlay 承诺扩大到此入口。外挂字幕自动匹配和视频级记忆明确归属 1.5.1。发布文案见 [验收稿](../../Glide-1.5.0-Release-Notes.md)。

局域网 WebDAV 合成服务使用 `GLIDE_FIXTURE_BIND` 与 `GLIDE_FIXTURE_PORT` 显式绑定，默认仍仅监听 127.0.0.1:8768。真机用例的测试运行环境可分别设置 `GLIDE_SMB_FIXTURE_ADDRESS` 和 `GLIDE_DAV_FIXTURE_ADDRESS`；未设置时继续使用回环服务。
