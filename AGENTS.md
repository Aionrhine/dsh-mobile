# dsh-mobile（Whaleness）工作区说明

第三方 DeepSeek Harness 移动客户端。Kotlin Multiplatform：`shared` 模块是全部业务状态与纯逻辑的唯一来源；iOS 用 SwiftUI/UIKit（`DeepSeekHarnessMobile`），Android 用 Jetpack Compose（`androidApp`）。两端经 `dsh-plugin-mobile-gateway`（WebSocket）连接 Harness 桌面端。

本仓库是 fork：`origin` = Aionrhine/dsh-mobile，`upstream` = Clarklevis1995/dsh-mobile。定期合并 upstream（提交形如 `Merge upstream YYYY-MM-DD (...)`）；`scripts/apply-text-selection.py` 是本 fork 的差异补丁（幂等，CI 构建前自动应用），不要"顺手清掉"。

## 本机环境限制（重要）

此 checkout 在 Windows 上，**无 Java、无 ANDROID SDK、无 macOS**——下列所有构建/测试命令都无法在本机执行。改动验证只能：静态核对 + 推送后看 CI（`.github/workflows/ios-unsigned-ipa.yml`，push main 即触发）。声称"已验证"前先想清楚验证发生在哪。

## 构建与测试（需 macOS / Android SDK 环境）

```bash
./gradlew :shared:allTests                                    # KMP 跨平台单测（最重要门禁）
./gradlew :androidApp:testDebugUnitTest :androidApp:lintDebug :androidApp:assembleDebug
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64         # Apple Silicon 模拟器 framework
./gradlew :shared:iosSimulatorArm64Test                       # Kotlin/Native 测试
./gradlew :androidApp:installDebug                            # 安装 Debug APK
```

iOS 测试在 Xcode 打开 `DeepSeekHarnessMobile.xcodeproj`，选同名 scheme，Product → Test；`Build KMP Framework` 阶段会自动调 Gradle 编 framework，无需手工预编译。工具链：Java 17、Xcode 26+（部署目标仍 iOS 17）、Android compileSdk 36 / minSdk 24。

## 目录

- `shared/src/commonMain`（包：`protocol` `domain` `projection` `sync` `facade` `gateway` `cache` `platform`）— 协议 DTO、Reducer、投影、History 同步、粗粒度 facade；`commonTest` 为跨平台测试
- `DeepSeekHarnessMobile/` — iOS 应用（`Core/` 含 AppStore、KMPSharedAdapter、GatewayClient 等；`Views/` `Components/` `LiveActivity/` `Shaders/`）
- `DeepSeekHarnessMobileTests/`、`DeepSeekHarnessMobileUITests/` — iOS XCTest（含架构门禁与滚动性能测试）
- `AgentLiveActivityWidget/` — iOS 实时活动扩展
- `Vendor/swift-markdown-ui` — 本地 Swift 包（MarkdownUI）
- `Docs/` — 调研、KMP 迁移与各阶段验证记录；`Design/design-spec.md` — 设计规范
- `scripts/generate_project.rb` 是旧版 Xcode 工程生成脚本，检测到 Live Activity target 会主动 abort——**不要运行**

## 架构硬规则（改代码前必读 ARCHITECTURE.md）

- 业务状态只活在 KMP Store；UI 发 Intent，KMP 回有序 Event（state patch + effect descriptor），平台 Adapter 只校验 Event、维护 UI 镜像、执行平台 effect。
- `commonMain` 禁止任何平台 I/O：网络、磁盘、Keychain/Keystore、UIKit、Android framework 均不得进入。WebSocket transport 留在 Swift（URLSession）/ Android（OkHttp）是有意设计。
- Swift 侧：无平行 Reducer；`@Published` 镜像只能由 KMP Event 发布路径写入；Event 校验失败必须 fail-closed。Swift 只经 `KMPSharedAdapter` 访问 `SharedMobileFacade`，不直接碰 Kotlin Reducer/协程。
- 禁止恢复 Swift/KMP 双 Reducer、运行时迁移开关或 shadow 对比路径。
- Conversation/Trajectory 高频更新走增量协议（insert/append-delta/remove...），不对每个 token 做全量复制。

## 约定

- 文档、注释、README 以中文为主；近期提交信息为英文祈使句一行式。
- Gateway 最低版本（当前 `dsh-plugin-mobile-gateway` 0.10.3+）以 `AppRelease/release-info.json` 为准，不要在别处写死。
- 涉及滚动性能/阅读位置的改动，先读 `Docs/iOS滚动优先调度测量合同.md` 与相关验证文档；涉及发布流程看 `scripts/publish_r2_release.py`。

## 改动前建议阅读

`ARCHITECTURE.md`（全量，架构与测试门禁的 SSOT）→ `Docs/kmp-development.md`（模块边界与迁移规则）→ 敏感领域再读 `Docs/` 下对应文档（如 `multi-gateway-*`、`kmp-shadow-gap-analysis.md`、语音/历史分页各篇）。
