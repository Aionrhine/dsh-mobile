## 功能更新

- Android 与 iOS 新增应用字体大小设置，改善对话、审批、插件和设置页面在不同字号下的显示。
- 优化工作区侧栏拖拽时的触感反馈与界面响应，改善首页和侧栏之间的交互体验。
- 改善语音输入的录音启动、松手转写和取消响应，减少快速操作时的等待与状态异常。
- Android 更新检查及 APK 下载优先使用加速源，失败时回退 GitHub，并校验文件完整性与构建版本。
- 调整对话输入、语音面板和插件页面布局，改善键盘切换与滚动显示。

## 必需插件

- 必须安装 [dsh-plugin-mobile-gateway](https://github.com/Clarklevis1995/dsh-plugin-mobile-gateway) `v0.10.1` 或更高版本。
- 语音输入需在桌面端启用官方「语音输入」插件，并完成识别模型初始化。
- 安装或升级后，需要完整退出并重新启动 `dsh web`。

```bash
dsh plugin --profile web add dsh-plugin-mobile-gateway@latest
```
