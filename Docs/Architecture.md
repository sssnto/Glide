# Glide architecture

- `Core/Models.swift`：数据类型、URL 校验、非递归目录查询、WebDAV XML 解析。Swift Package 测试可在 macOS 单独运行。
- `LibraryStore`：服务器选择、媒体库／目录路径、分页、收藏、本地观看进度。请求使用 generation 标识隔离过期结果；返回上级、切换来源不接受旧目录响应。
- `MediaClient`：Jellyfin 认证、UserViews、Items、PlaybackInfo、会话进度；WebDAV PROPFIND。凭据从 Keychain 读取。
- `AuthenticatedAsset`：AVAssetResourceLoader + URLSessionDataDelegate 实现带认证的 WebDAV Range 读取，逐块送入 AVFoundation，取消时释放请求。
- `PlaybackController`：管理 AVPlayer 的生命周期、失败回退、音频会话、字幕／音轨及进度。刷看关闭观看进度保存与上报，影视详情保留续播。
- `VideoSurface`：AVPlayerLayer 使用 UIKit 手势视图；短点切换控制台、上下刷片、左右倍速、长按左/右侧快退/快进、双指缩放。
- `LibraryView / SourcesView / PlayerView`：SwiftUI 界面；播放准备任务绑定目录标识，切换目录或取消时丢弃旧任务；队列使用独立的完整范围快照。

## 目录范围约束

根层只调用 `UserViews`（老版本回退到 `Users/{userId}/Views`）。进入媒体库／目录后，文件夹列表的每一页调用 `Items` 并携带 `ParentId` 与 `Recursive=false`。从本层返回结果中提取文件夹，以返回的原始条目数量推进文件夹分页。视频封面另用固定 ParentId 的递归查询，并维护独立分页游标。

本地浏览路径为 `MediaFolder` 数组；媒体库是第一级，后续可以是普通文件夹、Series、Season 或 BoxSet。Jellyfin 决定它呈现的逻辑目录结构，客户端不扫描服务器的任意磁盘路径。

## 递归播放队列

浏览列表和播放集合分别查询。`DirectoryQuery.playback` 固定所选目录的 `ParentId`、`Recursive=true`、`MediaTypes=Video` 与 `IsFolder=false`。`ScopedQueueCollector.pages` 收齐所有分页并按 ID 去重，遇到无进展的分页抛错，防止死循环或默默使用部分队列。它不改动 `LibraryStore` 当前层的目录列表及其分页游标。

WebDAV 通过 `ScopedQueueCollector.webDAV` 遍历后代目录；路径边界、同源检查和已访问集合防止越界及循环。队列准备支持取消，视图额外通过 generation + scopeKey 拒绝过期结果。

`PlaybackQueue` 保存名称顺序的原始视频和当前播放顺序，随机模式对完整集合 shuffle，一轮不重复。前后移动与自动连播共用同一游标。切换模式保留当前视频，不重建 AVPlayerItem，因此播放位置不变。切到顺序模式恢复原序列；切到随机模式以当前视频为起点开启新排列。

AVPlayer 的结束通知只接受当前 item，递增完成事件；`PlayerView` 在前台推进下一部，锁定触控不阻止自动连播。队列末尾停止。准备队列不预下载视频，只读取元数据。

## 编码与认证边界

家庭视频刷看、电影、剧集详情、WebDAV 与本地视频统一使用 AVPlayer；不链接第三方解码库。`JellyfinPlaybackPolicy` 在 AVPlayer 链路内按原画、原画兼容、1080p H.264/AAC、720p H.264/AAC 自动恢复，用户不需要选择画质。转码 URL 和设备 CodecProfile 同时限制最大宽高、码率，并禁用视频流复制。恢复时保留播放时间与意图；持续缓冲可跳过不能降低码率的重封装。详见 [Player-Engine-Decision.md](Player-Engine-Decision.md)。

`ScreenRotation` 使用 iOS 16+ 的 UIWindowScene.requestGeometryUpdate 公开 API，更新当前及呈现控制器的方向支持，播放器退出时恢复进入前的方向。WebDAV 不具备服务器转码能力，因此系统不支持的容器／编码会显示错误并建议通过 Jellyfin 播放。未承诺 Infuse 的全格式解码能力。

API 与 WebDAV 限制跨来源重定向。Keychain 仅保存 Jellyfin token 或 WebDAV 密码，账号密码不出现在工程、测试脚本或文档中。服务器信息与观看状态保留在设备本地。

## Recursive preview grid

Folder browsing retains its nonrecursive cursor (`folderNextIndex`/`folderTotal`), while the video grid uses a separate recursive video-only cursor (`nextIndex`/`total`). The Jellyfin server's ParentId scopes both operations to the selected library/directory. First-page folder and video requests run concurrently; loading more videos never overwrites folders. Generation checks discard responses from previous scopes. Playback still collects an independent complete queue so pagination cannot truncate sequential/shuffled playback. WebDAV previews traverse within the selected root using the same boundary/cycle checks as queue collection.


## Scoped search and personal library (2026-09-21)

`DirectoryQuery.playback` accepts a trimmed optional SearchTerm while retaining ParentId, recursive video filtering and pagination. API fields verified against the [official Jellyfin SDK](https://typescript-sdk.jellyfin.org/interfaces/generated-client.LibraryApiGetItemsRequest.html). `LibraryView` owns a cancellable 300ms-debounced task keyed by scope, load generation, query and favorite IDs. A completed search produces one immutable result snapshot; visible cards and filtered playback use that same snapshot. Browsing cursors are not mutated. WebDAV retains bounded directory traversal and client-side title matching. Favorites remain app-local and therefore filter a complete scope collection rather than Jellyfin's separate server-favorite flag.

`PersonalVideo` persists media identity/display metadata and local last-played time under a versioned storage key, independently of browse pagination. Resolved playback resources and artwork URLs are not serialized; demo URLs and Jellyfin artwork rebuild from the current bundle/server. Resume eligibility is shared through WatchProgress. Playback saves the discovered duration as well as position, including for WebDAV entries without runtime metadata. Personal-library single-item playback avoids implicitly crossing directory boundaries. Favorites and history removal are independent. History is capped at200 entries; favorites are retained outside that cap. No cross-device synchronization is introduced.

## 影视与家庭视频分流

`MediaFolder.collectionType` 为兼容旧存储的可选字段；恢复旧路径时通过用户媒体库列表补齐。`LibraryExperience` 将 movies/tvshows 分别导向 CatalogView，其余类型保持目录浏览。影视不再发起扁平递归视频队列请求。CatalogItem 保留可选元数据、季集序号及 MediaSources/MediaStreams，详情与列表分别加载；列表遍历带 ParentId 和 IncludeItemTypes 的分页，去重并检测不前进，季集按数字稳定排序。失败/空季可见，切季取消旧请求，防止旧结果覆盖。

TrackSelection 区分服务器默认(nil)、字幕关闭(-1)与真实索引；选择具体音轨或字幕索引时由 Jellyfin 处理，单纯关闭字幕不强制转码。字幕 profile 声明 Encode。PlaySelection 的影视队列固定顺序、电影单片、节目当前季，切换集重置文件级源与轨道索引。详情请求和海报请求通过现有同源鉴权客户端，不把 token 放入显示模型或持久记录。

接口参考：[Jellyfin PlaybackInfo 官方 SDK](https://typescript-sdk.jellyfin.org/interfaces/generated-client.MediaInfoApiGetPostedPlaybackInfoRequest.html)。

媒体详情兼容旧版 `/Users/{userId}/Items/{itemId}` 与新版 `/Items/{itemId}?UserId=...`；仅在旧接口返回 404 时回退，不掩盖登录或服务器错误。新版路由依据 [Jellyfin 官方 SDK](https://typescript-sdk.jellyfin.org/interfaces/generated-client.LibraryApiGetItemRequest.html)。

## 演职人员与相关媒体

`CatalogItem.Person` 保存 Jellyfin 的 Id / PrimaryImageTag / Name / Type / Role。`CastSection` 横向懒加载全部人员（不再只展示前 12 个姓名），`PersonPortrait` 通过同源鉴权请求头像，带图片 tag；无图保留占位图。相关媒体页通过 `PersonIds` 精确关联、始终传 UserId，覆盖当前服务器的账号可见媒体，而非仅原电影所在目录。每页 60 条，支持继续加载、去重、防止分页无进展、刷新和失败重试；请求代次与取消检查防止旧结果覆盖。没有人员 ID 时不发出查询，避免误查同名人员或无筛选的全库。

接口依据：[Jellyfin BaseItemPerson](https://typescript-sdk.jellyfin.org/interfaces/generated-client.BaseItemPerson.html)、[GetItems PersonIds](https://typescript-sdk.jellyfin.org/interfaces/generated-client.LibraryApiGetItemsRequest.html)。


## 2026-09-21 测试反馈修订

CatalogView 改为 LazyVStack + LazyVGrid 渐进分页，每页 60 条；CatalogOrder 将名称/评分/年份/添加时间/片长及方向编码为 Jellyfin SortBy/SortOrder。账号、目录、查询和排序共同决定请求缓存键。人员查询排除 Episode，展示 Series 入口；依赖服务器已有关联元数据。

MediaCache actor 提供账号隔离、SHA256 文件名、15 分钟元数据 TTL、7 天图片 TTL、同请求合并和 256 MB 磁盘淘汰。元数据先解码为已知 Codable 模型再序列化，丢弃原始响应中的未知播放地址及凭据。详情的新旧接口共享一个逻辑缓存键。ArtworkCache 经 ImageIO 下采样后放入 48 MB 解码图片缓存，避免在主线程解码大图。图片 tag 参与键；缓存不会持久化解析后的播放 URL。删除来源使正在进行的旧缓存写入失效。

播放器采用 [AVPlayer 自动缓冲等待](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling) 与远程 15 秒 preferredForwardBufferDuration；不再使用立即播放强制绕过缓冲。启动或播放连续 25 秒无进展、或 item 失败时，自动模式仅允许一次 1080p 回退并保持播放位置。暂停不计入超时，切片/关闭取消监测。通过 [VTIsHardwareDecodeSupported](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)) 限制 HEVC/AV1 直放声明；AVPlayer 负责实际系统解码。此检查不代表具体 HDR/Dolby Vision profile、音轨或容器一定兼容。

DownloadStore 使用 [background URLSession](https://developer.apple.com/documentation/Foundation/downloading-files-in-the-background) 下载 Jellyfin Items/{id}/Download 原文件到 Application Support/OfflineMedia，UUID 文件名、原子清单、排除备份。鉴权在请求头；持久清单不含 token/解析流地址。默认媒体版本限定 MP4/MOV/M4V，检查空间与 HTTP 返回，完成回调立即移走系统临时文件。删除任务/来源取消对应传输并清理文件；回调按下载 UUID 匹配，避免旧任务覆盖重试。BGProcessingTask 做任务清单核对，实际传输由 URLSession 调度。离线播放优先本地 URL，不请求 PlaybackInfo 或上报网络会话。操作系统唤醒和后台长时间传输仍需真机验收。


## 滚动分页与紧凑播放器修订

CatalogView 的分页任务原先附在 `!loading` 条件下的按钮上。任务设置 loading 后移除自身视图，导致取消、复原、再次触发。现在任务附着稳定的固定高度页脚，仅以分页游标作为任务键；加载状态只更换内部内容。下拉刷新保留已有海报，成功后再替换，失败时仍能查看旧内容。

PlayerView 将标题移至顶部单行；进度与控制条集中在底部，ViewThatFits 在横屏用单行操作、窄屏用两行操作。常规和播放按钮保留至少 44 点触控区域，移除底部重复标题/简介/手势提示，收藏收纳到播放设置。播放状态进入 playing 时重新计时，3 秒无操作隐藏控件，避免初次网络准备超过计时器后控件不消失。


## 标签与相似作品

CatalogFacet 区分 Genres 与 Tags，清理空字符串并按种类去重；筛选使用 Jellyfin Items 的对应字段，固定 UserId 与非单集影视类型，分页保持相同条件。筛选范围为当前服务器全部账号可见库。详情保留原有加载流程，推荐独立请求，失败不阻塞播放。SimilarMediaSection 使用 Items/{id}/Similar，Episode 优先采用 SeriesId；结果排除自身、按节目 ID 去重，并解析单集的节目入口。两类请求使用现有账号隔离元数据缓存。推荐依赖 Jellyfin 的相似度数据，没有自行编造推荐结果。

接口依据：[Items 标签筛选](https://typescript-sdk.jellyfin.org/interfaces/generated-client.LibraryApiGetItemsRequest.html)、[Similar Items](https://typescript-sdk.jellyfin.org/interfaces/generated-client.LibraryApiGetSimilarItemsRequest.html)。

## 2026-09-30 原生播放流程

起播采用 2 秒远程缓冲偏好，首帧可显示后增加至约 15 秒实际观看时间对应的媒体时长，2× 为 30 秒。通过 AVPlayerLayer.isReadyForDisplay 的 KVO 立即识别首帧，0.5 秒周期观察只作补充。等待状态需持续 350 ms 才计为缓冲；定位和倍速的短暂状态切换不触发自动降级。续播等待 item 就绪并完成精确定位后再播放；手动连续定位取消旧 seek，回调需匹配 session 与 seek ID，时钟观察在定位中保留目标值。Jellyfin 不兼容的离线文件可联网协商兼容流；WebDAV 和离线状态仍受系统格式能力限制。
