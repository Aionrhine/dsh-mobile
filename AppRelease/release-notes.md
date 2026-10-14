## 功能更新

- 修复 Android 首页右滑打开侧边栏时的严重卡顿，改善首页拖拽和滚动流畅度。
- Android 与 iOS 新增按住说话、上滑取消和语音转写，识别结果回填草稿后可编辑并发送。
- Android 新增启动时后台检查更新，支持跳过指定版本、下载 APK 并进入系统安装流程。
- 两端“关于”页新增网关版本要求、已连接网关版本和本版本发布说明，并支持打开 GitHub 发布页。
- 修复 Android 隐私政策正文滚动和发布说明显示，改善对话输入与键盘切换体验。
- 改善插件开关操作时的状态显示，减少切换过程中的界面闪烁。
- DSH 主机信息显示网关上报的 DSH 版本，简化主机信息展示。

## 必需插件

- 必须安装 [dsh-plugin-mobile-gateway](https://github.com/Clarklevis1995/dsh-plugin-mobile-gateway) `v0.10.1` 或更高版本。
- 语音输入需在桌面端启用官方「语音输入」插件，并完成识别模型初始化。
- 安装或升级后，需要完整退出并重新启动 `dsh web`。

```bash
dsh plugin --profile web add dsh-plugin-mobile-gateway@latest
```
