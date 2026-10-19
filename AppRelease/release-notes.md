## 功能更新

- 修复代码文件预览中长行无法左右滑动的问题；Markdown 文件支持「源码 / 预览」切换，并保留各自的阅读位置。
- 优化双端文字与语音输入切换，使用独立的「按住说话」区域，改善录音浮层的出现动画，避免长按编辑文字时误触录音。
- 优化 iOS 和 Android 插件页面的图标加载与列表滚动流畅度。
- 修复 iOS 加载更早对话时跳到顶部和滚动卡顿的问题，加载后保留当前阅读位置。
- 对齐 Android 文件预览切换控件的 iOS 风格，收紧文件卡片的文字行距。

## 必需插件

- 必须安装 [dsh-plugin-mobile-gateway](https://github.com/Clarklevis1995/dsh-plugin-mobile-gateway) `v0.10.3` 或更高版本。
- 安装或升级后，需要完整退出并重新启动 `dsh web`。

```bash
dsh plugin --profile web add dsh-plugin-mobile-gateway@latest
```
