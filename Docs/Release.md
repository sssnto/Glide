# TestFlight 发布记录

2026-09-22：已创建 Glide 应用记录（Apple ID 6814679647，Bundle ID com.songpeng.glide，Team FR9RTRV9BC）。

归档版本 0.1.0（1）上传成功；用户随后上传的 0.1.0（2）已加入“Glide 个人测试”内部组。后台确认指定本人账号已在 iPhone 安装构建 2。组创建时关闭自动分发，未建立公开链接或外部测试组，未提交 App Store 正式审核。

[TestFlight 测试组](https://appstoreconnect.apple.com/teams/7efd0ab9-7fe6-4bbf-8f78-519b6b1a3448/apps/6814679647/testflight/groups/828b5767-f4eb-4ac0-930e-4458cacffc23)

本地 App Store 签名 IPA：Releases/0.1.0-1/Glide.ipa。归档暂存 /tmp/Glide-TestFlight.xcarchive；打包工具缓存日志不进入项目，避免保存认证信息。

本轮后续新增的标签、相似推荐和记录编辑功能为本地代码变更，尚未纳入已安装的构建 2。

2026-09-23：本地代码准备 0.2.0 阶段一、二测试版，包含播放兼容/诊断与续播/字幕/离线/设置等改进。此记录只描述本地代码；发布状态以 App Store Connect 与实际构建为准。

2026-09-23：0.2.0（4）Release 归档、上传和 Apple 处理完成。用户已自行完成出口合规选择并将构建加入现有个人测试组，反馈当前测试没有问题。随后开始的阶段三 StoreKit、权益和隐私支持改动尚未打包或上传；测试组仍以 0.2.0（4）为准。

阶段三隐私站点源码已上传至 https://github.com/sssnto/glide-privacy，GitHub Pages 主分支已启用。用户已配置 `glide.sssnto.cn` DNS，HTTPS 证书正在申请；正式隐私政策 URL 仍须在证书生效后核验。

2026-09-23：App Store Connect 创建 Glide Pro Lifetime 非消耗型项目（`com.songpeng.glide.pro.lifetime`，Apple ID `6815111578`），中英文显示文案已保存。中国大陆基准价格 ¥18.00 已设置并核对；当前销售范围为 175 个国家或地区。审核截图及交易测试尚未完成，未添加以供审核。第三阶段本地版本为 0.3.0（5），购买开关关闭，未归档或上传。

2026-09-23：用户决定暂缓收费。已从当前 App 构建移除 Pro 页面和 StoreKit 源码引用，下载和个性化设置维持免费；App Store Connect 商品仍处于“准备提交”，不会随当前版本送审。`https://glide.sssnto.cn/privacy.html` 和 `/support.html` 已经通过 HTTPS 打开，公开页面的购买说明已移除（网站提交 `dbf7d4f`）。本地 0.3.0（5）Release 无签名构建通过，尚未归档或上传 TestFlight。

2026-09-23：本地 0.3.0（5）完成全局 UI 首轮改版：iPhone 一级标签导航、电影/节目墙与详情层级、节目先展示季集、播放器可滚动设置面板、固定底部的来源连接按钮。iOS Release 构建及模拟器三项交互测试通过；真实 Jellyfin 大库、iPad 分屏和真机动态字体仍待视觉验收，未上传 TestFlight。设计规则见 `Docs/UI-Redesign-2026-09-23.md`。

2026-09-24：家庭媒体目录由横向文字条改为纵向封面网格，按可见区域懒加载目录预览；Jellyfin 优先用目录图，回退到目录内视频海报，WebDAV 尝试目录图片。新增添加时间排序，顺序播放与列表保持一致。本地 iOS Release 构建与 43 项核心测试通过；此版仍未上传 TestFlight。

2026-09-24：根据真实片库截图调整目录卡片：移除封面上的大标题、重复名称和“浏览媒体库”提示，仅在封面下显示一次名称；媒体库根页也不再重复显示“你的片库”引导块。此项仍是本地改动，未上传 TestFlight。

2026-09-24：替换通用播放键 AppIcon 为深绿底、雾绿单笔 `g` 形图标；保留原图和旧图标备份于 `Design/`。1024 × 1024 不透明 PNG 已通过 iOS Release 构建，尚未上传 TestFlight。设计说明见 `Design/AppIcon-2026-09-24.md`。

2026-09-24：优化点播到首帧的路径：已加载列表立即开播，剩余目录队列首帧后补齐；取消首帧前单独刷新远端进度，降低初始缓冲并为初始续播允许关键帧容差。诊断增加资源和播放器就绪耗时。45 项核心测试及模拟器刷看/缩放/锁定回归通过；真实服务首帧耗时待真机复测，尚未上传 TestFlight。

2026-09-24：用户录屏显示上一条 AVPlayer 起播策略调整后出现 00:00 黑屏和自动恢复，具体触发参数尚未经实服对照证明。已恢复自动等待、15 秒缓冲与精确续播定位；目录队列延后补齐和去除额外进度请求保留。播放器现在将真实首帧就绪状态提供给无障碍及 UI 测试；本地视频、Jellyfin fixture 的电影/剧集及自动转码首帧测试通过。真实 Jellyfin 视频仍需新构建实机复测，尚未上传 TestFlight。

2026-09-24：修复版本号来源不一致：目标设置已改为 1.0.1（1），但 `Glide/Info.plist` 仍固定为 0.3.0（5），导致归档沿用旧号。Info.plist 现引用 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`；新 Release 构建的实际 App Info.plist 已核对为 1.0.1（1）。旧归档不会改变，需要重新归档；本次未上传 TestFlight。

2026-09-27：通过 Xcode Organizer 的 “TestFlight Internal Only” 将当前播放器自动恢复改动归档并上传为 **1.0.1（3）**（Bundle ID `com.songpeng.glide`）。Xcode 显示 “App upload complete”，归档状态为 “Uploaded to Apple”，上传时间 16:49。此前 1.0.1 构建 2 已于 9 月 24 日上传，因此本次将构建号升至 3。发布预检和 49 项核心测试通过；本地模拟器自动转码出画回归通过。Apple 处理状态及“Glide 个人测试”内部组分发仍待 App Store Connect 网页登录后核对；在此之前不能将上传视为测试员已收到新构建。

2026-09-27：根据 1.0.1（3）真机诊断优化 HEVC 首帧失败回退，归档并通过 Xcode Organizer 的 “TestFlight Internal Only” 上传 **1.0.1（4）**。Xcode 显示 “App upload complete”，归档状态为 “Uploaded to Apple”，上传时间 17:15；归档 Info.plist 已核对版本 1.0.1、构建号 4。49 项核心测试、iOS Release 模拟器构建及 iPhone 17 Pro 黑屏自动恢复 UI 测试通过。App Store Connect 当前仍停留登录页，尚不能核对 Apple 处理状态或测试组分发，因此不宣称测试员已收到 1.0.1（4）。

2026-09-27：针对 1.0.1（4）真机诊断中的 25 秒原画起播等待，新增原画资源就绪后的 8 秒独立超时，并在转码成功后记住此媒体的有效播放路线 24 小时。50 项核心测试及 iPhone 17 Pro 慢原画、重播自动恢复 UI 测试通过。已通过 Xcode Organizer “TestFlight Internal Only” 上传 **1.0.1（5）**；Xcode 显示 “App upload complete”，归档状态 “Uploaded to Apple”，上传时间 17:46，归档 Info.plist 的版本和构建号为 1.0.1（5）。按用户要求以 Xcode 上传完成为本次交付界限；真实 NAS 复测仍需确认首帧耗时，尤其是最终转码阶段的约 10 秒。

2026-09-28：1.0.1（6）完成 Xcode Release 归档，包含 MobileVLCKit 3.7.3、视频信息、可拖动进度条、上下切片与刷看不记录进度。CLI 分发最初返回 “Failed to Use Accounts”；随后 Xcode Organizer 显示该归档 **Uploaded to Apple**，上传时间 08:35，Build Number 6。此版仍保留长按临时倍速与双击跳转，不是最新手势修复版。

2026-09-28：根据试用反馈调整播放器手势及缓冲提示，制作 **1.0.1（7）**：短点呼出控制、长按画面左右半屏快退/快进；已出首帧时不显示“正在准备画面”。50 项核心测试与三项相关 iPhone 模拟器 UI 测试通过。Xcode Release 归档的实际 Info.plist 为 1.0.1（7），签名验证通过；经 Organizer 选择 “TestFlight Internal Only” 上传后，Xcode 显示 **Uploaded to Apple**，上传时间 09:06，Build Number 7。Apple 处理完成及个人测试组实际可见状态尚未在 App Store Connect 核对。

2026-09-28：修复家庭视频刷看时轻点有少量位移便被平移手势抢走、控制栏无法呼出的问题，制作 **1.0.1（8）**。播放中连续左右滑动后的短点、轻微位移短触和长按跳转均通过 iPhone 17 Pro 模拟器回归（2/2）；50 项核心测试及发布预检通过。Xcode Release 归档版本、构建号及签名核对通过；通过 Organizer “TestFlight Internal Only” 上传后，Xcode 显示 **Uploaded to Apple**，上传时间 09:46，Build Number 8。Apple 后续处理及个人测试组可见状态尚未另行核对。

2026-09-28：根据 1.0.1（8）真机反馈修复控制台自动隐藏后轻点无法唤起，并纠正锁定状态图标，制作 **1.0.1（9）**。轻点识别移到播放器外层，底层只负责滑动、缩放、双指轻点和长按；长按松手不再导致控制台二次切换。iPhone 17 Pro 模拟器自动隐藏、滑动后轻点、轻微位移与长按三项 UI 回归及 50 项核心测试通过，发布预检通过。Xcode Release 归档实际版本和签名核对通过，经 Organizer “TestFlight Internal Only” 上传后显示 **Uploaded to Apple**，上传时间 11:03，Build Number 9。Apple 处理及个人测试组可见状态尚未另行核对。

2026-10-16：修复 **1.3.0（6）** 分发时 MobileVLCKit dSYM 缺失。SDK 准备脚本现保留官方匹配符号并支持升级旧缓存，Release 构建及发布预检新增 UUID 校验；新归档自动包含依赖 dSYM。今天 11:09 的实际签名归档已补齐 UUID `99DC0B74-A3D1-3ED3-AC1F-2B8FC6A452A3` 的官方符号，应用文件／签名保持完整；本次未重新上传或确认 Apple 处理状态。[修复与验证](Testing/Glide-1.3.0-MobileVLCKit-Symbols-2026-10-16.md)。

2026-10-16：根据用户 **1.3.0（7）** 原片卡顿且原画兼容入口消失的诊断，开发 **1.3.0（8）**：修复协商标记／候选编码的过严判断，显式请求复制原视频，自动失败后保留手动重试。100 项核心测试、25 项原画传输检查、实际菜单点击回归及 Release 归档符号检查通过；独立「Glide 兼容验证」包已安装并成功启动。新版本原片效果仍待复测，本次未上传 App Store Connect。[实现与验证](Testing/Glide-1.3.0-Transport-Retry-2026-10-16.md)。

2026-10-16：开发 **1.4.0（1）** 界面与交互重设计：紧凑海报墙、结构化作品与技术信息、底部播放快捷操作、统一字体与暗色层级，并优化图片解码、滚动身份和播放状态更新。媒体库入口、目录与家庭视频统一采用 2:3 竖版预览；进入媒体库或文件夹默认展示媒体，顶部固定切换目录。100 项核心测试，以及 iPhone／iPad 页面、默认浏览、播放器、辅助字号和合成大库滚动用例通过；最终目录竖版与三列布局补充 iPhone 回归通过。签名验证包已生成；真机安装与启动边界见 [验证记录](Testing/Glide-1.4.0-UI-Validation.md)。未归档或上传此开发版本，真实大库帧率和最终真机手感仍待用户验收。
