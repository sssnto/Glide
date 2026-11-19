# 双指捏合卡顿修复 · 2026-11-06

用户确认问题发生于播放中的双指捏合放大、缩小。当前源码版本为 1.15.0（2）；此次修改保留工作区已有的 Duo、推荐信息和商业化实验改动。

## 定位与修改

`GestureVideoView.applyTransform()` 原先在每次手势回调及后续布局中，将视频／字幕的 transform 清零、重新写 frame，再设置缩放。兼容内核的 UIKit 视图及其自动调整尺寸的 drawable 也走这条路径。另一个高频路径是每次 pinch 都调用 PlayerView 的 `showHUD`，修改整页状态并取消、重建隐藏 Task。

现在用稳定的内容容器同步变换视频与两层 ASS；手势只更新容器 transform，真实视口变化才通过 bounds／center 调整解码器与字幕尺寸。初次挂载和横竖屏尺寸变化仍会调整 VLCKit 的子视图，保留原有 AVPlayerLayer、播放会话、缩放焦点和偏移边界。缩放提示改由播放器 UIView 内的标签更新，结束时才安排一次隐藏；其他快进、倍速提示保留。无变化的无障碍值不再重复写入。

该几何处理遵循 Apple 对 [UIView.frame](https://developer.apple.com/documentation/uikit/uiview/frame) 的说明：已变换的视图应使用 bounds／center 调整几何。

## 验证

相同 UIKit 几何探针连续执行 480 次缩放：

| 解码器视图属性写入 | 修复前 | 修复后 |
| --- | ---: | ---: |
| frame | 959 | 0 |
| bounds | 0 | 0 |
| transform | 1918 | 0 |

该探针将带计数的 UIView 接入实际 `GestureVideoView`，并带一个自动调整尺寸的子视图，覆盖兼容内核的几何接口；计数阶段不执行视频解码。这是 UIKit setter 的次数，**不是视频帧率或掉帧测量**。探针检查还覆盖字幕与视频坐标对齐、子视图尺寸、真实视口变化、非法倍率、缩放复位，以及原生层和 player 身份。原始记录见 [Baseline.json](Baseline.json)、[Fixed.json](Fixed.json)。

- iPhone 17 模拟器：**4 项 UI 测试通过**，包括几何契约、系统内核 4K 连续捏合、兼容内核 4K 连续捏合，以及 ASS 双内核原始字体／颜色／运动回归。每个 4K 用例执行三轮放大、缩小，保持会话、AVPlayerLayer 和打开次数，进度继续前进，无播放错误。见 [日志](Logs/Simulator-UI.log)。
- 用户 iPhone 13 Pro Max（iOS 27.0.1）：[真机几何探针](iPhone-Geometry.json) **9 项通过**，480 次缩放中解码器视图的 frame、bounds、transform 重复写入均为 0。
- 真机实际 4K 播放：在生产 `PlayerView` 内，分别使用系统与兼容内核，直接驱动同一个缩放方法；每个内核三轮播放中放大／缩小、一轮暂停中放大／缩小，**各 9 项通过**。确认实际解码尺寸 3840×2160、进度继续前进、暂停位置不动、媒体／内核／播放层身份和打开次数保留，最终缩放复位。见 [系统内核](iPhone-4K-Native.json)、[兼容内核](iPhone-4K-Compatibility.json)。这是应用内方法驱动，不是物理触控自动化。
- **用户真机手动确认通过**：自动回归结束后，手机停留在原创 4K 兼容播放；用户按提示亲手放大、缩小三次，反馈“已经顺畅，没有明显卡顿”。此反馈对应该 4K 样例，不扩展为所有私人片源均已验收。
- XCTest 真机触控通道：无线连接和用户恢复 USB 后都在执行测试前以 code 74 退出，日志显示通道被拒绝及 IDE 断开；未确认根本原因，不将失败运行记为触控自动化通过。见 [首次失败日志](Logs/Device-UI.log)、[USB 重试](Logs/Device-USB-UI.log)、[运行器输出](Logs/Device-Runner-Error.txt)。
- 最终 Release 编译及签名校验通过，见 [构建日志](Logs/Release-Final-Build.log)、[签名结果](Release-Signature.txt)。最终新增的真机驱动入口均在 DEBUG 条件内。

真机应用内回归以目标 60 Hz 的 CADisplayLink 记录主线程显示回调间隔：系统内核 P95 约 17.1 ms、最大 58.1 ms；兼容内核 P95 约 24.1 ms、最大 52.2 ms。采样覆盖播放缩放、暂停切换与暂停缩放，**不等于视频帧率或视频掉帧率**；未采集修复前同条件的真机显示回调基线，不据此声称帧率提升百分比。

4K 样例由仓库原创 `demo0.mp4` 放大至 3840×2160、H.264、24 fps，再以流复制循环至五分钟；不含用户片源或账号信息。元数据与 SHA-256 见 [Fixture.json](Fixture.json)。这验证实际高分辨率播放与手势链路，不代表所有编码、网络或极高码率片源的性能。

截图：[系统内核缩放复位](Screenshots/4K-Native.png)、[兼容内核](Screenshots/4K-Compatibility.png)、[ASS 原始样式](Screenshots/ASS-Compatibility.png)。

## 重跑

1. 运行 `build-for-testing`，将生成的原创 4K 文件通过 `simctl`／`devicectl` 复制到测试应用 `Documents/ZoomQA4K.mp4`。
2. 设置 `TEST_RUNNER_GLIDE_ZOOM_FIXTURE=1`，运行 `testVideoZoomGeometryContract`、`testPinchNative4KContinuity` 和 `testPinchCompatibility4KContinuity`。
3. `--glide-zoom-probe --glide-duo-fixture` 只运行几何探针，报告写入 `Documents/VideoZoomQA.json`。测试素材与入口均为 DEBUG 专用。
4. 真机触控驱动不可用时，可启动 `--glide-duo-fixture --glide-ui-audit --glide-zoom-4k --glide-zoom-inapp-probe -localPlaybackEngine avPlayer`，再以 `vlc` 重跑；分别生成 `Documents/VideoZoomPlaybackQA-avPlayer.json`、`Documents/VideoZoomPlaybackQA-vlc.json`。使用 devicectl 时，应用参数前须用 `--` 分隔，避免将 `-localPlaybackEngine` 误解析为工具选项。

[结构化结果](Validation.json)、[本次相关源码指纹](Source-Snapshot.json)。当前修改未提交、推送或发布。
