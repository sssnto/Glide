# Glide 兼容内核独立验证

此目录是开发验证应用，Bundle ID 为 `com.songpeng.glide.compatibilitylab`，不在 Glide scheme 中编译或打包。当前候选固定为 MobileVLCKit 3.7.3；版本与官方二进制校验值见 `Dependencies/MobileVLCKit.json`。这不是已发布功能或全格式支持承诺。

## 复现

需要 Xcode、Python 3.9+、FFmpeg（仅生成原创素材）以及带 `xcodeproj` gem 的 Ruby（可由本机 CocoaPods 安装提供）。无需对主项目执行 `pod install`。

```sh
python3 Scripts/generate_compatibility_fixtures.py /tmp/GlideCompatibility/Fixtures
GLIDE_LAB_FIXTURES=/tmp/GlideCompatibility/Fixtures python3 Scripts/prepare_compatibility_lab.py
```

生成工程默认为 `.build/CompatibilityLab/CompatibilityLab.xcodeproj`。SDK 默认复用 `.build/CompatibilitySDK`，与主应用使用同一架构裁剪产物。下载的 SDK、生成工程与测试素材均在忽略目录；不提交二进制。脚本下载固定 URL、核对 SHA256 后才解包，不从 latest 分支隐式升级。也可用 `--work /tmp/GlideCompatibility/Lab --archive /path/to/verified.tar.xz` 复用已下载包。SDK 校验值或印记不符会拒绝复用。

选择 `CompatibilityLab` scheme 和专用模拟器，运行界面测试 `CompatibilityLabUITests`。手动启动可传 `--suite matrix`、`edges`、`controls`、`lifecycle`、`subtitles` 或 `subtitle-controls`；默认 matrix。每组会自动运行并在界面及应用沙盒的 Application Support 下保存脱敏 JSON，解码截图位于 `Snapshots`。

## 验证内容

- `matrix`：H.264／AAC MP4、HEVC／AAC MP4、H.264／AAC MKV、MPEG-4／MP3 AVI。
- `edges`：改后缀 MKV、截断 MP4、纯音频 MP4、多音轨 MP4。无画面样例的正确失败结果也属于验收，不能把测试通过理解为文件可播放。
- `subtitles`：原创 ASS MKV、双音轨 ASS MKV；直接启用字幕并起播，验证程序不再额外定位到 2 秒。
- `subtitle-controls`：冷启动双音轨 ASS，覆盖字幕显隐、暂停、2×、连续定位竞争与换文件后的独立选择。
- `controls`：预备暂停、播放／暂停、音轨与字幕选择／关闭、连续定位只接收最后结果、2× 媒体时钟。
- `endurance`：原创 60 秒 1080p 双音轨 ASS 样片，50 次打开／关闭后静音前台播放 1800 秒；每 30 秒记录 RSS、热状态与实际画面计数。先用 `Scripts/generate_compatibility_hd_fixture.py` 生成素材。
- `lifecycle`：起播期间快速停止与重开、旧定位回调不能写入新视频。

字幕界面测试追加 `--visual`：每个 ASS 样例停在屏幕上，XCTest 保存系统截图、通过 Vision OCR 识别原始字幕文字后点击「继续验证」。解码截图可能不含字幕叠层，因此系统截图单独作为文字／样式的视觉证据。详见 [本次结果与剩余问题](../../Docs/Testing/CompatibilityLab-2026-10-15.md)。

字幕请求会合并快速变更，在轨道与画面就绪后回读当前位置，并让用户定位优先。`VLCClockPlayer` 通过 SDK 的公开原生实例初始化接口接入 libVLC 公开时钟，避免暂停定位时事件缓存未更新。桥接与 Swift 适配器位于 `Glide/Services/Compatibility`，与 1.3.0 主应用共用。实现、七个屏幕检查点及边界见 [ASS 增量记录](../../Docs/Testing/CompatibilityLab-ASS-2026-10-15.md)。

当前 R28 六项独立界面回归全部通过，最终独立 iPhone Release 编译通过。解码 PNG 在播放中请求，屏幕字幕 OCR 则暂停后独立采集；两种图像证据都保留。暂停定位要求五次连续时钟采样，再确认暂停意图。倍速测量等待输入稳定并开始推进，使用实际耗时而不是假定休眠长度。[最终结果 JSON](../../Docs/Testing/CompatibilityLab-ASS-results.json)保留历史失败、最终结果与源文件哈希；该结果没有关闭真机与生产分发门槛。

使用与主应用相同的 `PlaybackEngine`、`PlaybackResource`、`PlaybackEngineLifetime` 和核心模型。候选适配器只声明已实现的轨道能力，仅接受本地文件。它尚未实现生产级服务器流、预加载、时间轴预览、画中画、AirPlay、缓冲范围和 HDR 输出证据。

实际画面证据由当前媒体的 displayedPictures、可见窗口和非零尺寸共同触发，再要求本会话新生成的 PNG 含有原创测试图案的多种颜色；不以 ready 或时钟前进替代。截图是 libVLC 输出证据，屏幕呈现还须查看实际界面。初始化使用 start-paused；媒体轨道就绪不等于已出画面。

## 启动修订

首次验证漏嵌入动态 framework，出现 `DYLD / Library missing`；已添加独立 Embed Frameworks 阶段和构建时缺库检查。随后补齐 UIScene 生命周期，满足当前 iOS SDK 的启动要求。验证成功以 XCTest 与实际输出为准，不能只依赖构建工具报告“launch 成功”。

SDK 的 stop 是异步操作。停止立即取消业务回调并移除独立画布，旧播放器与文件访问租约保留至停止通知，再在后台释放底层播放器；仅等通知仍不足以保证底层释放不会等待主线程。验证程序在结果完成前要求所有旧会话清理完毕，快速退出同时覆盖立即、50 ms 和 100 ms 三种时机。

1.3.0 已接入主应用的本地播放流程；独立 1080p 真机 50 次开关和 30 分钟长播已通过，数据范围与主应用验收见 [1.3.0 报告](../../Docs/Testing/Glide-1.3.0-compatibility-2026-10-15.md)。上架前仍需完整传递组件材料、正式分发复核及计划承诺的输出专项。完整记录见 `Docs/Testing` 的兼容内核验证报告。
