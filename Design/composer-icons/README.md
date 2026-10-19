# Android 输入区图标

Android 选用接近 iOS 原生图标的圆角轮廓样式；iOS 保留 SF Symbols 的 `keyboard` 和 `photo.on.rectangle.angled`。

- [Figma 选择与预览](https://www.figma.com/design/BjWYaFHG2LKe85T844105j?node-id=117-291)
- 来源：`lucide-static` 0.468.0 的 `keyboard`、`images`，许可见 `LICENSE`。
- 原始图标导入 Figma 后导出到 `svg/`，没有手工改绘路径。
- Android 使用 SDK 的 `Svg2Vector` 转为 VectorDrawable；保持 24 × 24 视口。
- 键盘入口显示为 24dp，图片入口为 22dp；颜色使用按钮或主题前景色。

`manifest.json` 记录来源、Figma 节点、显示尺寸和 SHA-256。
