# Glide 1.5.1 字幕验收

2026-10-20。构建 **1.5.1（2）**。版本范围见 [产品计划](../../Glide-1.5.1-Product-Plan-2026-10-20.md)。本目录仅记录 1.5.1 实际执行结果，1.5.0 的长播、恢复和品牌 NAS 缺项仍保留在原记录中。未提交商店审核。

## 实现与范围

本地授权目录和 SMB 在当前视频的同目录匹配 UTF-8 SRT/VTT。文件名匹配准确的视频主名，并识别语言／强制字幕等后缀。唯一候选可自动使用；多候选仅在语言偏好唯一命中时自动选中。全局字幕偏好为关闭时跳过自动选择，当前视频的手动选择优先。

字幕菜单提供同目录候选，播放设置中可调整延迟、查看文件名、关闭字幕和清除当前视频记忆。手动导入保留原有 2 MB 限制，形成受管理的本机副本；关闭后重启仍可从字幕菜单重新启用该副本。Jellyfin／WebDAV 沿用手动导入。

记忆使用独立、可恢复的快照，不改动片库快照格式。键包含来源 UUID、协议、共享根、账号／域和媒体路径，经 SHA-256 生成本机键；本地使用授权书签或受管理目录标识，不依赖会随应用更新变化的沙盒绝对路径。管理副本使用随机 UUID 文件名。移除来源或删除导入的视频副本时清理相应字幕记忆。导入副本回收保留当前与上次有效快照引用的文件。

本地／SMB 视频大小或修改时间变化时停止恢复旧选择；同目录字幕每次恢复重新读取并校验内容摘要，删除、修改或副本损坏会提示重新选择。该规则不是完整视频内容校验，不能识别同时保持视频大小与修改时间的所有内容替换。外挂字幕使用播放器实际时间和保存的延迟进行显示。

## 已执行结果

| 检查 | 当前结果 |
| --- | --- |
| 核心测试 | **117 项通过，0 失败**：110 Swift Testing + 7 XCTest，其中新增 10 项字幕测试，覆盖匹配、编码、边界、管理副本、备份、身份和跨内核轨道恢复。 |
| Swift 6 | Core、生产 SMB provider、新字幕来源及会话服务通过 complete concurrency／arm64 iOS 17 simulator 类型检查，使用最小应用依赖桩；不代表全应用 Swift 6 迁移。 |
| 应用内检查 | iPad Pro 12.9 第六代、iOS 26.3.1 **模拟器**最终构建：12 项本地检查通过，见 [原始报告](Subtitle-Session-iPad-2026-10-20.json)。覆盖两个内核的字幕定位／延迟、关闭／清除、导入副本重新启用、失效和取消隔离。 |
| 正常界面 | **5 项定向界面用例通过**：重启记忆／延迟／关闭，系统／本地 VLC／SMB 外挂字幕像素与 OCR，关闭后重启再启用导入副本，原生音轨／字幕选择，SMB 简体 ASS／繁体缺失字体回退 ASS／内嵌 SRT。见 [界面记录](UI-Regression-iPad-2026-10-20.json)及 [截图目录](Screenshots/)。前两项先通过，增加导入副本重新启用后重跑后三项；最终应用内检查再次覆盖字幕状态与两个内核的时钟逻辑。 |
| iPhone | 独立「Glide NAS 验证」**1.5.1（2）**：iPhone 13 Pro Max、iOS 27.0，**13 项通过**，包含生产 SMB 流式播放／同目录字幕／定位，见 [原始报告](Subtitle-Session-iPhone-2026-10-20.json)。该 SMB 为 Mac 上创建的原创样例只读 Samba 服务。 |
| 归档 | Release 归档成功，发布预检与严格签名校验通过；应用及 MobileVLCKit 的 dSYM UUID 匹配，见 [符号记录](Archive-Symbols-2026-10-20.json)。 |

版本、源码摘要、检查范围与设备汇总见 [构建验收记录](Build-Validation-2026-10-20.json)，核心测试原始日志见 [Core-Final.log](Logs/Core-Final.log)。

## 复现

核心测试：`swift test --jobs 2 --scratch-path /tmp/Glide151/CoreBuild`。

Swift 6 类型检查使用 [最小应用依赖桩](Harness/SubtitleCompileHarness.swift)，覆盖 Core、生产 `PlaybackResource`、`SMBSourceProvider`、`SubtitleSource` 与 `SubtitleSession`，桥接真实 SMB 头文件；依赖桩仅替代应用外围依赖，不用于运行验收。

独立验证包的 `--glide-subtitle-probe` 使用应用内原创演示视频，创建专用 `SubtitleFixture` 目录并运行生产控制器。增加 `--glide-subtitle-smb-probe -glideSMBFixtureAddress 127.0.0.1:1445` 测试固定只读 Samba 的 `media/字幕样例`；iPhone 使用当前 Mac 局域网地址的 1449 端口。测试账号为此前创建的假账号 `glide`／`glide150-fixture`。

正常界面用例使用 `--glide-subtitle-fixture` 或 `--glide-subtitle-smb-fixture`。`--glide-subtitle-reset` 只清理该专用验证来源的字幕记忆，重启恢复步骤会移除此参数。所有验证入口仅在 Debug／CompatibilityQA 编译，正式 Release 中不启用。

## 本轮边界

- iPhone 使用实际物理设备；iPad 记录为模拟器，未补记成实体 iPad 验收。SMB 服务是 Mac 上的原创样例 Samba，未覆盖各品牌 NAS 及其休眠唤醒。
- 本轮未重跑 1.5.0 的完整长播／内存／温升项目，不将旧记录当作 1.5.1 的新结果。外挂字幕在应用画面叠加，PiP／AirPlay 不包含字幕。
- 真机最终报告取得后，尝试回到正常片库时设备再次锁定；该操作被 iOS 拒绝。没有重装，最终构建和已保存的 13 项通过报告保留；用户可直接重新打开验证应用。
- 界面测试曾遇到样例未安装、目录扫描时点按偏移、iPad 弹出菜单遮挡、20 秒样例播完，以及 OCR 将“幕”误识别成“墓”。修正验证操作后分别重跑；失败尝试不计入通过数量。中文像素同时保留截图供人工核对，OCR 限定字幕区域并允许前五个字符识别候选。
