# Glide 1.3.0 本地兼容内核验收

后续构建 1.3.0（2）针对用户报告的中文字幕方框新增字体回退；专项结果见 [中文字幕修复验证](Glide-1.3.0-CJK-subtitles-2026-10-15.md)。下文保留（1）的历史验收范围，原 ASS 样例仅含英文。

日期：2026-10-15。开发版本 1.3.0（1），未发布；规格见 [本地兼容播放](../Glide-1.3.0-Functional-Spec.md)。固定 MobileVLCKit 3.7.3，所有素材均为原创合成样例，没有真实用户片源。各轮通过记录集中在 [验收索引](Glide-1.3.0-validation-summary.json)。结果按独立实验、主应用界面、主应用真机控制器分别记录。

## 真机结果

设备为 iPhone 13 Pro Max、iOS 27.0（24A437）。使用独立 Bundle ID，不覆盖用户手机上的正式 Glide。

| 范围 | 实际结果 | 证据 |
| --- | --- | --- |
| 独立实验 50 次打开／关闭 | 50 次均出画面并完成旧会话释放；首帧中位 0.528 秒，范围 0.420–0.535 秒 | [长播数据](Glide-1.3.0-physical-endurance.json) |
| 独立实验 1080p 长播 | 前台活跃 1800.59 秒，累计 43295 张 displayedPictures；热状态采样均为 nominal | 同上 |
| 独立实验内存 | 50 次关闭后 RSS 57.66 → 58.29 MB，差 0.64 MB；长播采样 51.43–76.87 MB，末次 61.49 MB | 同上；不是完整泄漏分析或功耗测量 |
| 主应用控制器／画面承载 | 6 项通过：三类格式出画面，1080p 暂停定位／轨道／倍速，系统 ↔ 兼容切换保留暂停与位置，系统失败后兼容重试 | [主应用真机 JSON](Glide-1.3.0-physical-main-probe.json) |
| 主应用真机 XCTest | 两次均在与 IDE 建立连接前退出，code 74；没有运行到设置页操作用例 | `/tmp/Glide130/Physical-Integration-R1.xcresult`、`Physical-Integration-R2.xcresult` |

长播静音，人工听音未验证；播放器 stop 返回耗时与底层彻底销毁耗时不能混用。50 次测试同时等待旧会话清理，RSS 变化只表示这组有限采样没有持续累积，不证明永不泄漏。长播程序构建早于最终主应用暂停准备和格式检查修订；主应用最终控制器另由 `CompatibilityQAProbe` 验收，不能把 30 分钟结果写成最终 PlayerView 的长播。

真机主应用验证使用 DEBUG 中的 `--glide-compatibility-probe`：固定读取 QA 沙盒素材，通过生产 `PlaybackController`、`VideoSurface` 和共享适配器执行流程，原子写出 `compatibility-main-probe.json`。最终构建测得：暂停定位 30.000 秒，恢复推进至 33.012 秒，双向切换均保持 4.000 秒。它验证实际出画面、时钟、选择与切换，不代替设置页手势和字幕屏幕 OCR。

## 主应用模拟器与回归

专用 iPhone QA 模拟器，iOS 27.0。通过项目及其构建范围分轮记录；中途失败保留并说明修订。

- R3：系统播放失败后选择兼容，实际出画面与所选内核检查通过。
- R4：暂停状态从系统切到 VLC、再切回系统，位置误差不超过 1 秒，队列下一条继续沿用偏好，通过。
- R5：MKV、AVI、改后缀 MKV 的主应用画面、VLC 诊断及脱敏检查通过；同轮短样片结束进入下一条导致字幕 OCR 用例失败。
- R6：字幕用例从暂停状态起播并定位到有字幕区间，第二音轨选择、ASS 实际文字识别、关闭后文字消失通过。图像：[显示字幕](Glide-1.3.0-ASS-visible.png)、[关闭字幕](Glide-1.3.0-ASS-disabled.png)。
- R8：原生多音轨／字幕选择、字幕关闭与格式信息回归通过。短样片使用 DEBUG 暂停起播以避免自动进入下一条。
- R14：使用新进度控件，明确指定 AVPlayer 的原生拖动回归通过。
- R16：原生 MP4／HEVC MP4／MKV／AVI 的 4 文件格式基线与诊断流程通过。
- R16：1080p 实际拖动至约 30 秒、保持暂停、恢复后推进至 33–45 秒、再次暂停与兼容内核选中检查通过。
- R17：原生改后缀／截断／纯音频／多轨 4 文件异常矩阵通过。
- R18：采用稳定轨道 ID 后，最终进度控件上的 ASS 起播、音轨选择、字幕 OCR 显隐复测通过。
- R20：采用模拟器本地签名后，Jellyfin 原始流失败 → 兼容流／转码恢复 → 实际出画面、原生 PiP 控件与本地 VLC 偏好隔离回归通过。

原生 8 文件逐项结果见 [基线 JSON](Glide-1.3.0-native-format-results.json)，格式用例通过包括合理拒绝不支持的文件，不表示 8 文件都能由系统播放。[1080p 暂停画面](Glide-1.3.0-1080p-paused.png)取自主应用 R16。

专用 iPad mini（A17 Pro）iOS 27.0 模拟器中，同一主应用控制器的 6 项验证通过，实际暂停定位为 30.000 秒，恢复至 33.434 秒，双向切换均为 4.000 秒；见 [iPad 模拟器结果](Glide-1.3.0-ipad-simulator-probe.json)。随后 iPad 的主应用 UI 用例 `testNativeFailureCanRetryWithCompatibility` 通过（`/tmp/Glide130/IPad-Integration-R1.xcresult`），覆盖实际失败卡、兼容出画面与设置页所选状态。这不代替 iPad 真机。

本轮核心测试 **90 项通过**：86 项 Swift Testing 和 4 项 XCTest。使用 `/tmp/Glide130` 内的模块／SwiftPM 缓存重跑成功；日志 `/tmp/Glide130-core-retry.log`。核心测试包括本地偏好不能将远程或带认证头资源送给 VLC 的策略；不会据此宣称真实服务器全量通过。

## 发现与修订

1. 初次主应用接入只修改自定义渲染 view 的 layer.frame，内部 drawable 保持零尺寸。改为设置 UIView.frame 和 transform，正常起播回归通过。
2. 家庭目录刷看原本有意忽略观看进度；内核切换复用打开流程时也丢失位置。切换现在明确作为同一视频恢复，保存暂停意图与时间。
3. VLC 元数据 ready 早于视频输出建立。冷启动暂停场景现在先静音准备首帧，再提交等待中的定位；定位等待 seekable，保留最新用户意图。
4. 失败卡的重试点击可能同时触发父层轻点隐藏控制。增加短暂抑制并保留控件显示。
5. 1080p UI 拖动回归暴露了原 UISlider 跟踪结束后仍发送变化值的问题。早期 R6–R13 未稳定落到目标；R14 后生产进度条改为直接追踪触摸位置的 UIControl，保留缓冲区绘制、44 点触摸区域和可调节无障碍操作，拖动期间使用用户目标值。
6. VLC SDK 的缓存状态可能晚于实际播放时钟，播放按钮曾显示错误操作。快照优先使用原生 isPlaying，按钮按用户播放意图显示。R16 恢复／暂停回归通过。

R1–R19 中的失败和测试修订保留在 `/tmp/Glide130/Integration-R*.xcresult`；它们不算最终验收通过。独立实验 R28 是先前历史结果，见 [ASS 实验记录](CompatibilityLab-ASS-2026-10-15.md)。

网络用例 R18／R19 未通过：初次保留测试来源但丢失钥匙串，重认证后仍因未签名包无法读写钥匙串而失败。固定本机 DEBUG fixture 增加重新认证，最终以 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 使用模拟器本地签名，R20 通过。没有向凭据服务增加绕过。

## 构建与依赖

官方归档及源码固定在 [依赖锁定](../../Dependencies/MobileVLCKit.json)和[源码材料清单](../Dependencies/MobileVLCKit-3.7.3-sources.json)。SDK 准备脚本校验 SHA256，裁剪真机 arm64、模拟器 arm64／x86_64；无解码源码修改。缓存复核与错误 SHA256 的拒绝检查通过，主应用和独立实验生成工程复用同一 SDK。

独立 QA 包已签名、安装并在手机正常启动；最终 Release 未签名归档完成于 `/tmp/Glide130/Glide-1.3.0-verified.xcarchive`。宿主机 `codesign --verify --deep --strict` 返回 `CSSMERR_TP_NOT_TRUSTED`，因此没有将该项写作通过；实际设备安装／启动与最终公开分发签名分别验收。归档是本机开发产物，不是已上传或可安装的 App Store 包。

最终 arm64 Release 应用未压缩约 41.3 MB，内嵌兼容 framework 约 36.0 MB；[包体审计](Glide-1.3.0-size-audit.json)记录实际字节数。这不是 IPA 或 App Store 下载体积。

`release_preflight.py` 仅静态检查版本、站点与延期收费入口，不等于真实设备、组件分发或 App Store 审核通过。

## 仍保留的边界

- 仅无请求头的本地 file URL 可选兼容内核；Jellyfin 在线流与 WebDAV 保持原生。WebDAV 不增加新能力。
- VLC 的 PiP、AirPlay、原生时间轴缩略图、网络随机读取、HDR／杜比／多声道输出没有完整实现与实测支持声明。
- 已验证普通内嵌 ASS，不外推为所有复杂特效、字体附件或 PGS／SUP 已通过。
- iPad 真机、真实用户片源、人工听音、外部输出和完整功耗／泄漏专项仍待验证。
- 已附基础组件声明、LGPL 文本、固定源码与补丁引用；完整传递组件归属、对应源码提供方式与正式分发复核未关闭，上架前必须完成。
