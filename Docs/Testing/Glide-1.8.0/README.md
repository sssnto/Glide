# Glide 1.8.0 开发验收

2026-10-20，1.8.0（1）。本版新增两份外部 SRT／VTT 双字幕与集中式字幕控制，不依赖外部账号或 NAS。Plex、飞牛按用户决定暂缓。范围见 [版本计划](../../Glide-1.8.0-Product-Plan-2026-10-20.md)，操作见 [体验步骤](User-Acceptance.md)。核心、模拟器、iPhone、Release 归档、签名及符号检查通过；结果受下述实测范围限制，未提交商店。源文件哈希和构建结果见 [构建清单](Build-Validation-2026-10-20.json)。

## 实现

主字幕和第二字幕使用独立会话、选择及延迟，共用播放器媒体时钟和一次同目录扫描。旧主字幕记忆键保持兼容，第二路使用独立键；关闭字幕后保留已导入副本，当前仍在读取的视频信息与字幕导入通过临时引用保护，避免另一条字幕保存时误删副本。来源、账号、目录和视频继续隔离。

字幕控制页集中提供选择、导入、0.1 秒偏移、归零、第二字幕字号、整体底部位置和关闭入口。字幕绘制位于控制遮罩上方，控制栏显示时按实际高度避开进度条；长句允许换行。取消文件导入后返回原字幕控制页。选择内嵌字幕时关闭第二字幕。

兼容内核对本地暂停定位改用时间定位及短暂静音解码，观察到新画面且真实时钟接近目标时暂停，继续观察时钟稳定后恢复音量和倍速。取消、切换请求、结束及超时也恢复音量；不改变调用方播放意图。SMB 保留原有时间定位和一次推进。

首轮短样例的第二次暂停定位曾停留在旧时刻，六次推进配合旧百分比定位也曾再次失败，见 [原始报告](Dual-Subtitle-Repeated-Seek-Failure.json)。仅改用时间定位后，新增的反复往返检查仍有失败，见 [报告](Dual-Subtitle-Time-Only-Repeated-Seek-Failure.json)，因此未将该试验作为完成结果，也不将最终处理表述为逐帧精确定位。

接口核对采用 [VideoLAN 的 VLCKit 3.x 源码](https://raw.githubusercontent.com/videolan/vlckit/3.0/Sources/VLCMediaPlayer.m)与 [libVLC 3.x 源码](https://raw.githubusercontent.com/videolan/vlc/3.0.x/lib/media_player.c)。两种 setter 对应不同的定位入口；定位停留在旧关键帧是本次样例的观测与推断，不代表已经证明所有容器的内部原因。没有引入新 ABI 或更换 SDK。

## 已执行结果

| 检查 | 结果与证据 |
| --- | --- |
| 核心 | 141 项通过：134 Swift Testing 与 7 XCTest，其中新增双字幕核心测试 6 项。[日志](Logs/Core-Final.log)。仅核心包由 Swift 6 编译，不代表全应用 Swift 6 迁移。 |
| 双字幕生产流程 | 最终模拟器 18 项通过，真实 AVPlayer／VLC 出画面；覆盖两路偏移、重复往返暂停定位、倍速、重开、导入副本保留、文件变化与取消隔离。[原始报告](Dual-Subtitle-iPad-Final.json)。12 个定位样本均等于目标值，其中 8 个往返样本同时确认实际暂停。 |
| 正常界面 | 选择两路字幕、0.1 秒微调、重启恢复、关闭第二路、取消系统文件选择后返回原页全部通过；文字像素 OCR 与字幕避开时间轴的几何检查通过。[摘要](UI-Controls-Final-Summary.json)、[日志](Logs/UI-Controls-Final.log)。后续仅兼容内核生产逻辑与独立回归测试辅助函数变化，该用例使用系统播放，字幕界面实现未再修改。 |
| 最终回归 | 最终源码同批 4 个测试全部通过，无跳过：双字幕生产检查、1080p VLC 时间轴点按定位／播放／暂停、原单字幕关闭／重启／重新启用、官方 Emby 生产流程。[摘要](UI-Regression-Final-Summary.json)、[日志](Logs/UI-Regression-Final.log)。 |
| 原单字幕 | 12 项生产流程通过，保留单字幕兼容、导入副本及记忆失效规则。[报告](Primary-Subtitle-iPad-Final.json)。 |
| Emby | 既有官方 4.9.3.0 原创服务回归 14 项通过；其中 13 项真实服务／原生播放，1 项注入定位偏差的控制器契约，与真实解码证据区分。[报告](Emby-Regression-iPad-Final.json)。测试服务沿用 [1.7.0 配置与边界](../Glide-1.7.0/README.md)。 |
| iPhone | iPhone 13 Pro Max、iOS 27.0，独立「Glide NAS 验证」1.8.0（1）最终源码构建、安装、启动及 18 项检查通过，2026-10-20 16:41:55（北京时间）。12 个实际定位样本均到达目标值，8 个往返样本同时确认实际暂停。[最终报告](Dual-Subtitle-iPhone-Final.json)、[安装](Logs/Device-Install-Final.log)、[启动](Logs/Device-Probe-Launch-Final.log)。 |
| Release | 最终源码归档、发布预检、deep／strict 签名及应用／MobileVLCKit dSYM UUID 检查通过，无需补修符号。[符号报告](Archive-Symbols-2026-10-20.json)、[预检](Logs/Release-Preflight.log)、[签名](Logs/Release-Signature.log)。 |

[双字幕画面](Screenshots/Bilingual-Subtitles.png)、[独立偏移控制](Screenshots/Independent-Offsets.png)和 [1080p 兼容播放](Screenshots/Compatibility-1080p.png)已逐张进行视觉检查。原单字幕的正常菜单流程仍收到 UIKit 的 `_UIReparentingView` 运行时提示，原始摘要保留该提示；当前检查没有出现崩溃，不能据此覆盖所有系统版本。

真机完成 18 项检查后，尝试重新打开正常片库时手机已锁定，iOS 拒绝启动，见 [日志](Logs/Device-Normal-Launch-Final.log)。该次正常模式重启未通过，不再要求额外解锁；手机保留已验证的最终包与原创素材，解锁后可手动打开。正常界面的操作流程在模拟器上通过。两次构建只有未链接 AppIntents 的元数据提取提示，本版未新增 AppIntents，未关闭编译告警。模拟器已关闭，键盘设置未改动。

## 历史失败与修正

首轮嵌套菜单未稳定进入字幕选择，改为字幕控制页内的导航列表。自动化随后暴露了短样例连续暂停定位未更新、测试暂停位置与正偏移的边界设置错误、控制页中未完整显示的步进器点击、重新展开快捷菜单、视频点击与系统文件选择取消返回等问题。原始失败报告与摘要保留在本目录。

1080p 回归首轮将素材装在 Documents，而应用读取 Application Support，导致目标文件不存在；此轮未验证解码。后续改为实际读取目录并核对 [素材哈希](Targeted-Format-Fixtures.json)，不放宽定位断言。一次界面拖动回归未到达目标，失败继续保留；最终用时间轴点按覆盖同一生产定位入口，双字幕正常界面另行覆盖时间轴拖动。屏幕截图还发现遮罩压暗字幕及字幕靠近时间轴，产品布局修正后可读性、OCR 和间距检查通过。[历史尝试汇总](UI-Attempt-History.json)保留原始通过／失败数量与修正说明；历史 Fifth 报告不是最终验收结论。

## 范围与限制

双字幕首批为两份外部 UTF-8 SRT／VTT；主字幕在上，第二字幕在下，默认关闭第二字幕。本版不包含双内嵌字幕、外挂 ASS、服务端烧录字幕组合、在线字幕搜索或 PiP／AirPlay 外部字幕输出。

使用项目原创本地视频、中文 SRT 和英文 VTT，通过真实 AVPlayer／MobileVLCKit、生产字幕会话及存储验证，不替换解码器。VLC 短样例沿用既有 ±0.8 秒检查容差，系统播放使用 ±0.4 秒；实际定位值另存报告。既有 1.7.0 的媒体服务器、4K／HDR 与长 GOP 边界保留，NAS 矩阵未在本版全部重跑。

本轮未推送、打标签或提交商店。
