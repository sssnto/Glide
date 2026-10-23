# Glide 1.6.0 开发验收

2026-10-20，1.6.0（1）。本轮开发验收通过，未提交商店；范围见 [版本计划](../../Glide-1.6.0-Product-Plan-2026-10-20.md)。

## 实现

链接入口在片库顶部及媒体来源页。独立可恢复快照保存名称、主机、UUID 和媒体修订标识；完整 URL 与请求头使用设备 Keychain。添加／编辑在链接列表内导航，避免与系统长按菜单叠加弹层。完整地址或请求头变化时默认生成新身份；用户确认仍是同一视频并开启保留选项后才保留旧身份。仅改名称保持身份。旧记录不能打开被替换的新内容。删除链接同时移除钥匙串与对应本机记录。

STRM 手动导入只接受 64 KiB 以内 UTF-8 文本，含一条绝对 HTTP(S) 地址；后台分块读取，支持任务取消。地址上限 16 KiB；请求头上限 8 KiB／10 个，禁止控制字符、重复名称和播放器管理的传输字段。带请求头的渐进式视频复用 Range loader，拒绝跨来源重定向；HLS 自定义头不纳入本版。

跳过默认显示按钮，自动跳过需用户启用。提示独立观察进度，减少主界面高频刷新的范围；按钮位于控制层上方，主操作与取消均至少 44 点高；点击跳过不会同时触发画面控件显隐。规则按视频或 Jellyfin 节目保存，身份含来源、根与账号。手动区间覆盖同类服务器区间；时间错误、未知时长和超出时长的标记不用于跳过。暂停保留暂停意图，定位期间禁用跳过；自动模式每段本次只执行一次，回拖不反复跳过。退出或切换时取消旧片段请求，回调有代际隔离。

Jellyfin 使用真实 MediaSegments 接口结构。受控服务仅生成原创视频及假标记，用于客户端契约验收，不代表对所有实际服务器／插件完成验证。缺接口、无权限或片段不可读时继续播放并保留手动规则。

## 已执行结果

| 检查 | 结果 |
| --- | --- |
| 核心 | 125 项通过：118 Swift Testing + 7 XCTest，新增 8 项链接／STRM／跳过核心测试。见 [日志](Logs/Core-Final.log)。 |
| Swift 6 | Core、生产 SMB／字幕／链接／跳过服务与真实桥接头通过 complete concurrency／arm64 iOS 17 simulator 类型检查。[最小外围依赖桩](Harness/LinkSkipCompileHarness.swift)替代应用外围依赖；不代表全应用 Swift 6 迁移。 |
| 应用内 | 最终源码的 iPad Pro 12.9 第六代、iOS 26.3.1 模拟器：12 项通过。[原始报告](Link-Skip-iPad-2026-10-20.json)覆盖 STRM、Keychain、HTTP 认证与定位、HLS、手动／自动跳过、节目／账号隔离、Jellyfin 片段与缺接口回退、取消与删除。 |
| 正常界面 | 最终源码 3 项通过：链接增删改／非法输入／手动跳过／重启恢复清除，应用内验证＋长按编辑，原生轨道与媒体信息。[结果摘要](UI-Final-Summary-2026-10-20.json)、[日志](Logs/UI-Final.log)、[截图](Screenshots/Rule-Restored.png)。 |
| iPhone | iPhone 13 Pro Max、iOS 27.0，最终 1.6.0（1）独立包安装成功；12 项通过，2026-10-20 12:31:55（北京时间）。[最终原始报告](Link-Skip-iPhone-2026-10-20.json)，含使用有效凭据的重定向拒绝验证。此前报告作为[界面修订前历史记录](Link-Skip-iPhone-Pre-UI-2026-10-20.json)保留。 |
| 归档 | 最终 Release 归档、deep／strict 签名校验与发布预检通过。应用及 MobileVLCKit dSYM UUID 匹配，见[符号记录](Archive-Symbols-2026-10-20.json)与[预检日志](Logs/Release-Preflight.log)。未上传。 |

## 复现与边界

swift test --jobs 2 运行核心回归。python3 Scripts/link_skip_fixture_server.py 启动 127.0.0.1:8770 的原创 HTTP／HLS／Jellyfin 契约样例。--bind 和 --port 可指定仅供 iPhone 使用的局域网监听，样例无私人视频和真实凭据。

独立验证包的 --glide-link-skip-probe 运行生产控制器、Keychain、存储和片段服务。-glideLinkFixtureAddress http://Mac局域网地址:8771 用于真机。所有此类入口均仅存在于 Debug／CompatibilityQA，Release 不启用。正常界面测试使用 --glide-link-fixture 切回该独立包的演示片库。

本轮未覆盖有效公网证书的 HTTPS 端到端、实体 iPad、第三方 Files 云端占位文件、带认证的 HLS、NAS 自动 STRM 扫描或 IPTV。HTTPS 沿用系统 TLS 校验，未添加证书绕过。1.5.0／1.5.1 的旧长播、品牌 NAS 和字幕记录保留为历史结果。

## 手动体验

在独立「Glide NAS 验证」的片库顶部点链接图标，或从媒体来源进入「链接与 STRM」。添加实际视频地址或手动导入 STRM；保存的链接可左滑或长按编辑／删除。更新过期签名时，确认仍是同一视频再开启「更新地址时保留观看设置」。

播放时点右上角「… → 片头片尾」，填写秒数并保存。默认在区间内显示跳过按钮；开启自动跳过后仅在播放状态执行。Jellyfin 剧集可选择共用节目规则，服务器有标记时会自动读取。

Mac 的原创局域网样例可用命令 `python3 Scripts/link_skip_fixture_server.py --bind Mac局域网IP --port 8771` 临时启动；手机同网并允许本地网络后，输入 `http://Mac局域网IP:8771/sample.mp4`。这是测试服务，Mac 休眠或服务退出后样例不可用。

最终 UI 三项实际通过，MCP 传输层在 300 秒超时；已直接核对 Xcode 原始日志和 xcresult 的 3 passed／0 failed，未把传输超时当作应用失败，也未隐去此前失败。迭代中的触控冲突、编辑弹层、控件定位／滚动问题已分别修订后重跑。

最终 UI 结果保留一条原生音轨 Menu 打开时产生的 `_UIReparentingView` 运行期告警。轨道选择、关闭字幕、返回和媒体信息均通过；源码未发现向 UIHostingController.view 插入子视图的调用，本轮未确认其系统内部原因，未屏蔽该告警。

最终构建清单及源码 SHA-256 见 [Build Validation](Build-Validation-2026-10-20.json)。本次完成上述开发验收，不代表已上架或覆盖文中未验证边界的全部组合。
