# iOS 本地真机调试配置

将 `Local.xcconfig.example` 复制为 `Local.xcconfig`，填写：

- `LOCAL_BUNDLE_IDENTIFIER`：自己固定使用的调试 Bundle ID。
- `LOCAL_DEVELOPMENT_TEAM`：Xcode 账号对应的 Apple Team ID。

主应用、测试和 Live Activity 扩展的 Debug 配置共用这些值，测试和扩展自动追加对应后缀。`Local.xcconfig` 已加入 Git 忽略规则。Release 保留现有签名配置。

选择 Debug 构建后正常运行即可，无需修改 Xcode 中的 Bundle Identifier 或 Team，否则可能覆盖配置变量。本地文件缺失时使用示例 Bundle ID 和空 Team，需要填写本地配置才能真机签名。

此配置不向 Apple 注册标识符，也不会修复服务端的“标识符不可用”错误；如需更换调试标识符，只修改本地文件。
