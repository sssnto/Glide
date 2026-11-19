# WebDAV 有声无画面修复 · 1.16.0（8）

## 原因与改动

用户构建 7 的脱敏诊断显示：WebDAV 原画直放使用 AVPlayer，已缓冲约 13.7 秒、音频时钟运行，但没有视频画面，约 9.35 秒后触发 `video_frame_timeout`。当时兼容内核只允许本地文件与 SMB，WebDAV 没有可用的解码回退，恢复次数为零。这份日志不能单独证明视频编码，需要原片复核。

构建 8 对已验证来源范围内的 WebDAV 文件增加兼容播放：MKV／AVI／WebM／TS 等先使用 VLC；MP4／MOV 保留 AVPlayer，媒体检查失败、加载失败或无首帧时自动切换 VLC 一次。自动回退从原本请求的位置开始，避免跳过已经响起声音但尚未看到的内容；手动切换保留实际进度与暂停／播放状态。切换不改变本地视频的默认内核，也不影响 Jellyfin／Emby 的服务器转码逻辑。

播放设置中的“WebDAV 播放器”提供系统／兼容切换；失败页面也有手动入口。画中画或外部播放期间不能切换。兼容内核原有的能力边界保持不变，例如不提供系统画中画。

认证使用应用内 URLSession 的流式读取通道，向 libVLC 提供仅绑定 `127.0.0.1` 的一次性随机地址；凭据不进入 VLC URL、选项、日志或落盘文件。每个输入最多四个连接，客户端只能请求固定资源的 GET／HEAD 与单一 Range，不能指定其他上游地址；跨来源重定向拒绝，TLS 继续使用系统校验，遵循蜂窝播放设置。校验分段位置与长度，发送时暂停／恢复上游读取，排队数据上限 2 MiB，切换视频时取消旧监听与请求。此通道不下载整部视频，也不改动服务器文件。

原生媒体检查现在覆盖 WebDAV，把视频轨数和 FourCC 编码标记写入脱敏诊断；回退后保留初始编码及恢复事件，仍不导出文件名、地址、标题或认证头。

## 验收

- **真实原片：iPhone 13 Pro Max、iOS 27.2、主应用 1.16.0（8）通过**。仅使用已保存连接读取用户指定的那个文件，没有编辑、转码或替换原文件。原生检查识别 HEVC 的 `hev1` 标记，随后自动回退一次，兼容内核输出 **1216 × 2160** 画面；兼容首帧约 1.51 秒，总起播约 3.04 秒，持续播放及拖动后继续输出画面通过。见 [设备检查结果](Device-Original-QA.json)、[解码诊断](Device-Original-Diagnostics.json)。这些时间只代表本轮，不是网络性能承诺。
- **原创片源的 23 项应用内检查通过**：带认证的开放／定长／后缀 Range、内容逐字节匹配、同来源重定向、拒绝跨来源重定向、错误分段／忽略 Range 拒绝、HEAD 长度、路径隔离；普通 MP4 仍走系统；暂停状态切换内核保留进度；识别两个音轨并切换；AVC High 10 MP4 真实复现系统音频运行而无首帧，随后自动回退并实际输出画面；MKV 直接兼容；旧会话不污染新视频。见 [检查结果](Simulator-WebDAVPlaybackQA.json)、[诊断](Simulator-WebDAVPlaybackDiagnostics.json)。
- **3 项模拟器 UI 测试通过**，iPhone 17、iOS 26.3.1：新的认证兼容播放检查，以及上一轮播放器内旋转保存／原样还原／目录继承封面、缩放几何两项回归。见 [播放 UI 日志](Simulator-Playback-UI.log)、[既有功能回归日志](Simulator-Regression.log)。没有把模拟器结果当作实体机触控验收。
- **完整核心回归通过**：启用 `GLIDE_ROTATION_HTTP_FIXTURE=1` 的 Swift Testing 268 项、19 个套件，以及 XCTest 7 项均通过，HTTP 旋转测试没有跳过。见 [核心日志](Core.log)。
- 主应用修复包已经签名检查并安装，指定原片的结果来自该包。正式构建与静态预检结果见 `Validation.json`。

首次远程启动没有产出报告，用户打开后看到普通片库；确认前台后重新启动验证才获得上述带当前时间戳的通过报告，未将先前启动成功当作播放通过。最后尝试恢复普通主界面时被锁屏拒绝；用户可从主屏幕正常打开 Glide，默认不进入验证页，无需重新登录。

尚未提交、推送、打 tag、上传商店或更新官网。

## 重跑

1. `python3 Scripts/webdav_playback_fixture.py` 生成原创有声 High 10／8 位 MP4 与 MKV，监听 127.0.0.1:8827，使用固定虚拟认证。
2. `python3 Scripts/rotation_webdav_fixture.py` 启动 127.0.0.1:8828 的原创旋转服务。
3. `GLIDE_ROTATION_HTTP_FIXTURE=1 swift test --scratch-path /tmp/GlideRotationCore`。
4. 独立模拟器 bundle `com.songpeng.glide.webdavqa`、CompatibilityQA、单目标串行运行：`TEST_RUNNER_GLIDE_WEBDAV_PLAYBACK_FIXTURE=1` 对应 `testWebDAVAuthenticatedCompatibilityPlayback`；`TEST_RUNNER_GLIDE_WEBDAV_PRESENTATION_FIXTURE=1` 与 `TEST_RUNNER_GLIDE_ZOOM_FIXTURE=1` 对应原有两项回归。

真实原片仅在主应用内通过调试启动参数传入，使用设备内已保存认证，不把实际 URL 或密码写入仓库。测试服务验收后关闭。
