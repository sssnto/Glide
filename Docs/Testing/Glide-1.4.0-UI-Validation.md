# Glide 1.4.0 界面与交互验证

日期：2026-10-16。开发版本：1.4.0（1），未上传 App Store Connect。

本轮覆盖片库、详情、轨道选择、播放器、个人片库、离线和设置。设计规则见 [界面与交互设计](../Glide-1.4.0-Design.md)。验证使用应用自带演示和仅监听 127.0.0.1 的合成 Jellyfin 服务，无需真实媒体、服务器账号或用户密码。

## 已完成的回归

| 验证 | 结果与范围 |
| --- | --- |
| 核心逻辑 | 100 项通过：4 项 XCTest、96 项 Swift Testing。 |
| iPhone 页面流程 | 电影墙、详情、播放、倍速、音轨可用状态、字幕、设置、个人片库和离线页面通过。 |
| 播放控制 | 竖屏／紧凑横屏、暂停、时间定位、设置打开时保持显示、自动隐藏后轻点唤起通过。 |
| 辅助大字号 | AXXXL 的片库、详情、轨道选择与语言设置流程通过；保留 Dynamic Type。 |
| 范围与固定目录 | 包含子目录／仅当前层、搜索、排序、播放队列、固定规则、重启恢复、编辑及移除通过。 |
| iPad 页面流程 | 侧栏、片库、详情、播放快捷菜单、轨道选择、设置、个人片库和离线页面通过。 |
| 家庭视频新默认 | iPhone、iPad 均通过：竖版卡片、逐层进入／返回默认媒体、顶部切换、手动目录模式下刷新、重启恢复媒体默认值。 |
| 目录竖版与浏览密度 | 最终 iPhone 用例通过：媒体库入口、子目录和视频均为竖版，常规宽度显示三列；包含逐层进入、切换和重启回归。 |

上表是相应交互用例的验证范围，未执行整个历史 UI 测试集。iPad 首次冷启动使 MCP 调用超过 300 秒，底层测试继续完成；实际 xcresult 为 1 项通过、0 项失败，已单独读取结果核实。目录统一竖版及列宽调整后，最终 iPhone 用例再次通过（61.067 秒）；iPad 此项最后的视觉微调尚未单独重新截图，默认浏览流程已有通过结果。

最终真机包的构建身份见 [device-build.json](Glide-1.4.0-UI/device-build.json)，同时记录主程序和调试 dylib 的 SHA256。签名校验通过；连接恢复后已安装至 iPhone 13 Pro Max。自动启动被 iOS 锁屏拒绝，解锁后可手动打开「Glide 兼容验证」；最终包的真机启动和人工验收尚待完成。

## 滚动、分页和缓存证据

合成电影库包含 38 个条目，按每页 12 个返回。滚动测试已遍历全部 38 项，详情返回后的条目锚点偏移 1pt。首卡两次采样均为 115.33 × 251.67pt；重复进入同一详情后，详情请求保持 2 次、海报请求保持 4 次，没有重复增长。原始结果见 [scroll-measurements.json](Glide-1.4.0-UI/scroll-measurements.json)。

海报网络加载完成前的瞬间未被直接采样，因此这组结果只能证明采样之间、分页及返回过程的几何稳定性。源码使用固定画布、稳定身份、按尺寸降采样和取消检查；下载海报改为异步 ImageIO 解码，目录排序移出滚动更新路径。尚未测量真实大库的滚动帧率，也未据此宣称达到固定 FPS。

## 截图

- [主要页面预览](Glide-1.4.0-UI/preview.png)
- [媒体库入口](Glide-1.4.0-UI/phone-family-libraries.png)、[家庭视频媒体](Glide-1.4.0-UI/phone-family-media.png)、[顶部目录切换](Glide-1.4.0-UI/phone-family-directories.png)
- [iPhone 片库](Glide-1.4.0-UI/phone-catalog.png)、[详情](Glide-1.4.0-UI/phone-detail.png)、[播放器](Glide-1.4.0-UI/phone-player.png)、[横屏](Glide-1.4.0-UI/phone-player-landscape.png)
- [辅助字号片库](Glide-1.4.0-UI/phone-ax-catalog.png)、[辅助字号详情](Glide-1.4.0-UI/phone-ax-detail.png)
- [iPad 片库](Glide-1.4.0-UI/ipad-catalog.png)、[iPad 详情](Glide-1.4.0-UI/ipad-detail.png)、[iPad 播放](Glide-1.4.0-UI/ipad-player.png)

截图为实际模拟器运行结果，样片仅用于展示布局。真实服务器的字段缺失、超长标题、网络状况与真机触控手感仍需结合日常使用复核。
