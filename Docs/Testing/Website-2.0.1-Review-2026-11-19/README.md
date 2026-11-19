# 2.0.1 审核状态与 Duo 官网更新

2026-11-19（Asia/Shanghai）。用户反馈 2.0.1（11）已提交审核，要求更新官网。对外统一使用营销版本 **2.0.1 已提交 App Store 审核**，不展示易随送审变更的内部构建号，也不提前标为已上架。

## 内容

- 首页更新审核状态、搜索与分享摘要、版本卡片、下载说明和相关 FAQ。
- 新增 Duo 展示区：展开默认全屏、按需控制面板、前后台与尺寸变化后的片库排布、画中画快捷入口和中断修复。
- 发布说明新增 2.0.1 送审条目；2.0 工作台保留为设计演进记录，不沿用旧版“2.0 即将发布”状态。
- 帮助页补充 Duo 与画中画的操作、支持条件和问题反馈信息，保留系统与兼容路线的输出限制。
- 保持 App Store 链接、GitHub Pages 仓库、main 分支根目录、CNAME 与现有域名配置。

## 素材

三张公开素材均为 `Docs/Publishing/2.0.1/screenshots/duo-inner` 中 2.0.1（11）的原创演示模拟器截图，按字节直接复制，没有修改或裁切应用画面：

- `03-fullscreen-controls.jpg` → `Website/assets/duo-201-fullscreen.jpg`
- `02-library.jpg` → `Website/assets/duo-201-library.jpg`
- `04-control-panel.jpg` → `Website/assets/duo-201-panel.jpg`

没有使用用户私人片库、服务器地址或账号数据；没有制作模拟游戏／画中画悬浮窗图片。图片尺寸为 2007×2853，网页保持原比例并按断点重排。

## 检查与发布

- 5 页静态语义、141 个本地引用、CNAME 与 sitemap 检查通过；`site.js` 语法及网站 diff 空白检查通过。
- 原生 Chrome 检查桌面首页与 Duo 展示区，以及 390×844 窄屏的说明与单列截图布局。内嵌浏览器连接返回 `native pipe path unavailable`，因此改用已有 Chrome 的原生 CUA 控制；未使用其他浏览器自动化技术。
- 浏览器截图已在工具输出中视觉检查。本次未保存额外网页截图，也未做 DOM 溢出测量；具体范围见 `browser-check.json`。
- 通过 GitHub 连接器创建 10 个与本地校验值一致的文件 blob，再基于原有 tree 创建提交，以期望旧 HEAD 的非强制更新发布 main。其他网站文件保持不变。
- 官网仓库提交：`00394325832f05dcf18365225c747d876ede8bf6`，基于 `3097f5b7b92dca02c568bf303f184ad779a7d32a`。
- GitHub Pages 已报告该提交 `built`；公开域名逐文件的 HTTP／字节检查见 `deployment.json`。

网站源码镜像在应用仓库的 `Website/`；本次没有推送应用其他开发修改，也没有修改 App Store Connect 的审核提交。

记录文件：`static-check.json`、`browser-check.json`、`source-manifest.json` 和 `deployment.json`。
