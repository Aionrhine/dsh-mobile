## 功能更新

- Android 与 iOS 新增按住说话、上滑取消和语音转写，识别结果回填草稿，由你决定何时发送。
- 新增插件管理入口，可查看插件与组件详情、切换启用状态。
- Android 新增启动时后台检查更新，支持跳过指定版本、下载 APK 并进入系统安装流程。
- Android 与 iOS 的“关于”页新增要求网关版本、已连接网关版本和本版本发布说明，并支持打开 GitHub 页面。
- 修复 Android 隐私政策正文滚动和发布说明 Markdown 渲染，缩小隐私政策标题栏空隙并减轻按钮阴影。
- DSH 主机信息显示网关上报的 DSH 版本，移除 Provider 与模型条目。
- 完善定时任务搜索、状态筛选与任务详情展示。
- 优化对话输入、键盘切换、工作区抽屉和长名称显示。
- 改善后台连接保持与回到前台后的断线恢复，手动断开后不再自动重连。
- 统一 Whaleness 图标、启动页与实时活动视觉，补齐英文界面和审批提示。

## 必需插件

- 必须安装 [dsh-plugin-mobile-gateway](https://github.com/Clarklevis1995/dsh-plugin-mobile-gateway) `v0.10.1` 或更高版本。
- 语音输入需在桌面端启用官方「语音输入」插件，并完成识别模型初始化。
- 安装或升级后，需要完整退出并重新启动 `dsh web`。

```bash
dsh plugin --profile web add dsh-plugin-mobile-gateway@latest
```
