# Glide 1.2.1 播放内核与格式验证

日期：2026-10-15。开发构建 1.2.1（1），未发布。

## 环境与素材

专用 `Glide 1.2 QA` 模拟器（iPhone 17 Pro，iOS 27.0）；构建使用本机 Xcode。未连接真实 NAS／Jellyfin，未访问个人媒体。Jellyfin 集成回归通过项目测试服务，仅监听 `127.0.0.1:8768`。

`Scripts/generate_playback_fixtures.py` 以 FFmpeg testsrc2 与两种频率的正弦音生成原创 320×180、15 fps、20 秒样例；额外生成内嵌字幕、改后缀和截断变体。生成目录 `/tmp/Glide121/FormatFixtures`，附带文件大小、SHA256 和生成命令清单。素材仅复制到 QA 应用沙盒 `Library/Application Support/FormatFixtures`，不在应用资源包中。`--glide-format-fixtures` 仅 DEBUG 模拟器有效。

样例中的容器和编码组合只代表该文件；不能推广为所有同扩展名文件均可播放。模拟器结果不能证明真机硬解、HDR、杜比视界、多声道输出、功耗、画中画或 AirPlay。

## 核心与回归

- Core：89 项通过（86 项 Swift Testing + 3 项 XCTest）。新增覆盖旧装载／旧定位失效、容器头部／截断容错，以及未知元数据与纯音频／不可播放的区别。日志 `/tmp/Glide121/core-final.log`。
- 首轮播放接口回归：快速退出重开、暂停／恢复、下一条预热命中，2 项通过，`/tmp/Glide121/Engine-R1.xcresult`。
- 最终多音轨／内嵌字幕选择、关闭字幕、格式信息页与时间轴定位，2 项通过，`/tmp/Glide121/Tracks-Timeline-R2.xcresult`。信息页已进行截图检查，见 [验证画面](Glide-1.2.1-本机格式信息.png)。
- Jellyfin 黑屏直放 → 兼容流实际出画面、学习路线后重开，`/tmp/Glide121/Recovery-Black-R2.xcresult` 通过。
- Jellyfin 分片延迟后继续播放，`/tmp/Glide121/Buffering-R4.xcresult` 通过；从头起播小于 8 秒、延迟确实发生、观看时间继续超过 30 秒、仅一次 PlaybackInfo、原画重封装、recoveryCount 为 0、实际缓冲至少 8 秒且记录 buffering_recovered。脱敏结果见 [缓冲诊断](Glide-1.2.1-buffering-result.json)。
- HDR master 场景通过，`/tmp/Glide121/Recovery-HDR-R1.xcresult`：保留 master 验证，不走单变体解包，按请求输出 SDR；实际解码帧的 `outputColorTransfer=ITU_R_709_2`、`outputColorEvidence=decodedFrame`，恢复后有实际画面。流描述与实际解码帧的证据分别处理，不能仅凭压缩轨道元数据宣称输出已为 SDR。
- 静态发布预检通过。最终 Release 未签名设备目标编译通过，日志 `/tmp/Glide121/release-final.log`；唯一工具提示为未依赖 AppIntents 框架而跳过元数据提取，无 Swift 编译警告。

本轮累计通过 8 个不同界面用例，其中自动恢复分别执行黑屏与 HDR 两种服务场景，共 9 次成功用例运行；早期失败轮次保留用于追溯，不计入成功结果。Release 包确认为 1.2.1（1），不含格式样例目录或 DEBUG 测试启动入口。测试服务已在收尾时关闭；未提交、上传或发布。

## 原生格式实测

两组矩阵均通过：`Formats-Main-R2.xcresult`、`Formats-Edges-R2.xcresult`，保存在 `/tmp/Glide121/`。每个样例记录显示层是否出画面、系统检查与诊断，测试成功不等于所有样例都可播放；失败样例的错误路径也是验收内容。

| 合成样例 | 实际封装／源编码 | 原生实际画面 | 检查结果 |
| --- | --- | --- | --- |
| 01-h264-aac.mp4 | MP4，H.264／AAC | 有 | avc1，1 视频、1 音频 |
| 02-hevc-aac.mp4 | MP4，HEVC／AAC | 有 | hvc1，1 视频、1 音频 |
| 03-h264-aac.mkv | Matroska，H.264／AAC | 无 | 系统拒播，识别 Matroska 文件头 |
| 04-mpeg4-mp3.avi | AVI，MPEG-4 Part 2／MP3 | 无 | 系统拒播；能读到 FMP4 视频描述，不能据此声称可播放 |
| 05-renamed-mkv.mp4 | Matroska，扩展名改为 mp4 | 无 | 系统拒播；仍识别 Matroska |
| 06-truncated.mp4 | MP4，仅保留前 128 字节 | 无 | 系统拒播／失败提示，封装提示仍可用 |
| 07-audio-only.mp4 | MP4，仅 AAC 音频 | 无 | 系统允许播放但视频轨道为 0，应用提示没有视频轨道 |
| 08-multi-track.mp4 | MP4，H.264、双 AAC、mov_text | 有 | 1 视频、2 音频；系统可选字幕项为 2 |

脱敏原始结果与样例 SHA256 已保存为 [JSON 记录](Glide-1.2.1-native-format-results.json)。`subtitleTracks` 字段统计系统 legible 选择组中的可选项，可能包括系统派生的强制字幕选项，不是对原始字幕流数量的断言。测试检查实际画面与选择状态；未完成 ASS／PGS 排版或所有字幕字符的验收。

## 首轮发现与修订

截断 MP4 的系统错误不保证立即返回；首轮界面测试的 25 秒等待先于应用的启动超时，导致 `Formats-R1.xcresult` 的矩阵用例失败。将测试预算增至 35 秒，保留应用超时策略；本地超时改为文件完整性／兼容性提示。文件头结果先独立展示，异步元数据仍未知时明确显示未完成检查。系统明确拒播且没有实际画面时给出对应提示；不按后缀拒播。该轮不能计为矩阵整体通过。

服务器恢复首轮 `Recovery-Black-R1.xcresult` 停在登录表单，没有进入播放。通过 DEBUG 模拟器专用准备流程确认未签名测试构建写钥匙串返回 `-34018`。随后仅在模拟器测试构建使用临时 ad hoc 签名和测试 entitlement，生产 Credentials.save／read 路径完成保存并读到媒体库；没有将测试凭据改为明文存储，也没有修改 Release 签名配置。

缓冲前三轮没有整体通过：R1 切换服务模式后目录缓存仍是旧清单；专用 DEBUG 准备流程清理该测试账号缓存后进入场景。R2 的复制原 GOP 造成实际分片为交替 10.4／1.6 秒，未形成预期持续缓冲；测试素材改为固定 4 秒关键帧并在生成时断言分片长度。R3 暴露「从头播放」仍复用旧续播位置、跳过延迟片段的问题；将起播位置从独立详情页状态移入 PlaySelection，并增加从零起播断言后，R4 全部通过。播放器原有持续缓冲策略和测试恢复条件均保留。

## 复现要点

1. `python3 Scripts/generate_playback_fixtures.py /tmp/Glide121/FormatFixtures`。
2. 在专用模拟器安装 Debug 应用，将该目录复制至上述 QA 沙盒位置。
3. 设置测试 runner 环境 `GLIDE_FORMAT_FIXTURES=1`，依次运行 `testNativeFormatMatrix`、`testNativeFormatEdgeCases`、`testNativeTrackSelection`。
4. Core 使用 `swift test`；受限环境可把 clang／SwiftPM module cache 与 scratch path 指向 `/tmp/Glide121/`。
5. 集成恢复采用 `Scripts/fixture_server.py`：黑屏场景 `GLIDE_BLACK_FRAME_FIXTURE=1`，持续缓冲后恢复场景 `GLIDE_BUFFERING_FIXTURE=1`，分别启动、执行对应测试、关闭，避免混用。测试 runner 设置 `GLIDE_JELLYFIN_FIXTURE=1`，会启用仅 DEBUG 模拟器存在的 `--glide-jellyfin-fixture`；固定连接本项目 loopback 合成服务，仍走正式认证与钥匙串存储。

本机模拟器测试使用 `/tmp/Glide121/Simulator.entitlements`，`application-identifier` 和 `keychain-access-groups` 为 `GLIDEQA001.$(PRODUCT_BUNDLE_IDENTIFIER)`，`get-task-allow=true`；构建覆盖 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGN_ENTITLEMENTS=/tmp/Glide121/Simulator.entitlements`。此覆盖未写进项目。Release 编译独立使用 `CODE_SIGNING_ALLOWED=NO`，真机按自己的开发团队正常签名。

真机授权目录／iCloud 下载、超大目录、旧设备、HDR／杜比及第三方内核尚待独立验收。WebDAV 本轮未新增功能。
