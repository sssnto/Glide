# Glide 1.15.0：iPhone Duo 操作与交互适配

用户要求全面支持 iPhone Duo，随后确认没有 Duo 真机，先按官方模拟器验收。当前状态为开发中；不能把普通 iPhone／iPad、合成窗口尺寸或编译通过记作 Duo 姿态验收。

## 范围

- 根据用户补充的“给我选一部”截图，推荐行优先显示作品名：剧集显示剧名、季／集编号和单集标题，电影显示片名、年份与类型；明确区分来源与作品身份。可靠字段缺失时省略或说明缺失，不从来源简称猜测剧名。保留片长／剩余时间及推荐理由。

- 外屏、展开内屏及系统多任务可用空间共用功能；原生标签／侧栏自适应，保持所选入口、导航、搜索、目录滚动和编辑草稿。
- 电影与目录海报随可用宽度重排；存在折线时采用偶数列，垂直活动分割区域留出真实间隔并分别处理两侧宽度。媒体详情在空间充足时双栏，动态字体保持可读。
- 播放器保留同一个播放会话、队列、媒体版本、音轨／字幕、倍速、暂停意图、片段区间和进度；展开／折叠／旋转只改变布局。内屏以系统 ArrangementView 分隔画面与控制／队列，桌面姿态上方观看下方操作，书本姿态两侧分区。
- 定位、字幕、完整 ASS／PGS、音轨切换、内容地图、时刻、片段集、离线行程与原功能均可使用；高优先级自定义控件避让摄像头 occlusion 和 fold division。方向请求使用当前窗口真实方向，不由宽高比猜测。
- 放大画面在窗口变化后保留相对焦点并夹取边界，取消仍在执行的手势，避免折叠动作触发切片。保留显式控制与 VoiceOver 操作，触控目标至少 44 pt；尊重左右安全区差异、RTL 和大字体。

## 工具链与发布门槛

本机初始为 Xcode 27.0／iOS 27.0 SDK，没有 Duo 设备配置、iOS 27.1 runtime 或 RocketSim CLI，剩余磁盘约 19 GB。Duo 的 ArrangementView、reservedRegions 与竖向系统栏需 Xcode 27.1／iOS 27.1；已请用户准备工具链，期间完成可编译的通用适配和旧系统回归。

新增 API 必须由 27.1+ SDK 实际编译，并通过 iOS 版本门控；旧 SDK 的回退构建不计为完整 Duo 支持。闭合／展开／书本／桌面姿态和旋转必须以官方 Duo 模拟器真实切换验收。若未能驱动姿态切换则保留明确待验收项，不用屏幕分辨率替代设备状态。既有普通 iPhone 与 iPad 做回归。无 Duo 真机时不宣传真机验证或真实功耗／触感／性能结论。

2026-10-28 工具链已更新到 Xcode 27.1（27A9275）与 iOS 27.1 Simulator（24A94425），官方 iPhone Duo 模拟器可运行。已通过 Device Hub 的 Closed／Partially Open／Open／Rotate Right 操作真实姿态；未依赖 RocketSim、合成窗口尺寸或模拟折线。Debug 与 Release 均实际编译 `GLIDE_DUO_SDK` 分支。内外屏为不同显示端口，截图须分别指定 display 3／1。

核心覆盖几何、列宽、折线间隔、极端输入、导航身份、缩放焦点。UI 验证导航深度／草稿／搜索跨尺寸连续性；播放中多次切换形态，检查不重新请求播放、无额外自动切集、时间持续、暂停／倍速／轨道／片段范围保持；检查键盘、表单、菜单、进度条、横竖方向与安全区。Release 签名和 dSYM 校验继续保留。

不自动推送、打标签、上传商店或修改官网已发布状态。

## 官方依据

- [Get ready for iPhone Duo](https://developer.apple.com/iphone-duo/)
- [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Strike a pose with adaptive layouts](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Xcode SDK 与系统要求](https://developer.apple.com/xcode/system-requirements)

核对日期：2026-10-28。官方要求、代码实现、普通设备回归、Duo 模拟器姿态实测分别记录。
