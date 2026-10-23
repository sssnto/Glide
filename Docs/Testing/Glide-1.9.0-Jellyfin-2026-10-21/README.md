# Glide 1.9.0（2）Jellyfin 播放修复

2026-10-21。用户在主应用报告 4K HEVC Main 10／Dolby Vision Profile 8 视频在首帧前失败；经明确授权，在主应用内使用已有 Jellyfin 登录验证用户指定的剧集。账号、令牌、地址、媒体内容和字幕正文不导出；检查报告仅保存技术字段。1.9.0（1）的字幕导航／循环验收保留在[原始记录](../Glide-1.9.0/README.md)，本目录记录后续修复，不能用原记录代替本次真实服务器验证。

## 问题与修复

[用户报告](User-Report.json)显示系统内核在首帧前返回 CoreMedia -12927，自动、1080p、720p 均未成功。实测服务器为 Jellyfin 12.2.0，视频为 3840×2160 HEVC，默认中文字幕是 PGS，另有同语言 SRT。

音轨／字幕索引必须绑定实际 MediaSourceId，包括字幕关闭的 -1。此前只有 Emby 的部分选择路径绑定来源，Jellyfin 可能忽略选择并继续使用默认 PGS 烧录。现在两种服务器都绑定；Jellyfin 关闭字幕时同时清理 URL 上残留的 Encode 参数，明确请求 -1／Drop。Emby 保留服务器协商的方法，不能传入 Jellyfin 的 Drop 值。

同时适配本次 Jellyfin 12 返回的媒体库／详情入口，旧版接口在 404 时回退，保留同源认证规则。

Jellyfin 文字字幕优先使用 External 路线，客户端读取服务器导出的 SRT，并使用现有字幕叠加组件显示。请求在内存中按字节限制 2 MB，解析沿用字幕文档限制；取消时停止请求，不保存字幕副本。用户明确选择的图形字幕不会被擅自替换；只有 HDR 自动播放的隐式图形默认轨允许选择同语言、相同强制属性的文字轨。字幕偏好仍受关闭状态与已有导入选择约束。

服务器 HLS 混流／音频转换需要允许建立转码任务，但这不表示客户端可以任意接受视频转码。原画兼容继续严格核对 VideoCodec=copy；只有 HDR HEVC、码率已知且服务器原因全部属于容器／音频转换时，自动路线才优先请求视频复制。烧录字幕、视频编码／分辨率／动态范围等转换条件不会绕过复制限制。实际解码仍保留 HDR 色彩检查与故障恢复。

“尝试原画兼容”恢复至服务器流和播放失败界面；重试保留定位和播放／暂停意图，适用时可直接操作。诊断新增来源类型、字幕处理方式与客户端字幕条数，各次尝试会清理这些字段。

## 真机结果

[最终构建报告](Production-iPhone-Final.json)来自主应用 Glide 1.9.0（2）、iPhone 13 Pro Max／iOS 27.0，使用生产 PlaybackController、真实 AVPlayer 与正常音频会话，未注入解码结果，未记录观看进度。用户重新连接后安装最终源码构建，报告时间为 2026-10-21 12:13（北京时间），不是此前候选包的旧报告。

- 默认打开即成功出画面，首帧约 5.959 秒，无降级恢复；输出为 3840×2160、hvc1，真实解码帧记录为 PQ／BT.2020。
- 客户端加载 823 条中文字幕，原生字幕轨未选中属于预期：视频流使用 Drop，文字由客户端叠加。报告同时记录字幕条数和语言，不能只凭 Drop 判为“关闭字幕”。
- 5 项检查通过：暂停时钟冻结、暂停跳至字幕句仍保持暂停、真实媒体时钟命中中文字幕、继续播放时钟前进、原画兼容已启用。
- 跳转后的恢复观察记录了约 2.67 秒缓冲；这次短测不代表所有位置无等待，也不代表完成整集长播、人工听音、Dolby Vision 屏幕输出或全格式矩阵验收。

最终源码见[快照](Source-Snapshot.json)，实际状态见[构建清单](Build-Validation.json)。最终包已安装并通过本次真机复核；已不带验证参数重新启动主应用，保留登录与媒体库。此前 CoreDevice 4016 的安装失败仍保留在[尝试记录](Attempt-History.json)，用户重新连接后已解决，不再是阻塞项。

## 回归与归档

| 检查 | 实际结果 |
| --- | --- |
| 核心 | 最终源码 157 项通过（150 Swift Testing + 7 XCTest），覆盖来源绑定、关闭参数与会话保留、同语言文字选择、严格复制条件和 Emby 隔离。[日志](Logs/Core-Final.log)。一次沙箱编译缓存失败另存[原件](Logs/Core-Sandbox-Failure.log)，未计作产品失败或通过。 |
| 正常字幕界面与双字幕 | 在最终 Emby 参数隔离前通过 2 个用例，覆盖台词搜索／定位、样式保留与重置、A–B 开关，以及真实 AVPlayer／VLC 的 18 项双字幕检查。此后只修改服务参数隔离及其核心测试，未重跑这 2 个用例。[双字幕报告](Dual-iPad-Regression.json)、[首批摘要](UI-Regression-First-Summary.json)、[日志](Logs/UI-Regression-First.log)。首批共 3 用例、2 通过、1 Emby 失败、无跳过；MCP 调用在 300 秒超时，实际 xcresult 完整保留，不把工具超时视为通过。 |
| Emby | 修复 Drop 参数后，最终源码独立重跑 1 用例通过、0 失败／跳过；官方 4.9.3.0 原创服务的 14 项检查通过，其中 13 项真实服务／原生播放，1 项单独标注注入定位结果的控制器契约。[报告](Emby-iPad-Final.json)、[摘要](Emby-Regression-Final-Summary.json)、[日志](Logs/Emby-Regression-Final.log)。 |
| iPhone 最终包 | 包含最后 Emby 参数隔离的最终构建安装成功，同一剧集 4K PQ／823 条中文字幕／5 项控制检查通过。[报告](Production-iPhone-Final.json)、[安装日志](Logs/Device-Install-Final.log)、[启动日志](Logs/Device-Launch-Final.log)、[正常启动日志](Logs/Device-Normal-Launch-Final.log)。 |
| Release | `/tmp/Glide190/Glide-1.9.0-2.xcarchive` 归档成功，版本 1.9.0（2）。[发布预检](Logs/Release-Preflight-Final.log)、[签名](Logs/Release-Signature-Final.log)通过，应用与 MobileVLCKit 的 dSYM UUID 完整匹配且无需修复：[符号报告](Archive-Symbols-Final.json)。[二进制检查](Release-Binary-Checks.json)确认本次及相关 QA 入口未进入 Release。 |

签名在沙箱中曾返回 `CSSMERR_TP_NOT_TRUSTED`，正常访问系统信任服务后，同一归档严格校验通过；失败日志保留[原件](Logs/Release-Signature-Sandbox-Failure.log)，没有修改信任设置或关闭签名校验。最终构建只保留未引入 AppIntents 的元数据提取提示。模拟器和专用 Emby 测试容器已停止，原创素材及配置保留。

## 保留的诊断历史

| 证据 | 可支持的结论 |
| --- | --- |
| [最初主应用检查](Investigation-Main-First.json)、[元数据](Investigation-Main-Metadata.json) | 匹配用户指定剧集和原始格式；默认图形字幕路线存在故障。早期直接内核循环重复调用 play，部分测试关闭蜂窝权限，不能用它们代表生产流程起播耗时。 |
| [绑定后的关闭字幕检查](Investigation-Off-Bound.json) | 关闭操作需同时绑定来源并消除 URL 烧录参数；单凭修改设备能力或 -1 不充分。 |
| [最初网络检查](Investigation-Network-Initial.json)、[GET 片段检查](Investigation-Isolation-First.json) | 最初 HEAD 返回 405，结论不足；后续同源初始化／片段 GET 返回 206，不能归因于完全无网络或账号不可用。未完成的网络阶段及直接内核试验不算生产播放通过。 |
| [生产文字轨检查](Investigation-Production-Explicit-Text.json)、[默认路线初测](Production-Default-First.json) | 视频可出画面，但原生文字轨未选中，不作为中文字幕验收。 |
| [选中 HLS 字幕后的失败](Production-Captions-Controls-First.json) | 同一设备、服务器和剧集选中该 HLS 字幕轨后，生产流程准备超时，促成客户端文字渲染修复；不推断所有 HLS 字幕都失败。 |
| [客户端字幕首测](Production-Client-Captions-First.json) | 823 条中文字幕与 4K PQ 出画面；控制检查只通过 3/4，恢复播放尚未通过，保留原件，不计为完整验收。 |
| [最终候选](Production-Final-Candidate.json) | 自动采用经过检查的视频复制后，字幕与 5/5 控制检查通过。 |
| [诊断字段清理后的复测](Production-Diagnostic-Reset-Pass.json) | 5.562 秒首帧、823 条中文字幕、4K PQ 与 5/5 控制检查再次通过；跳转恢复记录约 3.14 秒缓冲。此时尚未补充 Emby 参数隔离。 |
| [Emby 首轮失败](Emby-iPad-Drop-Failure.json)、[服务器异常摘要](Emby-Server-Drop-Failure.json) | 官方原创 Emby 服务在备用音轨／关闭字幕时明确拒绝 Drop，返回 HTTP 400。已把该 URL 修正限定为 Jellyfin，增加跨服务回归断言；失败原件保留，不计通过。 |
| [最终源码真机复测](Production-iPhone-Final.json) | 最终包安装后，5.959 秒首帧、823 条中文字幕、4K PQ 与 5/5 控制检查通过；跳转恢复约 2.67 秒缓冲，未触发质量降级。 |

## 支持边界

本轮修复针对该 Jellyfin HDR／字幕协商路径。只有图形字幕且无同语言文字轨时，烧录仍依赖服务器正确的 HDR 转换能力；明确选择 PGS 仍走服务器处理。服务器文字字幕为当前播放会话的内存数据，不承诺新建其选择／偏移持久化；转换成 SRT 也不保留 ASS 排版效果。字幕叠加不宣称覆盖 PiP／AirPlay 的外接输出。未推送、打标签或上传商店。
