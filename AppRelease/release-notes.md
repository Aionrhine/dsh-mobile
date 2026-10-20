## 功能更新

- 点击文件后立即打开预览面板，下载完成后直接显示内容；加载过程中关闭面板会停止当前下载。
- 文件加载新增实际下载进度百分比与 Whaleness Logo 循环动画，并改善关闭后重新打开预览的体验。
- 修复 Android 选择工作区目录时，列表滑到边界后继续上滑导致弹窗反复抖动的问题。
- 微调手机和平板首页的鲸鱼轮廓比例，使外形更加舒展。
- 更新 README 截图与功能说明，新增英文版文档。

## 必需插件

- 必须安装 [dsh-plugin-mobile-gateway](https://github.com/Clarklevis1995/dsh-plugin-mobile-gateway) `v0.10.3` 或更高版本。
- 安装或升级后，需要完整退出并重新启动 `dsh web`。

```bash
dsh plugin --profile web add dsh-plugin-mobile-gateway@latest
```
