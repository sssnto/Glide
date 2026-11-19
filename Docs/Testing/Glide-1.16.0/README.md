# 1.16.0（5）视频方向修正验收

构建 10 的 Jellyfin 12.2 服务器旋转、512 MiB 断线与服务重启验收见 [独立记录](Jellyfin-Server-Rotation-2026-11-10/README.md)。

后续构建 9 的视频文件缩略图见 [验收](WebDAV-Video-Artwork-2026-11-10/README.md)，构建 8 的有声无画面修复见 [原片验收](WebDAV-Playback-2026-11-10/README.md)。

后续构建 7 的播放器内旋转保存与目录视频封面见 [交互验收](WebDAV-Player-Interaction-2026-11-10/README.md)，构建 6 的 WebDAV 重复扫描修复与真机请求计数见 [独立记录](WebDAV-Directory-Cache-2026-11-10/README.md)；本页保留构建 5 的方向修正验收历史。

## 最终结果

- 核心完整回归 **255 项通过**：[日志](Logs/Core-Final.log)。其中 6 项覆盖矩阵组合、容器边界、文件变化拒绝写入、方向外全部字节保留，以及 AVFoundation 读取真实原创 MP4。
- 本机 HTTP WebDAV **10 项网络测试通过**，属于上述 255 项，不重复计数。覆盖有效锁、目标 ETag、失效锁的独立回退、两种保护均失效、并发修改、备份失败、MOVE 响应丢失后的持久化核对、目录越界，以及测试文件清理的名称／大小／完整摘要限制。
- iPhone 17 模拟器（iOS 26.3.1、Xcode 27.1）最终 **2 项 UI 测试通过**：完整连接、旋转预览、确认替换、备份还原和原创短片探针；独立验证包无 QA 启动参数时直接进入验证页。见 [日志](Logs/Simulator-UI-Final.log)、[预览](Screenshots/Rotation-Preview.png)、[完成](Screenshots/Rotation-Contract.png)。
- 用户 iPhone 13 Pro Max 与实际 WebDAV：最终构建 5 的 **9 项检查通过**，用户手动点击验证并反馈“显示‘验证通过’”，随后通过 devicectl 读取了构建号、时间均匹配的新报告。包括上传摘要、方向矩阵、方向外全部字节、系统播放器尺寸和可播放性、**实际解码后的视频帧尺寸**、完整字节还原、本轮自建文件清理、前轮遗留原创副本清理。见 [真机报告](iPhone-NAS-Final.json)。
- 独立「Glide 方向验证」和主应用「Glide」均已更新为 **1.16.0（5）**。主应用成功启动，原有片库和登录使用原数据容器；WebDAV 凭据不从独立包导出或跨应用复制。见 [安装记录](Device-Installation.json)、[主应用构建](Logs/Main-QA-Build.log)、[签名](Logs/Main-QA-Signature.log)。
- 最终正式 Release 编译、深度签名校验、静态预检通过：[构建](Logs/Release-Build5.log)、[签名](Logs/Release-Signature-Build5.log)、[预检](Logs/Preflight-Build5.log)。未生成本版本商店归档，未上传或分发到商店。

## 实际 NAS 差异与修正

首次真实目录验证返回保护检查失败。脱敏 HTTP 证据表明：LOCK 返回 200 和令牌，但未带令牌的覆盖 MOVE 仍返回 204。客户端原先在锁检查失败时直接结束，没有再独立验证另一种保护。见 [初始失败](iPhone-NAS-Initial-Failure.json)。

现在释放失效锁、清理本轮小文件，再以全新随机名称独立验证目标版本条件：错误 ETag 必须被拒绝，A／B 内容必须保留，正确 ETag 才允许 MOVE。该 NAS 实际通过了版本检查，后续替换均使用已验证的目标版本条件；不会仅因 LOCK 返回成功就信任锁，也不会去掉保护直接覆盖。见 [首次兼容通过](iPhone-NAS-Version-Protection.json)与最终报告。

遗留文件清理仅处理本应用生成的 UUID 名称、大小一致且完整摘要等于仓库原创短片的副本，DELETE 使用刚读取的 ETag。相似名称但内容不同的文件保留。未自动修改用户原有视频。

## 交互与验收边界

早期 UI 尝试存在编译及控件定位问题，未计为通过；选片后已增加自动定位到预览，左右按钮独立点击，弹窗使用明确标识。设备后续锁屏导致最后一次启动被拒绝，未使用旧报告冒充最终结果。独立包现按 bundle 标识直接进入验证页并保持亮屏，用户手动点击后完成最终验收。

真实 NAS 验证使用 58,319 字节的仓库原创 MP4，不包含用户视频、账号、密码、地址、完整 ETag 或锁令牌。报告中的 HTTP 记录只有方法、固定角色、状态码、版本标识类型及长度。该验证不替代用户具体片源的编码、大文件传输，以及 Jellyfin／Emby 刷新后的实际播放验收。实际片源须由用户在界面中选择、预览并确认后保存。

功能范围和恢复流程见 [说明](../../Glide-1.16.0-Video-Rotation.md)；[结构化结果](Validation.json)、[最终相关源码指纹](Source-Snapshot.json)。此次未提交、推送、打 tag 或上传商店。

## 重跑

本机服务：`python3 Scripts/rotation_webdav_fixture.py`，仅监听 `127.0.0.1:8828`，仅使用原创媒体与虚拟账号。

核心：`GLIDE_ROTATION_HTTP_FIXTURE=1 swift test --scratch-path /tmp/GlideRotationCore`。

UI：设置 `TEST_RUNNER_GLIDE_ROTATION_FIXTURE=1`，在 CompatibilityQA、独立 rotationqa bundle、单个模拟器和关闭并行测试的条件下运行上述两项测试。模拟器通过 `--glide-rotation-fixture` 隔离片库状态。

实际目录：打开「Glide 方向验证」，应用直接进入验证页并保持亮屏；在包内填写凭据，点“验证旋转保存与原样还原”。导出 `Documents/rotation-qa.json`。地址和凭据不写入仓库或导出报告。
