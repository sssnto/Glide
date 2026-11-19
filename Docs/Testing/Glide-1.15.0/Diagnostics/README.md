# 诊断附件

最初 `simctl io screenshot` 默认读取外屏端口；Duo 展开后，该端口没有活动画面。`Inactive-Display-Captures/` 保留这些未被用作界面通过证据的截图。后续根据官方 `simctl io enumerate` 指定外屏 display 1、内屏 display 3，`Screenshots/*verified.png` 为指定活动屏后的截图。早期 JSON 中的会话与进度仍来自应用，但不能用对应的停用屏截图证明布局。

核心初轮 SDK／沙箱错误、界面初轮问题和自动化窗口坐标问题保留原日志；通过数量以最终验收记录为准。
