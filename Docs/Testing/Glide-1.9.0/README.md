# Glide 1.9.0 开发验收

2026-10-20 实施，2026-10-21 补充真机验收，1.9.0（1），字幕导航与片段循环。范围见 [计划](../../Glide-1.9.0-Product-Plan-2026-10-20.md)，操作见 [体验步骤](User-Acceptance.md)。独立包已安装至 iPhone；真机发现的 VLC 片尾停顿修复后，相同包连续两轮 19 项检查通过。最终源码相关模拟器回归、149 项核心测试、Release 归档、签名与符号检查均已通过。[构建清单](Build-Validation-2026-10-20.json)保存实际状态与源码哈希。本轮不推送、打标签或提交商店。

## 实现

主字幕全文来自当前外部 SRT／VTT，列表身份在文档加载时生成，搜索保留身份、重复台词分别显示。搜索在输入后 200 毫秒执行，使用惰性列表，按媒体时钟与字幕偏移二分查找当前句；滚动后暂停跟随，可重新开启。点击定位保留播放／暂停意图，单句重播则播放到对应偏移后的句尾并暂停。

循环属于生产 PlaybackController，使用两种实际内核的媒体时钟；区间外手动定位、切片、关闭清除区间，同片重试／切内核保留。循环时片头片尾跳过与自动下一条让位，停止或定位失败不会无限重试。循环不是逐帧无缝播放；0.5 秒最短区间是输入边界，不代表所有文件／倍速下都能无缝回环。

VLC 在 EOF 后可能不再接受普通定位，因此文件结尾的回环重新打开同一视频，在 A 点继续，保留循环和播放意图。这条路径有加载间隔。结束判断与时钟都直接读取当前 libVLC 输入，避免依赖 VLCKit 缓存的结束状态；保留结束事件去重与同片回环重新加载。中段回环仍使用实际定位，句尾暂停受媒体时钟采样间隔影响，实际停止值单独记录。

两路外部字幕样式以版本化数据保存在本机，首次读取迁移旧字号偏好。编辑预览与实际字幕共用渲染组件；描边绘制在 Canvas 内，避免产生多个供 VoiceOver 重复朗读的文字节点。颜色、字号、描边和背景透明度都有范围限制及缺损数据回退。外部字幕位置设置继续保留。

## 已执行结果

| 检查 | 结果与证据 |
| --- | --- |
| 核心 | 2026-10-21 复测 149 项通过（142 Swift Testing + 7 XCTest），新增 8 项，覆盖无效循环边界、暂停／定位条件、偏移裁剪、重复台词身份、重叠字幕、2 万句查询、样式迁移与持久编码。[日志](Logs/Core-Final-2026-10-21.log)。仅核心包使用 Swift 6，不代表全应用迁移。 |
| 10 月 20 日完整回归 | 修复前源码同批 3 个正常界面用例通过：台词搜索／定位／样式预览／修改保留／重置／循环开关、原有双字幕偏移与重开／取消导入、1080p VLC 点按定位／继续播放／暂停／内核确认。[摘要](UI-Controls-Final-Summary.json)、[日志](Logs/UI-Controls-Final.log)。双字幕文字像素 OCR 与时间轴间距检查通过。另批 3 个生产流程用例通过，无失败／跳过，见 [摘要](UI-Production-Final-Summary.json)与[日志](Logs/UI-Production-Final.log)。这些历史结果不代表 10 月 21 日修复后的重新执行。 |
| 10 月 21 日修复后回归 | 最终源码 4 个相关用例通过：字幕界面、字幕循环生产流程、双字幕生产流程，以及 1080p VLC 点按定位／继续播放／暂停／内核确认。首批 3 通过、0 失败、1 跳过：[摘要](UI-Native-State-2026-10-21-Summary.json)、[日志](Logs/UI-Native-State-2026-10-21.log)；1080p 因遗漏 `GLIDE_FORMAT_FIXTURES` 标志被跳过，补回测试环境后独立重跑 1 通过、0 失败、0 跳过：[摘要](UI-1080p-Final-2026-10-21-Summary.json)、[日志](Logs/UI-1080p-Final-2026-10-21.log)。未改产品断言。模拟器为 iPad Pro 12.9 第六代、iOS 26.3.1。 |
| 字幕导航与循环 | 最终源码真实 AVPlayer／VLC 验证偏移定位、单句停止、中段 2× 三次回环、暂停冻结、越界退出、无效 B、区间内定位、同片切内核保留、片尾与跳过／下一条优先级、切片和关闭清理，共 19 项。[10 月 21 日模拟器原始报告](Study-iPad-Final-2026-10-21.json)。不替换解码器。 |
| 双字幕／Emby | 既有双字幕 18 项在 10 月 21 日重新通过，[报告](Dual-iPad-Final-2026-10-21.json)。Emby 官方 4.9.3.0 原创服务在 10 月 20 日回归 14 项通过，[报告](Emby-iPad-Final.json)；其中 13 项真实服务／原生播放，1 项明确注入解码器结果的控制器契约，不能把该项计为真实解码。10 月 21 日仅调整本地 VLC 结束判断，未重新执行 Emby 服务矩阵。配置与限制沿用 [1.7.0 记录](../Glide-1.7.0/README.md)。 |
| iPhone | 独立「Glide NAS 验证」1.9.0（1）已安装并启动，iPhone 13 Pro Max／iOS 27.0。最终源码相同包连续两轮 19 项通过，使用真实 AVPlayer／VLC，无解码器替换：[首轮](Study-iPhone-First-Pass-2026-10-21.json)、[最终复核](Study-iPhone-Final-2026-10-21.json)。最终报告时间为 2026-10-21 00:31:18 UTC；两内核中段均 3 次、片尾均 2 次回环，队列完成计数均为 0。[构建](Logs/Device-Build-Final-2026-10-21.log)、[安装](Logs/Device-Install-Final-2026-10-21.log)、[启动](Logs/Device-Launch-Final-2026-10-21.log)。 |
| Release | 10 月 21 日最终源码重新归档、发布预检、deep／strict 签名和应用／MobileVLCKit dSYM UUID 检查通过，无需补修符号。应用 UUID 为 `9580696A-95C0-3876-97C3-4DC1BD8AF94C`，MobileVLCKit 为 `99DC0B74-A3D1-3ED3-AC1F-2B8FC6A452A3`。[符号报告](Archive-Symbols-2026-10-21.json)、[归档](Logs/Release-Archive-Final-2026-10-21.log)、[预检](Logs/Release-Preflight-2026-10-21.log)、[签名](Logs/Release-Signature-2026-10-21.log)。Release 不含字幕 QA 启动入口，尚未上传商店。 |

[台词搜索](Screenshots/Transcript-Search.png)、[样式预览](Screenshots/Appearance-Preview.png)、[循环面板](Screenshots/Loop-Controls.png)与[双字幕回归](Screenshots/Bilingual-Regression.png)为 10 月 20 日正常界面截图，已逐张检查；10 月 21 日未修改界面实现，并重新通过字幕界面用例。UIKit 仍在原生 Menu 流程输出 `_UIReparentingView` 提示，保留在原始摘要，不屏蔽；本轮通过不代表所有系统版本均无问题。

[1080p 兼容播放截图](Screenshots/Compatibility-1080p.png)已复核，10 月 21 日相应用例再次通过。最终构建只有未链接 AppIntents 的元数据提取提示，本版未新增 AppIntents，未关闭编译诊断。测试模拟器已关闭，键盘偏好未改动。

句尾暂停使用媒体时钟采样，验证容差为 0.8 秒，原始报告保留实际停止值；字幕定位沿用系统 0.4 秒／VLC 0.8 秒容差。没有将输入区间和请求目标当成真实解码时间。首次完整 19 项通过的 [历史报告](Study-iPad-First-Pass.json)与最终报告分开。

## 已保留的问题与历史

- 2026-10-20 首次安装曾被 CoreDevice 4016 拒绝，[日志](Logs/Device-Install-Connectivity-Failure.log)保留；2026-10-21 重新连接后成功安装。首次真机检查仍在 VLC 片尾停住，实际时钟 11.524／12 秒、请求继续播放但回环次数为 0，见 [失败原件](Study-iPhone-EOF-Failure-2026-10-21.json)。改为读取 libVLC 原生结束状态后，相同真机连续两轮完整通过；未降低循环次数或放宽定位断言。[真机尝试记录](Physical-Attempt-History-2026-10-21.json)与[修复前源码快照](Source-Snapshot-2026-10-20.json)单独保留。该结果支持本路径修复，不推断覆盖所有编码与系统版本。
- 首轮描边叠加使字幕辅助功能节点类型变化，导致旧 StaticText 断言失败；当前使用 Canvas 描边并保留正文的文字节点。
- 首轮循环退出按钮位于滚动列表下方；改为面板底部固定出口，正常界面搜索、台词定位、样式预览和循环开关随后通过。
- VLC 文件末尾暂停且未再次上报结束，实际时钟为 11.906／12 秒，见 [原始报告](Study-Third-Tail-Failure.json)。对去重状态增加真实回退播放后重新启用的保护；效果仍以最终实测报告为准，不将推断写成所有封装的根因。
- 加入内核切换检查后，验证程序曾沿用上轮显式内核覆盖，错误地把后续系统播放当作兼容播放，见 [报告](Study-End-Rearm-First-Failure.json)；每轮改为独立控制器，并未修改产品默认内核选择。
- 后续系统播放在循环后手动定位，真实时间已到 8 秒而请求仍未结束，见 [报告](Study-End-Rearm-Second-Failure.json)；新旧定位取消顺序已调整，继续实测。
- 含同片切换的后续实测中，VLC 的片尾定位真实时钟已到 10 秒，但画面计数低于定位前，导致“必须更大”的判断不能完成，见 [报告](Study-Seek-Ordering-Failure.json)。改为要求正数且已变化，兼容定位后统计重置；这一处理仍保留真实时钟容差和稳定观察，不用请求目标伪造实际时间。
- 后续画面计数修正仍未独立解决片尾回环，见 [失败报告](Study-Counter-Reset-Failure.json)。最终增加 EOF 重新打开同片后，两轮完整生产流程通过。原有结束标记重新启用与画面计数保护均不单独被描述为已证明的根因修复。
- 新增三个字幕控制入口后，旧自动化在惰性行尚未加载时直接读取 frame；设置内核选项也被推到可视区外。改为先确认存在并滚动，不放宽播放／偏移断言。[历史尝试汇总](UI-Attempt-History.json)保留原始结果。

## 支持边界

全文与单句操作只适用于客户端能读取的外部主字幕，不提取内嵌、ASS／图形或服务器烧录字幕全文。样式不改变这些外部渲染路径。PiP／AirPlay 字幕与系统输出、HDR／4K、长 GOP、NAS 长播和其他格式矩阵不在本轮完整重跑范围。计时与定位实测不能替代人工听音和全部设备验收。

实现参考 [Apple ScrollViewReader](https://developer.apple.com/documentation/swiftui/scrollviewreader)、[Canvas](https://developer.apple.com/documentation/swiftui/canvas) 与 [libVLC 3.x 状态接口](https://github.com/videolan/vlc-3.0/blob/master/include/vlc/libvlc_media_player.h)，支持项目既有 iOS 17 起点。原生状态枚举同时核对本地固定 SDK 的 `Headers/vlc/libvlc_media.h`，未更换依赖二进制。
