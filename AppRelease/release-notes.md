## 功能更新

- 新增工作区文件改动审阅视图并补齐审阅图标与多语言文案，支持用户消息 Markdown 渲染与会话时间分隔条。
- 支持划词引用回复、输入草稿按会话保留、相机拍照上传，以及通过 `dshmobile://` 链接按网关 ID 直达会话。
- iOS 会话图片支持全屏画廊预览与左右滑动翻页，修复未匹配生成图兜底预览问题。
- 改善流式 Markdown 显示稳定性、修复轨迹中模型耗时的计时起点，并持久化外观偏好设置。
- 改善后台任务日志续记与待办保留，优化 Apple Music 卡片播放状态反馈。

## 必需插件

- 必须安装 [dsh-plugin-mobile-gateway](https://github.com/Clarklevis1995/dsh-plugin-mobile-gateway) `v0.12.2` 或更高版本。
- 安装或升级后，需要完整退出并重新启动 `dsh web`。

```bash
dsh plugin --profile web add dsh-plugin-mobile-gateway@0.12.2
```
