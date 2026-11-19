# Glide 2.0.1（11）发布材料

本次主题：**为 iPhone Duo 优化，展开精彩，观看更自在。**

## 文案

| 文件 | 用途 |
| --- | --- |
| `zh-Hans/release-notes.txt` | App Store「此版本的新增内容」 |
| `zh-Hans/promotional-text.txt` | App Store 宣传文本 |
| `zh-Hans/announcement.txt` | 社交平台或官网发布公告 |
| `release-copy.md` | 以上文案的汇总版 |
| `metadata-zh-Hans.json` | 版本号及对应中文文案 |

应用名、关键词、隐私政策和支持链接可继续使用现有内容。更新说明围绕本版本实际变化：Duo 布局、全屏播放、画中画及 Jellyfin 登录修复。

## 截图

图片来自 2.0.1（11）当前应用的真实模拟器界面。采用独立演示数据，仅包含原创视频及海报，无用户账号、服务器地址或私人媒体。直接采集活动屏幕，未拼接设备外壳、修改应用画面或添加不存在的功能。

| 目录 | 屏幕 | 尺寸 | 格式 |
| --- | --- | --- | --- |
| `screenshots/duo-inner` | iPhone Duo 展开内屏，竖向 | 2007 × 2853 | JPEG，无透明通道 |
| `screenshots/iphone` | iPhone 17，竖向 | 1206 × 2622 | JPEG，无透明通道 |

两组请放入 App Store Connect 对应屏幕分组，不要互相缩放替代。尺寸和格式依据 [Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)。本次新增 Duo 内屏及普通 iPhone 截图，现有 iPad 截图可继续沿用。

Duo 外屏本轮未重拍：官方折叠按钮受 Mac 锁屏影响，不能用内屏图片裁切代替。画中画实景也未放入截图：Duo 模拟器不支持系统画中画，本轮没有模拟游戏或悬浮窗画面。

### 推荐上传顺序

Duo 内屏：

1. `03-fullscreen-controls.jpg` — **展开精彩，沉浸观看**：展开后的全屏播放器。
2. `02-library.jpg` — **你的片库，随屏展开**：片库海报及媒体信息。
3. `04-control-panel.jpg` — **更多控制，随手可及**：手动打开的控制面板；这是可选布局。
4. `01-watching.jpg` — **打开 Glide，开始观看**：观看首页与快捷入口。
5. `06-library-dark.jpg` — **明暗之间，都很清晰**：原生深色片库。

普通 iPhone：

1. `02-library.jpg` — **随身片库，一目了然**。
2. `03-fullscreen-controls.jpg` — **播放操作，轻点即达**。
3. `01-watching.jpg` — **打开 Glide，开始观看**。
4. `06-library-dark.jpg` — **明暗之间，都很清晰**。

以上短句用于官网或社交图的配文；当前截图文件为原始应用画面，未叠加宣传标题。`05-fullscreen-picture.jpg` 是隐藏控制器后的纯画面，可作为补充素材，不建议作为商店首图。

## 验收与版本

- 正式归档版本：2.0.1（11），Bundle ID 为 `com.songpeng.glide`。
- 用户于本轮明确反馈已完成测试、新版本已适配 Duo；记录为用户验收反馈。
- 本轮截图通过公开演示素材的自动化导航采集，检查了首页、片库、播放画面、控制器及深色界面。
- 截图包不代表本轮重新做过实体 Duo 测试；画中画实机结论依据用户的线下验收反馈。
- `verification.json` 记录尺寸、透明通道、文件校验值及截图采集结果。

发布时选择 2.0.1（11）正式构建，再粘贴对应文案和上传截图。本材料包不包含测试应用，也未执行提交审核或对外发布。
