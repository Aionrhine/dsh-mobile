# 文件格式图标

本目录保存已确认的 Figma 实心图标原始导出，包含 72 个格式：27 个直接复用 Untitled UI File Icons，45 个沿同一几何补充。图标本身为完整矢量，格式文字已转为路径，不依赖运行时字体。

- 设计稿：https://www.figma.com/design/BjWYaFHG2LKe85T844105j?node-id=77-2072
- 原始素材：https://www.untitledui.com/resources/file-icons
- 官方公开包：`@untitledui/file-icons`，版本 `0.0.9`，`package.json` 声明许可为 MIT。
- `manifest.json` 保存格式别名、颜色家族、Figma 节点与导出文件的 SHA-256。

Android 使用 Android SDK `Svg2Vector` 转换后的 VectorDrawable；iOS 使用保持原色的 SVG Asset Catalog。双端格式匹配在 `shared` 的 `FileIconCatalog` 中统一维护，扩展名和特殊文件名优先于 MIME，最后使用通用或未知格式图标。

带格式字样的图标只匹配对应格式或等价别名，例如 JPEG → JPG、CXX → C++。未覆盖的 HEIC、WAV、MOV、AAB、TAR/GZIP 等使用未知图标，避免显示成 WEBP、MP3、MP4、APK 或 7Z 等不同格式。目录继续使用原有文件夹图标。

卡片背景在浅色模式混合 8% 图标色与 92% `#FFFFFF`，在深色模式混合 16% 图标色与 84% `#1C1C1E`。背景为不透明混合色，避免叠加在不同父背景上产生色差。

重新导出后更新清单的素材哈希，再运行：

```sh
python3 scripts/generate_file_icon_assets.py
```

脚本仅使用本地素材和 Gradle 缓存中的 Android 官方转换器，不访问网络。它同步双端资源、iOS 明暗颜色、共享格式枚举和 Android 静态资源映射。格式识别只影响视觉，不改变下载、SHA-256 校验、预览或外部打开的判断。
