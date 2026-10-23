# Glide 1.6.0：链接播放与片头片尾

沿用已确认的版本顺序，在 1.5.1 工作区基础上实施。既有未提交代码和历史验收保留，未授权推送、打标签或提交商店。

- 提供独立「链接与 STRM」入口，输入 HTTP(S) 视频链接、名称和可选请求头，保存、编辑、删除和再次播放；链接及请求头存设备 Keychain，片库快照仅存标识与展示信息。地址或请求头变化默认重置观看设置，仅用户明确选择同一视频时保留。
- 手动导入 UTF-8 STRM 文件，按文件名保存链接。每个 STRM 只接受一条绝对 HTTP(S) 地址；不执行指令或访问本地路径，不将 STRM 当成视频复制。此版不自动扫描 NAS 中的 STRM，也不提供播放列表／IPTV。
- 复用系统播放、进度、字幕导入和错误恢复。首批范围为系统可播放的渐进式视频及无自定义请求头的 HLS；带自定义头的 HLS 明确拒绝，避免不完整的认证实现。
- 可按视频保存手动片头秒数、片尾秒数；Jellyfin 剧集可按节目共用规则。默认显示跳过按钮，自动跳过需主动启用；暂停、拖动和切片有明确隔离，自动跳过每段只执行一次。
- Jellyfin 提供 MediaSegments 时读取真实标记。支持 Intro、Outro、Recap、Preview、Commercial；缺接口或无标记不影响播放，不声称客户端自动识别片头。

Jellyfin 接口依据：[官方片段文档](https://jellyfin.org/docs/general/server/metadata/media-segments/)、[官方控制器](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/MediaSegmentsController.cs)、[DTO](https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Model/MediaSegments/MediaSegmentDto.cs)，2026-10-20 核对。接口为带认证的 GET MediaSegments/{itemId}，返回 Items 中的 Type、StartTicks、EndTicks；时间单位为 100 ns。

验收覆盖链接／STRM 输入边界、请求头限制、持久恢复与删除、请求头隔离、原创 HTTP Range／HLS 播放、手动／自动跳过及暂停／定位、规则作用域、非法片段、Jellyfin 缺接口回退和真实 UI。真机、模拟器与合成服务分别记录，不沿用旧版本结果充当新版本通过。
