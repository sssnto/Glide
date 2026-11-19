# Glide 1.15.0：iPhone Duo 适配验收

2026-10-28，开发版本 1.15.0（1）。核心、最终 UI 回归与 Release 归档校验已通过。尚未提交、推送、打标签或上传商店，官网仍对应用户确认发布的 1.11.0。

## 实现

- 统一系统 TabView／自适应侧栏，以场景保存所选入口。
- 媒体与目录网格按可用空间重排，感知活动／非活动折线，处理两侧不对称宽度与 RTL；详情在宽空间双栏，大字体回到单栏。
- 内屏使用系统 ArrangementView 分隔画面与控制／队列；书本姿态左右分区，桌面姿态上下分区。外屏保留叠加控制。
- 播放会话、AVPlayerLayer、队列、倍速、暂停与轨道选择由稳定的播放器所有者持有；缩放保留相对焦点，尺寸变化取消执行中的手势。
- 自定义控件读取摄像头遮挡区域。画面轻点排除实际顶部控件与底部控制区域；设置弹出期间屏蔽画面轻点，防止重复触发。
- 搜索框与滚动结果分离，避免结果重排影响输入；清除按钮至少 44 pt。补充 VoiceOver 播放、定位、切换与缩放复原操作。
- 推荐卡片以剧名或电影名为主标题，补全季／集编号、单集标题、年份、类型和来源；新增字段支持旧数据解码与持久化，不改变推荐排序或点击后的媒体身份。

## 验收状态

| 项目 | 证据与状态 |
| --- | --- |
| 核心 | **245 项通过**：238 项 Swift Testing＋7 项 XCTest，含推荐信息映射与旧数据兼容，见 [核心日志](Logs/Core-Metadata-Final.log)。 |
| 工具链 | Xcode 27.1（27A9275），iOS 27.1 SDK 与 Simulator（24A94425）；Debug／Release 实际编译 Duo API 分支。 |
| 官方姿态 | Device Hub 的 Closed、Open、Partially Open 与 Rotate Right；已实测外屏、展开、书本、桌面和旋转，不以普通 iPad 或合成窗口尺寸代替。 |
| 播放连续性 | 展开到合拢保持同一会话、准备次数 1、1.5 倍速、第二音轨与连续进度。样例自然结束后进入第二条，准备次数变为 2；书本到桌面仍保持该会话与次数。 |
| 暂停连续性 | 稳定暂停位置 04:48，合拢、展开、半折叠与旋转期间保持暂停、会话、轨道、倍速与准备次数。见 [合拢状态](Pose-Evidence/paused-closed-landscape.json)、[展开状态](Pose-Evidence/paused-open-portrait-verified.json)、[书本状态](Pose-Evidence/paused-book-verified.json)。 |
| Duo 最终 UI | **3 条流程通过**：片段编辑草稿跨屏、暂停播放跨屏（含 AVPlayerLayer 身份）与搜索跨屏。前两项见 [最终日志](Logs/Duo-Final-UI.log)，搜索在未及时驱动姿态导致一次超时后[单独补跑通过](Logs/Duo-Search-Verified.log)。 |
| 普通 iPhone | **4 条流程通过**：推荐媒体身份、倍速／音轨／片段草稿、原始 ASS 系统与兼容内核，以及片段合集返回完整视频。见 [推荐日志](Logs/Recommendation-iPhone.log)、[播放与 ASS](Logs/iPhone-Accepted.log)、[片段合集](Logs/iPhone-Diagnosis.log)。历史整批测试曾失败，修正入口选择后分别复核通过；不将失败整批记为全绿。 |
| iPad | **2 条流程通过**：推荐媒体身份展示，见 [首轮日志](Logs/iPad-Final.log)；倍速／音轨／片段编辑，首轮启动中断后[单独复核通过](Logs/iPad-Controls-Verified.log)。 |
| Release | **最终归档通过**：`/tmp/Glide1150-Final.xcarchive`，见 [归档日志](Logs/Release-Final-Archive.log)。[签名验证](Release-Signature.txt)、[应用与 MobileVLCKit dSYM UUID](Archive-Symbols.json)、[发布预检](Release-Preflight.txt) 均通过。 |

## 图像与数据

只使用仓库原创山野素材，五分钟样例附两条原创合成音轨，无私人媒体或服务账号。`--glide-duo-fixture` 使用独立 QA 状态与离线目录；`Scripts/generate_duo_fixture.py` 可重建素材。常规商店构建不提供 QA 入口。

Duo 内屏／外屏为独立端口。`simctl` 默认截图可能读取已停用外屏；正式截图明确选择 display 3／1。误取停用屏的图像保留在 [诊断目录](Diagnostics/README.md)，不用于通过证据。

- [展开内屏](Screenshots/paused-open-portrait-verified.png)
- [书本姿态](Screenshots/paused-book-verified.png)
- [桌面姿态](Screenshots/paused-tabletop-verified.png)
- [推荐媒体信息（iPhone 原创样例）](Screenshots/recommendation-media-identity-iPhone.png)

## 诊断保留

8 GB Mac 同时启动两个模拟器曾出现大量换页，后续改为顺序验收。旧失败、中断和误取停用屏的结果保留用于追溯，不计为通过。Duo 编辑页弹出键盘时日志仍记录一次 `Invalid frame dimension (negative or non-finite)`，该流程的输入、跨屏草稿和控件断言均通过；目前未确定该警告来源，不宣称运行时零告警。

## 边界

用户没有 Duo 实体机，本次按其选择使用官方模拟器验收；不据此宣称 Duo 真机、真实功耗、温度、触感、无线网络或硬解性能已通过。NAS／服务器协议与解码器能力不因本次布局适配而扩展。发行前仍需按商店流程核对隐私和公开材料。

[产品范围](../../Glide-1.15.0-Product-Plan-2026-10-28.md)、[发布说明草稿](../../Glide-1.15.0-Release-Notes.md)、[结构化验收结果](Validation.json)、[源码指纹](Source-Snapshot.json)、[体验检查步骤](User-Acceptance.md)。
