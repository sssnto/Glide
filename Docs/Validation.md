# 验证记录

## 2026-09-24：单轨播放与缓冲进度

- 播放器用同一条可拖动轨道展示未加载、已缓冲和已播放区间；缓冲数据来自当前 `AVPlayerItem.loadedTimeRanges`，保留不连续区间，切换媒体或画质时清空旧范围。本地文件显示全段可用。辅助功能可读出具体缓冲起止时间。
- 手动拖到已缓冲区间时允许 0.25 秒定位容差，区间外仍精确定位；自动缓冲等待与首帧恢复策略保持原有设置。缓冲范围表示 AVPlayer 已加载的数据，不保证每一种编码在范围内都能零等待解码。
- 核心测试 46 项通过，iOS Release 构建通过；模拟器已验证本地演示媒体显示缓冲范围、刷片，以及暂停后拖动单轨定位。本地 Jellyfin fixture 的 1080p HLS 自动恢复、首帧和已缓冲区间回归通过；测试来源已清理。真实 NAS 弱网表现仍需真机验收。

真机建议分别用原画直放、1080p HLS 和离线影片检查：播放中观察浅色缓冲区是否增长；暂停后拖到浅色范围内、范围外及两段缓冲之间的空档；切换下一部和画质后确认旧缓冲范围消失。

2026-09-20，Xcode 26.3，iPhone 17 Pro / iOS 26.3 模拟器。

- Debug 构建成功，无应用编译警告。
- 6 个 Swift Testing 核心测试通过：URL 输入校验、代理前缀与查询编码、同源检查、DAV 命名空间／失败 propstat 过滤、损坏 XML、时长显示、目录分页范围约束（若干断言位于同一测试）。
- UIKit 手势端到端测试通过：横滑切换第二段视频，双指放大后读取持续的无障碍缩放值，锁定后横滑不切片，解锁并返回。
- 添加服务器输入校验 UI 测试通过。
- 用户授权的 Jellyfin 12.0.0 实服：HTTPS、账号认证成功，读取到 9 个媒体库；观察到普通文件夹、电影、剧集类型。
- 已保存的真实 Jellyfin 来源通过 UI 测试：媒体库 → 目录 → 刷新本目录 → 播放进入 playing 状态 → 暂停 → 返回目录。

- 本地 WebDAV fixture 的认证、PROPFIND、Range 播放及横屏可操作性测试通过；测试源在测试结束后删除。

测试没有把服务密码写入文件。真实服务的地址和媒体名称不记录在本文档中。

## 可重复的测试方式

核心测试：`swift test`。

常规 UI：Xcode Product → Test。需要联网来源的测试默认跳过。

真实服务测试：先在模拟器中手动连接 HTTPS Jellyfin，再为测试进程设置 `GLIDE_LIVE_TEST=1`，运行 `testConnectedServerDirectoryPlayback`。该测试会在用户已配置的第一台 HTTPS 服务器中播放一个视频并上报观看进度。

本地 WebDAV 测试：先运行 `python3 Scripts/fixture_server.py`（依赖 ffmpeg），再设置 `GLIDE_DAV_FIXTURE=1`，运行 `testWebDAVRangePlaybackAndLandscape`。测试账号仅为本地 fixture 的 demo/demo，不使用个人服务凭据。

## 尚未覆盖

物理 iPhone / iPad、弱网压力、长时间播放、所有 Jellyfin 编解码组合、第三方 NAS 的 WebDAV 实现，以及外挂字幕／HDR / Dolby 特性。

## 2026-09-24：首帧启动速度

- 点选已显示的视频后立即进入播放器；若当前目录还有未加载页，首帧出现后才在后台补齐刷看队列，避免目录枚举占用首帧前的请求。顺序和随机队列扩展均保留当前视频及已走过的顺序。
- 播放启动使用当前列表已有的续播进度，避免首帧前额外读取一次服务器进度。远端进度仍在浏览目录时随 Jellyfin 列表获取；从较早保存的个人记录打开时，跨设备最新进度可能要等重新浏览该目录才能刷新。
- AVPlayer 继续使用自动缓冲等待和远程 15 秒前向缓冲；此前尝试的立即起播、2 秒缓冲和宽容差 seek 在真实播放录屏中导致 00:00 持续黑屏并触发恢复，已撤回。诊断保留 `resourceReadySeconds` 和 `playerReadySeconds`，可与 `firstFrameSeconds` 对照定位慢在服务器协商、资源准备还是解码/缓冲。
- 45 项核心测试与 iPhone 模拟器 `testSwipeZoomLockAndReturn` 通过。真实 Jellyfin 大目录、弱网、4K 转码与远端续播精度仍待真机验收。

## 2026-09-24：无法起播回归修复

- 用户录屏显示播放器停在 00:00、持续等待首帧，随后尝试自动转码；这与上次改动的起播参数有直接时间关联，但录屏不足以单独证明哪一项参数导致故障。撤回立即起播、2 秒前向缓冲与宽容差续播 seek，恢复 AVPlayer 自动缓冲等待、远程 15 秒缓冲目标与精确定位。继续保留已加载列表直接进入播放器、首帧后补齐目录队列、首帧前少一次远端进度请求。
- 首帧测试改为检查 `AVPlayerLayer.isReadyForDisplay` 经播放器暴露的状态，避免仅凭“暂停”按钮出现而误判视频成功显示。签名模拟器上的本地演示视频、Jellyfin fixture 的电影与剧集，以及自动恢复到 1080p HLS 后实际首帧测试均通过。剧集测试将控制栏自动隐藏延长到 8 秒，以稳定完成后续控制操作。真实 Jellyfin 冒烟测试选中了电影类型媒体库，旧测试仍预期家庭视频的“刷本目录”入口，因此未进入播放。45 项核心测试通过，iOS Release 构建通过。真实 NAS 上的原问题视频仍需新构建复测。

## 递归队列、模式、旋转与画质更新

- 17 个核心测试全部通过，增加了完整分页、递归目录边界、循环防护、取消、随机去重、历史返回、模式切换保留当前视频，以及原画／1080p 策略校验。
- 4 个相关界面／播放场景通过：手势切片与锁定；只有子目录包含视频的 WebDAV 根目录播放与横竖屏按钮；Jellyfin fixture 跨页递归队列、自然播完自动下一部、随机模式切换及历史返回、暂停状态下切换原画／1080p 且时间不变；真实 Jellyfin 切换 1080p 并实际播放。
- 真实服务验证了 1080p 转码链路；未穷举服务器中的所有编解码格式。小于 1080p 的源视频不强制放大。
- UI 测试来源的本机地址与 demo 账号只用于项目自带视频，清理步骤不移除用户的真实服务器。

## 媒体库视频平铺（2026-09-20）

- 模拟器构建运行成功；17 项 Core 测试通过。
- `testFlattenedLibraryVideos` 通过：父目录没有直接视频时仍同时显示文件夹与后代视频；强制两条一页的服务端返回能加载第三条；点选第三条封面进入对应视频；进入子目录、刷新、返回媒体库根层清空旧视频正常。
- `testWebDAVRangePlaybackAndLandscape` 通过：WebDAV 根目录仅含子目录，递归预览及播放、Range 请求和横竖屏切换兼容。
- 临时测试来源已移除，本地测试服务已停止。此轮新增平铺行为使用本地 Jellyfin 协议测试服务验证，未重新进行真实服务器播放验证。

## 原生视觉第一阶段（2026-09-21）

采用Quiet Cinema配色，更新媒体库卡片、横向目录、播放工具条、视频文字层级、来源连接引导与播放器次要状态。iPhone模拟器构建运行成功，已人工查看首页截图。

三项UI回归通过：`testAddSourceValidation`、`testFlattenedLibraryVideos`、`testSwipeZoomLockAndReturn`。覆盖无效地址提示、父目录后代视频分页与点选、目录返回、左右刷片、缩放和锁定返回。使用本地协议测试服务；本轮未重做真实服务器画质测试。随后补充空媒体库提示并隐藏根层无意义的视频搜索，重新构建验证。

iPad Pro 11-inch (M5) 模拟器构建、安装与运行成功。已查看实际截图：三列演示封面、播放工具条与底部入口完整显示，无可见重叠。此次为竖屏首页检查，未覆盖分屏/大字体的完整验收。

## 全范围搜索、收藏与继续观看（2026-09-21）

- iPhone模拟器构建、安装与运行通过。
- 21项Core测试通过：新增搜索范围/分页/编码、历史快照序列化不包含解析后的播放凭据、续播阈值与无效值、WebDAV刷新元数据保留已知时长。
- `testScopedSearchAndPersonalLibrary`通过：搜索到Fixture C、仅有一个匹配结果、播放队列1/1、保存收藏与中途进度、重启后仍可找到记录并续播、移除历史保留收藏、取消收藏后列表移除。
- `testFlattenedLibraryVideos`回归通过：父目录平铺、完整分页、点选对应视频、切换目录与返回根层清空旧结果。
- 新增界面测试使用本地Jellyfin协议测试桩；本轮未验证真实服务器搜索表现或跨设备同步。临时来源已移除，测试服务已停止。

## 2026-09-21：影视媒体展示与目录偏好

- SwiftPM 核心测试：29 项通过。新增媒体库类型/旧路径解码、元数据缺失、季集数字排序、源 ID 与音轨/字幕索引（含关闭和默认区分）；目录范围、排序与固定目录持久化测试一并通过。
- iPhone 17 Pro / iOS 26.3：构建成功。`testMovieAndTelevisionCatalog` 最终通过：电影详情、受保护海报、选择声音/字幕、参数断言、HLS 播放、关闭刷片/随机入口、节目季集排序、空季/切季、下一集、新旧详情接口回退。
- `testScopeSortAndPinnedDirectory` 通过：直接层/子目录切换后搜索一致、降序队列、目录固定/重启恢复/删除。前次点击来源面板关闭过早的测试等待已修正。
- 已修复真实图片加载后裁切区域之外仍拦截选季点击的问题，海报尺寸与命中范围现受限；带图片重跑影视端到端通过。
- 本地 fixture 清理测试最终通过；仅删除 localhost:8768 且名称含 Fixture 的测试来源，未删除个人服务器。最后影视测试创建的来源也在测试结束时移除。
- 最终 XCTest result：`test_sim_2026-09-21T03-52-08-203Z_pid6716_77275e6d.xcresult`；目录偏好 result：`test_sim_2026-09-21T03-43-40-139Z_pid6716_16f44220.xcresult`（XcodeBuildMCP 工作目录）。
- 截图：`Design/native-movie-details.png`、`Design/native-show-seasons.png`，均为虚构本地媒体，已人工查看。

验证边界：fixture 断言 PlaybackInfo 的版本/轨道/字幕烧录参数并返回本地 HLS，不是真实 Jellyfin 编码器；不能替代多音轨听感、ASS/PGS 字幕烧录和真机视频兼容性验收。本轮未重复访问个人服务器媒体、未验证 iPad 新页面；照片查看与图视频混排未实现。影视列表当前完整分页加载后展示，超大型片库仍需渐进加载优化。

## 2026-09-21：演职人员头像与相关媒体

- iPhone 模拟器构建成功；31 项核心测试全部通过，覆盖人员 ID/图片 tag 解码、缺失 ID、同名不同 ID、每页保留人员与用户过滤、空 ID 禁止查询。
- `testPersonPortraitAndRelatedMedia` 通过：人员卡片 → 相关媒体 → 加载下一页 → 节目详情 → 返回 → 同名另一人员的空结果。fixture 对 PersonIds/UserId/分页参数做断言，受保护头像成功显示；无头像显示占位图。初次运行遇到连接表单键盘焦点时机问题，增加等待/重试点击后完整流程通过。
- 结果包：`test_sim_2026-09-21T04-46-07-211Z_pid6716_9f79b199.xcresult`（XcodeBuildMCP 工作目录）。测试来源已移除，本地服务已停止。
- 截图 `Design/native-cast.png` 与 `Design/native-person-media.png` 已人工检查。测试服务用演示风景图验证图片加载，不是真人肖像。真实片库头像和作品关联依赖 Jellyfin 已有元数据；本轮未对个人服务器重复联调。


## 2026-09-21：布局、缓存、排序、恢复播放与离线

- iPhone 17 Pro / iOS 26.3 构建成功；34 项 SwiftPM 核心测试通过，新增排序查询/持久化、硬件能力配置、人员查询排除 Episode。
- `testCatalogPolishCacheAndOffline` 通过：长声音/字幕名独立选择，三个偏好行边界无重叠；评分/名称排序；详情回访不重复请求；结束并重启应用后元数据与海报请求数不增加；下载完成后本地播放不增加远程 stream 请求。结果包 `test_sim_2026-09-21T08-53-00-638Z_pid6716_4ee41951.xcresult`（该批恢复播放测试尚因来源面板过渡时机失败，随后单独重跑通过）。
- `testPersonPortraitAndRelatedMedia` 通过：带认证头像、人员过滤分页、节目入口及季集页、同名不同 ID。fixture 要求查询排除 Episode，避免回到单集平铺。结果包 `test_sim_2026-09-21T08-45-45-048Z_pid6716_ac240ffe.xcresult`。
- `testAutomaticPlaybackRecovery` 通过：故意让原始流返回 404，自动模式请求兼容 HLS 后实际开始播放，显示“服务器转码”及回退提示。结果包 `test_sim_2026-09-21T08-56-17-243Z_pid6716_0e623271.xcresult`。此前两次失败发生在来源面板打开/关闭的测试点击时机，补充等待后通过，不是播放断言失败。
- 已人工检查并保存 [长轨道布局截图](../Design/native-track-layout.png)，仅含本地虚构测试媒体。旧文档“影视列表完整加载”“无缓存/下载”等描述由本节和 Architecture 最新说明替代。

边界：本轮使用本地协议 fixture，未重新访问个人服务器验证原始问题文件；HLS 是预制演示流，不证明真实服务器实时转码性能。模拟器验证了磁盘缓存跨进程复用、前台下载和离线播放；未验证真机锁屏下载/系统后台唤醒、长影片网络波动、iPad 分屏/大字体及 4K/HDR10/Dolby Vision/AV1 实机解码。设备硬解检测和自动回退已实现，不等于全格式硬解承诺。离线仅支持默认 MP4/MOV/M4V 原文件，仍要求系统能解码，尚无 MKV 内核或离线转码打包。

最后重新编译并通过 `testCleanupLocalFixtures`：移除本轮本地测试来源，保留个人服务器；本地协议测试服务已停止。


## 2026-09-21：媒体库闪烁与播放器遮挡

- 构建通过。`testCatalogPolishCacheAndOffline` 增加单条一页的自动分页验证，确认第二页出现且加载状态结束；排序、缓存跨重启、离线播放回归通过。
- `testCompactPlayerControls` 通过：旋转按钮、播放按钮高度不超过 48 点、横屏进度条位于屏幕下方 40% 内、播放后自动隐藏、点击恢复和返回。已人工查看横竖屏截图。最初 app.screenshot 在程序旋转后产生截断截图，改用 XCUIScreen 截屏并同步模拟设备方向后图像正常。
- 结果：`test_sim_2026-09-21T13-37-45-841Z_pid6716_ee093eee.xcresult` 与 `test_sim_2026-09-21T13-42-36-721Z_pid6716_f7a706ac.xcresult`。本地测试来源已由测试移除，未修改个人服务器。
- 截图：`Design/native-player-compact-landscape.png`、`Design/native-player-compact-portrait.png`。模拟器和本地 fixture 验证，不代表已在用户手机与真实大媒体库重现验收。


## 2026-09-22：记录删除、标签与相似推荐

- 构建成功，35 项核心测试通过；新增标签解码、去重、标签/类型分离及分页请求范围验证。
- `testScopedSearchAndPersonalLibrary` 通过：经播放菜单收藏、保存历史、重启续播；长按删除播放记录保留收藏，取消收藏后重启两类列表均不重新出现。编辑入口与 onDelete 同用删除方法，不删除远程影片。
- `testTagsAndSimilarMedia` 通过：点击带中文与 & 的标签，读取同标签第二页并进入节目季集；返回后点击相似节目进入季集；推荐排除当前电影。首轮因测试使用“选择季”文案而非 detail.season 标识失败，改正定位后通过。
- 两个结果包为 `test_sim_2026-09-22T08-18-50-566Z_pid6716_975a55bb.xcresult`（删除通过）和 `test_sim_2026-09-22T08-22-18-955Z_pid6716_294defa5.xcresult`（标签推荐通过）。清理测试通过，本地测试来源已移除，保留个人服务器；本地 fixture 已停止。
- 截图 `Design/native-tags-similar.png` 已人工查看。验证使用本地协议 fixture；真实相似度结果取决于服务器元数据，本轮未访问个人媒体验证推荐质量。新增功能尚未上传，TestFlight 已安装版本仍为 0.1.0（2）。

## 2026-09-23：播放器设置菜单

- 将右上角 Menu + simultaneousGesture 改为按钮驱动的可滚动 popover；画质入口同步改为显式浮层。浮层打开时取消控制栏隐藏计时，播放状态变化也不能重新隐藏其锚点，关闭后恢复计时。
- 模拟器构建通过；testCompactPlayerControls 通过：点击打开、保持超过 3 秒、滚动并切换画面填充、关闭、横屏重新打开、关闭后播放自动隐藏及点击恢复。
- 首轮测试在浮层外滑动导致选项不可见，定位到设置列表后通过；未在用户真机重现原问题，不将代码中的手势/隐藏竞争认定为已证实的唯一根因。
- 结果：test_sim_2026-09-23T01-19-24-163Z_pid26840_5622fb16.xcresult。人工查看横屏设置截图，浮层完整可见。本次修复尚未上传 TestFlight。

## 2026-09-23：有声音、时间前进但无视频首帧

- 原 watchdog 仅检测时间停滞，音频时钟前进会持续重置超时，遗漏无视频帧故障。现在关联实际 AVPlayerLayer，在期望播放且 timeControlStatus 为 playing 时检查 isReadyForDisplay；连续超过 10 秒无画面，自动画质仅尝试一次 1080p 恢复。暂停/等待缓冲不累计此计时，原画模式与恢复失败显示错误及手动转码入口。
- VideoSurface 避免每次 SwiftUI 更新重复设置相同 player；恢复通知出现时显示控制栏。这里检测首帧就绪，并不分析像素：已输出的纯黑片段或首帧后的冻结不在本次检测范围。
- 本地 fixture 支持 GLIDE_BLACK_FRAME_FIXTURE=1：直放返回 60 秒 AAC-only MP4，时钟正常前进但没有视频；兼容转码返回有画面的 HLS。恢复测试通过，截图确认 00:12 处恢复图像，进度保留，显示服务器转码。正常切换/缩放/锁定及 fixture 清理通过，共 3 项。结果 test_sim_2026-09-23T01-30-56-261Z_pid26840_f42df2ce.xcresult。
- 首轮恢复已发生但控制栏隐藏使断言失败，补充恢复时显示控制栏后通过。该轮菜单测试滚动时演示短片自动换片导致不稳定，改为验证浮层停留后暂停再滚动。
- 图像 Design/native-black-frame-recovery.png 已人工查看。未读取用户问题文件，不能断言具体视频编码是根因；本轮证实并修复的是无视频首帧时遗漏恢复。尚未上传 TestFlight。
- Apple API 依据：https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay

## 2026-09-23：阶段一、二测试版

- 用户提供的脱敏诊断：0.2.0(3)、HEVC Main 10、`hev1`、3840×2160、10-bit、直放、无首帧事件、缓冲约4.6秒、失败、恢复0次。已作为谨慎直放判断与真实设备测试样本；无法仅凭它断言 HEVC 码流损坏或 Jellyfin 服务端错误。
- 40 项核心测试通过，包含兼容画质约束、进度冲突、语言匹配、诊断过滤、SRT/VTT 解析；iPhone 模拟器构建通过且无警告。UI 冒烟中播放器紧凑控制、设置与诊断、自动恢复和测试来源清理均通过。先前脚本前提不成立（记住1080p、对源面板完成按钮的假设）已修订并复测通过。
- 0.2.0 (4) Release 归档成功，已上传且 Apple 处理完成；App Store Connect 显示“缺少出口合规证明”，因此尚未分配测试群组。iPad 模拟器构建成功，启动因 CoreSimulator 服务响应问题未完成视觉核对。
- 真机验收尚未完成。画中画、AirPlay、不同 Jellyfin 转码能力、下载后台恢复与 iPad 分屏由 Docs/Testing/阶段一二用户测试计划.md 验证；不得将模拟器结果冒充真机结论。
# 2026-09-27：自动播放与底座选型

- 完成 [双内核选型](Player-Engine-Decision.md)：当前版本保持 AVPlayer + Jellyfin 自动转码；MobileVLCKit 是下一步集成对象，尚未宣称全格式直放。
- 默认播放优先原画。黑屏／解码失败时按需尝试兼容流和 1080p H.264/AAC；持续缓冲可跳过无法降低码率的重封装，最后降至 720p。播放器和详情页不再要求用户手动选择画质，保留音轨、字幕、版本及播放诊断。
- SwiftPM 核心测试 49 项通过；iOS Release 构建通过；iPhone 17 Pro 模拟器 `testAutomaticPlaybackRecovery` 通过：本地原始流返回 404，自动恢复到视频转码并显示首帧，缓存进度可见。测试使用正常模拟器签名；完全不签名构建不能完成本地测试来源的钥匙串写入。测试来源已移除，本地 fixture 已停止。
- 该 fixture 的 HLS 是预制视频，不能证明真实 Jellyfin 的转码启动耗时、4K HDR/Dolby Vision 解码、真实网络抖动和 MobileVLCKit 的性能；这些仍需真机与真实媒体验收。

## 2026-09-27：HEVC 视频首帧偏慢的自动恢复

- 用户提供的 1.0.1 (3) 诊断显示 `automatic → compatible → hd1080` 两次恢复，最后 1080p 转码成功。旧 `firstFrameSeconds` 只计最后一次尝试，不能代表点击到画面的总耗时；`observedBitrate` 是 AVPlayer 的网络实测吞吐量，并非文件码率。
- 直放时若音频播放而视频层连续 6 秒无首帧，直接跳到 1080p；若 Jellyfin 首次协商已声明不支持 DirectStream，也跳过兼容流协商。其余失败仍保留兼容尝试，避免将短暂网络错误误判为解码失败。
- 诊断 schema 2 新增 `totalFirstFrameSeconds`、各次 `attemptSeconds`，每次重试重置当前尝试耗时与输出参数；成功出画面后清除过期错误码，事件保留失败阶段与错误类别。未记录视频标题、URL 或鉴权令牌。
- 49 项核心测试通过；iOS Release 模拟器构建通过；iPhone 17 Pro 本地 AAC-only 视频 fixture 的 `testAutomaticPlaybackRecovery` 通过（1/1），请求记录只含原画和 1080p 两次 PlaybackInfo，且恢复后显示视频画面。结果：`/tmp/glide-playback-recovery-20260927.xcresult`。真实 NAS 的编码/服务器配置原因仍需真机回测确认。

## 2026-09-27：原画起播卡住 25 秒

- 1.0.1（4）真机诊断显示三次尝试分别耗时 25.0、0.1、10.3 秒；原画资源 0.03 秒即就绪，却始终没有首帧，最终触发通用 25 秒看门狗。随后兼容流协商失败，1080p 转码成功。`bufferingSeconds` 12.2 秒是跨尝试累积值，不等于全部起播等待。
- Jellyfin 原画资源已就绪但 8 秒仍未起播时，跳过无效的兼容流尝试并转 1080p；对首次直接起播卡住、随后转码成功的媒体，在本机记住该路线 24 小时，重播时直接请求 1080p。只对同一来源同一媒体生效，过期后重新探测原画。转码流原有缓冲策略保持不变。
- 首帧诊断现在要求当前 AVPlayerItem 已就绪且当前播放层有首帧；避免异步状态回调使 `playerReadySeconds` 晚于 `firstFrameSeconds`。这属于诊断准确性改进，不是转码启动的性能结论。
- 50 项核心测试通过，iOS Release 模拟器构建通过；慢原画本地 fixture 的 iPhone 17 Pro UI 回归通过（1/1）：首次只有原画和 1080p 两次 PlaybackInfo，重复播放仅新增一次 1080p 协商，两次均实际显示画面。最终结果：`/tmp/glide-slow-direct-final-20260927.xcresult`。真实 NAS 的 1080p 转码首帧仍约 10 秒，需新构建真机复测后再判断服务器或客户端哪一段可继续优化。

## 2026-09-28：VLC 刷看与播放器手势

- 引入 MobileVLCKit 3.7.3；Jellyfin 家庭视频刷看先走 VLC 原画，失败或超时自动回到 AVPlayer 与 Jellyfin 转码链路。电影、剧集保留原有续播；刷看不写本机播放记录，也不向 Jellyfin 发送播放进度。设置中提供视频信息与第三方许可。
- 进度条改为可交互的系统滑块，拖动时显示统一的已播与缓存区间；上下滑动切片，左右滑动切换 2×/正常速度，长按临时 2×。原亮度与音量滑动手势已移除。
- Swift Testing 50 项通过；iPhone 17 Pro 模拟器的 `testCombinedTimelineSeekAndBuffer`、`testScopedSearchAndPersonalLibrary`、`testSwipeZoomLockAndReturn` 均通过。远端用例使用本地 Jellyfin fixture，在视频信息中确认播放内核为 VLC；暂停后拖动进度条，已播放时间实际变化；播放后无历史，收藏独立保留。真机格式、网络与解码表现仍需 TestFlight 回归。
- 1.0.1（6）iOS Release 正式归档成功，包内 `CFBundleShortVersionString=1.0.1`、`CFBundleVersion=6`，含动态 `MobileVLCKit.framework`。CLI 上传曾在账户校验处返回 “Failed to Use Accounts”；Xcode Organizer 后续显示该归档已上传 Apple，时间 08:35。此版本不包含下面的手势修复。

## 2026-09-28：短点误触快进与准备画面提示

- 移除单指双击快退/快进手势以及单击等待双击失败的关系；短点直接切换控制栏。长按画面左/右半屏分别跳退/跳进设置的秒数；左右滑动切换 2×/正常速度保持不变。
- “正在准备画面”中央提示仅在尚未出首帧时显示。AVPlayer 或 VLC 在已出画面后报告短暂缓冲，不再用该提示遮挡正在播放的画面。
- Swift Testing 50 项通过。iPhone 17 Pro 模拟器 `testTapControlsAndHoldToSeek`、`testSwipeZoomLockAndReturn`、`testCombinedTimelineSeekAndBuffer` 均通过：暂停后短点控制栏不改变时间，长按左右半屏定位成功，刷片与进度条无回归。结果位于 `.build/DerivedData/Logs/Test/Test-Glide-2026.09.28_08-56-10-+0800.xcresult` 和 `Test-Glide-2026.09.28_09-00-08-+0800.xcresult`。
- 1.0.1（7）Release 归档成功，实际 Info.plist 版本/构建号为 1.0.1（7），签名验证通过。Xcode Organizer 的 TestFlight Internal Only 上传显示 “Uploaded to Apple”，上传时间 09:06，Build Number 7；Apple 处理及测试组分发尚未另行核对。

## 2026-09-28：刷看时轻点控制栏无响应

- 排查发现，UIKit 的平移识别器会抢先识别手指轻微移动的短点；距离不足以执行左右倍速或上下切片时，原逻辑直接忽略该手势。现在小于 25 pt 且未触发滑动操作的平移结束事件按轻点处理，短点仍由轻点识别器直接处理。
- iPhone 17 Pro 模拟器 `testPlayingSwipeThenTapShowsControls` 验证播放中连续左右滑动后轻点重新显示控制栏，以及带轻微位移的短触；`testTapControlsAndHoldToSeek` 验证长按左右半屏跳转没有回归。两项均通过：`.build/DerivedData/Logs/Test/Test-Glide-2026.09.28_09-36-27-+0800.xcresult`。Swift Testing 50 项通过，1.0.1（8）发布预检通过。
- 1.0.1（8）Release 归档已生成，实际包内版本/构建号为 1.0.1（8），签名验证通过。Xcode Organizer “TestFlight Internal Only” 上传显示 “Uploaded to Apple”，上传时间 09:46，Build Number 8。真实 Jellyfin 片源触摸表现需新构建实机回归。

## 2026-09-28：自动隐藏后无法唤起与锁图标方向

- 未锁定的操作按钮改用 `lock.open`，锁定后解锁按钮改用 `lock.fill`，图形准确反映当前状态。
- 控制台轻点识别移到播放器外层，覆盖自动隐藏后的画面；底层视频视图只处理双指轻点、滑动、捏合及长按。避免轻微位移被底层平移吞掉，且长按松手不会再被外层当作轻点隐藏控制台。
- iPhone 17 Pro 模拟器 `testIdleAutoHideThenTapShowsControls`、`testPlayingSwipeThenTapShowsControls`、`testTapControlsAndHoldToSeek` 三项通过：`.build/DerivedData/Logs/Test/Test-Glide-2026.09.28_10-48-26-+0800.xcresult`。
- Swift Testing 50 项通过；1.0.1（9）发布预检通过。Xcode Release 归档的实际 Info.plist 版本/构建号为 1.0.1（9），签名验证通过。
- Xcode Organizer “TestFlight Internal Only” 上传显示 “Uploaded to Apple”，上传时间 11:03，Build Number 9。Apple 后续处理和测试组实际可见仍待核对。

## 2026-09-30：统一原生播放器

- 所有视频统一使用 AVPlayer / AVPlayerLayer / AVKit；移除 MobileVLCKit 源码、动态框架、Pods 编译阶段、scheme 依赖与许可页面。保留工程与 workspace 两种打开方式。模拟器应用链接检查仅包含 Apple 系统库；Release 包内没有第三方播放器框架。
- 起播缓冲偏好为 2 秒，首帧后普通速度目标 15 秒，2× 目标 30 秒；同一进度条按系统实际 loadedTimeRanges 显示缓存。首帧增加 KVO 观察，短暂等待延迟 350 ms 确认，避免倍速／定位切换误计卡顿。缓冲目标不等于系统保证的实际缓存量，也不证明真实服务器起播耗时已经改善。
- 续播等待 item 就绪并完成定位后播放；连续定位取消旧请求并校验会话与 seek 标识。手动定位允许小幅容差；自动兼容恢复优先保留最近的定位目标。系统无法播放的 Jellyfin 下载文件可尝试在线兼容流，WebDAV 与断网文件仍受系统格式支持限制。
- `swift test`：52 项核心测试通过。Debug 模拟器构建与 generic iOS Release 构建通过；Release 验证使用 CODE_SIGNING_ALLOWED=NO，仅验证编译与链接，不代表已签名归档、上传或真机验收。
- iPhone 17 Pro / iOS 26.3.1 模拟器：`testCombinedTimelineSeekAndBuffer`、`testIdleAutoHideThenTapShowsControls`、`testSwipeZoomLockAndReturn`、`testAutomaticPlaybackRecovery` 四项分别通过。覆盖拖动进度、自动隐藏后唤出、上下刷片、左右倍速、放大后平移、锁定与返回，以及慢直放自动恢复到 HLS、实际缓存区间和重播仅新增一次兼容协商。
- 交互结果包：`test_sim_2026-09-30T02-09-47-915Z_pid64692_dc828ce5.xcresult`（进度与唤出两个用例通过）、`test_sim_2026-09-30T02-19-40-570Z_pid64692_96be8265.xcresult`（刷片／倍速／缩放／锁定通过）；最终恢复结果：`test_sim_2026-09-30T02-32-05-720Z_pid64692_05cec7dd.xcresult`（1/1 通过，无编译警告）。前两批中旧缓存断言与测试操作落在控件上导致的失败已修订；测试来源数量较多时改为滚动到添加／清理入口。
- 已人工查看 `Design/native-avplayer-recovery-20260930.png`，确认视频画面与合并缓存条可见。使用 localhost 模拟协议服务与预制 HLS；未访问私人媒体。真实 Jellyfin 转码耗时、4K / HDR / Dolby Vision、离线兼容性、画中画与 AirPlay 仍按 [原生播放器回归测试计划](Testing/原生播放器回归测试计划.md) 实机验收。
- `testCleanupLocalFixtures` 通过（1/1）：清理 localhost 测试来源，保留个人服务器；本地模拟服务已停止。测试计划和 README 已更新到原生方案，旧 VLC 计划标记为历史资料。
