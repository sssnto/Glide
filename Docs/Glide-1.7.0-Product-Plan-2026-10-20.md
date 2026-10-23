# Glide 1.7.0：Emby 直连

按已确认的 1.5.0 后续顺序，在完成 1.6.0 开发验收后逐项接入媒体服务器。本版选择 Emby；Plex、飞牛与其他协议仍分别安排，不将三个来源合并宣称完成。保留此前未提交代码与验收记录，不推送、打标签或提交商店。

## 交付范围

- 手动添加 Emby HTTP(S) 服务器与路径前缀，账号登录、重新认证和移除；令牌继续使用设备 Keychain。来源类型独立保存，Jellyfin 与 Emby 的认证头、根媒体库路径分别处理。
- 沿用紧凑片库、竖版家庭视频预览、默认媒体视图、电影详情、节目／季／集、排序、当前范围搜索、分页、收藏与继续观看。服务器没有的元数据不伪造。
- 系统播放器播放已验证的原文件与服务器 HLS；通过 PlaybackInfo 协商实际媒体版本、音轨／字幕与清晰度。原画兼容必须确认视频复制，不把接入协议等同于支持所有编码／HDR。下载沿用既有 MP4／MOV／M4V 原文件边界并单独验证。
- 服务器播放开始、进度、暂停、结束与转码清理；观看记录区分来源与账号。重新连接失败不覆盖可用凭据，移除后清除本机认证与关联记录。
- Emby 视频复制 HLS 的定位结果超出容差时，仅在同一原文件本次已成功出画面、容器为 MP4／MOV／M4V、未选择服务器专属音轨或烧录字幕的条件下，尝试一次原文件精确定位；保留播放／暂停意图与媒体版本，手动再次尝试兼容才重新允许恢复。真实素材检查与注入解码器定位偏差的控制器契约单独记录。
- 复用手动导入字幕、视频级字幕记忆、每视频／节目手动片头片尾与自动跳过。Emby 不请求 Jellyfin MediaSegments，也不展示不可用的 Jellyfin 片段开关；本版不实现 Emby 自动片头标记。

## 验收

使用官方 Emby ARM64 服务与项目原创素材核实接口、错误认证、失败恢复、分页和凭据保存；核心协议测试覆盖来源隔离、认证差异及 URL 路径前缀。真实服务的 /emby 别名已验证，反向代理路径前缀的 HTTP 端到端尚未覆盖。服务端真实结果、核心契约、模拟器、iPhone 和未覆盖的组合分别记录。

验收至少覆盖：旧来源快照恢复；认证方案与来源标识；电影、家庭视频及多集节目；海报与搜索；原文件首帧／暂停定位；可用的 HLS 协商与结束清理；收藏、续播、已看及同步；手动跳过与字幕记忆不串用；重新登录失败和移除；正常界面操作；现有 Jellyfin／链接播放的针对性回归；设备构建、Release 归档、签名与 dSYM。

没有真实服务器、设备或素材支持的能力明确保留为未覆盖。不会把服务端成功返回 URL 当成客户端出画面、定位或转码成功。

## 接口依据

2026-10-20 核对 Emby 官方资料：[用户认证](https://dev.emby.media/doc/restapi/User-Authentication.html)、[用户媒体库](https://dev.emby.media/reference/RestAPI/UserViewsService/getUsersByUseridViews.html)、[视频流](https://dev.emby.media/doc/restapi/Video-Streaming.html)、[PlaybackInfo](https://dev.emby.media/reference/RestAPI/MediaInfoService/getItemsByIdPlaybackinfo.html)、[播放上报](https://dev.emby.media/doc/restapi/Playback-Check-ins.html)、[官方 Docker](https://docs.emby.media/docker-server.html)。认证使用 Emby 方案，媒体库为 Users/{UserId}/Views；静态视频包含媒体版本、播放会话与设备标识。实际支持以验收记录为准。
