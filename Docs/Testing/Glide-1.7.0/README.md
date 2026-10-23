# Glide 1.7.0 开发验收

2026-10-20，1.7.0（1）。Emby 接入及有条件的定位恢复已实现，本版范围内的核心、最终模拟器、iPhone、Release 归档、签名及符号检查通过。长 GOP 的历史偏差、真实素材复测和注入偏差的契约检查分别记录；未提交商店。范围见 [版本计划](../../Glide-1.7.0-Product-Plan-2026-10-20.md)，源文件哈希及构建结果见 [构建清单](Build-Validation-2026-10-20.json)。

## 已执行结果

| 检查 | 结果与证据 |
| --- | --- |
| 核心 | 135 项通过，128 Swift Testing + 7 XCTest；新增 10 项媒体服务器核心测试，包含定位恢复条件与一次性限制。[日志](Logs/Core-Final.log)。Core 由 Swift 6 包编译，不将此结果等同于全应用 Swift 6 迁移。 |
| Emby 应用内 | iPad Pro 12.9 第六代、iOS 26.3.1 模拟器 14 项通过：13 项真实官方 Emby 4.9.3.0／原生播放检查，另有 1 项明确注入解码器定位结果的生产控制器契约。覆盖 60+6 分页、原文件／视频复制 HLS、长 GOP 原创文件、双音轨、服务器字幕烧录、用户状态、字幕和跳过记忆、下载与删除。[原始报告](Emby-iPad-2026-10-20.json)。 |
| 正常界面 | 最终源码同一批 3 个测试全部通过：Emby 添加来源与实际播放、Emby 应用内检查、链接检查与长按编辑。[最终原始摘要](UI-Recovery-Final-Summary.json)、[日志](Logs/UI-Recovery-Final.log)。 |
| Jellyfin／链接回归 | 12 项生产流程检查通过：HTTP／STRM、Keychain、HLS、跳过、Jellyfin 标记、失败回退和取消等。[报告](Link-Jellyfin-Regression-iPad-2026-10-20.json)。Jellyfin 这一部分使用既有原创契约服务，并非真实 Jellyfin 服务器。 |
| iPhone | iPhone 13 Pro Max、iOS 27.0，最终源码的独立「Glide NAS 验证」1.7.0（1）安装与启动成功；14 项通过（13 项真实服务／原生播放，1 项注入偏差契约），时间为 2026-10-20 14:28:13（北京时间）。[最终报告](Emby-iPhone-2026-10-20.json)、[安装日志](Logs/Device-Install-Recovery-Final.log)、[启动日志](Logs/Device-Probe-Launch-Recovery-Final.log)。此前 12 项结果保留为历史证据。 |
| Release | 最终源码重新归档、deep／strict 签名、发布预检通过；应用与 MobileVLCKit dSYM UUID 匹配。[符号记录](Archive-Symbols-2026-10-20.json)、[预检日志](Logs/Release-Preflight.log)、[签名日志](Logs/Release-Signature.log)。未上传、推送或打标签。 |

[来源表单](Screenshots/Emby-Source-Form.png)、[电影详情](Screenshots/Emby-Movie-Detail.png)、[实际播放](Screenshots/Emby-Native-Playback.png)已进行视觉检查。

历史链接长按编辑首轮未进入目标页；自动化增加了菜单重新展开和有界点击重试，产品链接导航代码未变。首轮摘要和单独重跑摘要继续保留；最终源码已在同批 3 个用例中通过。设备首轮字幕烧录流定位为 4.5 秒、目标 5 秒，符合既有网络定位 ±0.5 秒容差；验证断言误用严格小于，修正为含边界并留出 0.01 秒浮点余量。保留 [首轮报告](Emby-iPhone-Assertion-Boundary-Failure-2026-10-20.json)。此前模拟器／真机、构建清单及归档符号的 Pre-Recovery 文件均为历史证据。最终 14 项真机检查通过后，尝试重开正常片库时 iOS 已锁定并拒绝启动，见 [日志](Logs/Device-Normal-Launch-Recovery-Final.log)；该次正常启动未通过，不再请求额外解锁。正常界面的 3 项操作测试在模拟器上通过，手机保留最终安装包，解锁后可手动打开。

最终构建仅出现未链接 AppIntents 的元数据提取提示；本次没有新增 AppIntents 功能，未屏蔽编译诊断。模拟器测试后已恢复原键盘设置并关闭测试模拟器；临时链接回归服务已停止。

## 实现与真实接口差异

新增独立 Emby 来源类型，保留旧来源枚举值和快照。登录使用 Emby 认证方案；根片库使用 Users/{UserId}/Views。令牌写入 Keychain，错误认证不会发布来源，失败重连保留原凭据。图片、下载、播放和用户状态都按来源生成认证。

Emby 4.9.3.0 的 DirectStreamUrl 是渐进式原文件地址。兼容播放单独请求 HLS：关闭 EnableDirectStream、开启服务器 HLS 协商，再通过既有策略强制 VideoCodec=copy；无法确认复制时保留失败回退。此项与 Jellyfin 的请求参数分开，未改变其兼容请求。返回的相对 HLS 地址保留用户配置的 API 路径前缀，拒绝其他来源和内嵌账号的地址。

Emby 轨道索引必须关联 MediaSourceId。详情页传递已选版本；语言偏好或其他仅携带索引的调用先取得默认版本 ID。服务器明确以 SubtitleMethod=Encode 烧录字幕时，界面和诊断标为视频转码，不标为原画复制。

电影、节目、家庭视频共用既有紧凑界面与个人记录。目录中的视频补足类型、节目、季集及已看字段，保证节目规则可关联。Emby 只复用手动跳过规则，不调用 Jellyfin MediaSegments；字幕副本和延迟仍按来源、根、账号及视频隔离。来源表单支持键盘“下一项”，避免密码输入时需要反复点选。

## 官方服务器与素材

官方 ARM64 镜像固定为 `emby/embyserver_arm64v8@sha256:22aeef01c017467c3e41d5f735bf93bff5745b54b7366b2df951d99efdf5f9da`，服务器版本 4.9.3.0。容器名 glide170-emby；配置与原创媒体位于 /tmp/Glide170，CPU 限制 1、内存限制 768 MB。未连接私人服务器，未使用商业影视素材。

服务器最初仅绑定 127.0.0.1:8772:8096，初始化专用假账号后，才增加指定 Mac 局域网地址的 8773:8096 映射供 iPhone 验证。账号为 glide-fixture，密码为 glide170-fixture，仅属于本次原创测试服务；服务令牌与原始服务日志留在 /tmp，不进入仓库验收材料。自动更新、UPnP 和库的联网刮削已在该容器中关闭。

`python3 Scripts/prepare_emby_fixture.py` 为上述本机测试服务准备电影、两集节目、中文嵌套家庭视频、64 个小型分页样例，以及单独的长 GOP 文件。总计 69 个媒体文件；电影库 66 个条目。主电影 660 秒，规则 2 秒关键帧、双 AAC 音轨和内嵌文本字幕。素材来自项目原创演示视频。

Debug／CompatibilityQA 的 `--glide-emby-probe` 使用生产 MediaClient、LibraryStore、PlaybackController、NativePlaybackEngine、字幕／跳过会话和 DownloadStore。单独的 contract 检查替换解码器，将复制 HLS 的定位完成结果注入为目标加 4.4 秒，再验证生产控制器切回原文件、恢复目标和保留播放／暂停意图；此检查不计为真实解码出画面。可通过 `-glideEmbyFixtureAddress http://Mac局域网地址:8773/emby` 指定手机使用的测试服务；该入口不进入 Release。GLIDE_EMBY_FIXTURE=1 启用对应 UI 验证。

## 已知问题与边界

保留 [长 GOP 原始失败报告](LongGOP-Seek-Failure-2026-10-20.json)。原始 AVC/AAC 样例含约 10.4 秒关键帧间隔，Emby HLS 的暂停定位目标 24 秒、实际约 28.4 秒，时长返回 666 秒；原文件定位正常。尝试 TS 分片也未修复，未保留这项无效产品改动。同一 SHA256 文件（5f27267f0669b859b153f03d302a83742d52f71c3f36ccaa81015763dc16c7cd）在新建媒体记录中复测可准确定位到 24 秒；实际报告中的 recoveryTriggered=false，不能据此宣称真实样例触发了恢复，也未确认服务端索引／时间轴差异的完整原因。

客户端现在检查解码器返回的定位完成值：仅 Emby 视频复制 HLS、同一原文件本次已成功出画面、MP4／MOV／M4V、未显式要求服务器音轨／烧录字幕且偏差超过容差加 0.15 秒时，尝试一次原文件精确定位，保留播放／暂停意图和媒体版本。手动再次尝试兼容才重新允许恢复；避免循环切换或丢弃选轨。核心条件和注入偏差的控制器契约已覆盖，不能扩展为已修复所有服务端索引、后续时钟漂移或依赖服务器选轨的组合。

未覆盖公网有效证书 HTTPS、反向代理路径前缀的 HTTP 端到端、所有 Emby 版本／硬件转码器、HDR／杜比视界／4K 高码率长播、直播、多版本影片、服务端下载权限关闭与更多服务器插件组合。URL 前缀策略有核心测试，官方服务的 /emby 别名有实际请求结果。HTTPS 沿用系统证书校验。此前 NAS 长播和字幕矩阵结果保留为历史记录，本轮不重复宣称完成。
