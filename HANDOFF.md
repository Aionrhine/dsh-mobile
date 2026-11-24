# dsh-mobile 交接文档

> 交接时间：2026-11-24（午间更新）
> 仓库：`Aionrhine/dsh-mobile`（fork，上游 `Clarklevis1995/dsh-mobile`）
> 当前代码基线：`661065c`，CI 绿色（run `45323786890`），IPA 已发布（含设备连接器 + 系统分享扩展 + GenUI v0.17.0）

---

## 一、项目是什么

第三方 DeepSeek Harness 移动客户端（Whaleness）。Kotlin Multiplatform：

- `shared/` — 全部业务状态与纯逻辑（KMP），唯一真相源
- `DeepSeekHarnessMobile/` — iOS（SwiftUI/UIKit）
- `androidApp/` — Android（Jetpack Compose）
- 两端经 `dsh-plugin-mobile-gateway`（WebSocket）连桌面端 DSH

**架构硬规则**（改代码前必读 `ARCHITECTURE.md`）：
- 业务状态只活在 KMP Store；UI 发 Intent，KMP 回 Event
- `commonMain` 禁止任何平台 I/O
- Swift 侧无平行 Reducer，只经 `KMPSharedAdapter` 访问 `SharedMobileFacade`
- 禁止恢复 Swift/KMP 双 Reducer

---

## 二、当前状态（2026-11-23）

| 项 | 值 |
|---|---|
| 代码基线 | `661065c` |
| CI | 绿色（`ios-unsigned-ipa` run `45323786890` / `Localization checks` run `45323788255`） |
| IPA | [unsigned-20261124-v1.8.4-batch2](https://github.com/Aionrhine/dsh-mobile/releases/tag/unsigned-20261124-v1.8.4-batch2)（含主 App + 3 个 `.appex` 扩展） |
| 版本号 | `AppRelease/release-info.json` = 1.8.4 (build 43) / 网关 0.12.2 |
| 上游落后 | C 档第一批 + 第二批（`devicetools` / Share & Action Extension）全部完成；仅余 DS Bot 模式按需项 |

### 本轮会话完成：C 档第一批 + GenUI v0.17.0 + C 档第二批（`db2215c` ~ `661065c`）

| 提交 | 内容 |
|---|---|
| `db2215c` | 语音输入 ObjC 异常防护（`VoiceAudioExceptionGuard` + Bridging Header）、本地化 `Vendor/SwiftMath` 公式补丁（`\boxed`/`dfrac`/`operatorname`/`iint`/`tag`）、Markdown 表格图片列宽、KMP `SharedChatHistoryCache` `@Throws` 标注、移除已废弃 WebRTC 升级路径与 SPM 依赖 |
| `5445650` | 跨设备问答历史还原（`QuestionAnswerProjection`）、新建会话独立选择工作区（`SharedNewConversationWorkspace` + 草稿重绑 + `DshWorkspace` 图标）、Agent Team 团队模式开关（`TeamModeSnapshot` + 更多菜单开关 + 停用二次确认弹窗） |
| `90cca0f` | 网关连接方式分类与记忆（LAN/公网/Tailscale、`recentSuccessfulEndpoints`、重配保留其他方式地址）、`ImagePreprocessor` 可配置压缩上限、定时任务轨迹竞态与归档会话过滤修复、本地化收口（1618 条 iOS 文案通过） |
| `61fd132` | 移除 `AppStore.swift` 中遗留的 `isDraftWorkspaceReplacement` 旧 stub（消除重名编译冲突） |
| `5492b8b` | 修复 GenUI `evaluateJavaScript` 返回 `Promise` 触发 `WKErrorJavaScriptResultTypeIsUnsupported` 导致全部渲染失败的问题 |
| `ae109a5` | 升级内置 GenUI 运行库与引擎至 `@changfenhuang/dsh-genui@0.17.0`（支持 `computed`/`$computed`/`currency`/`carousel`/`map`，新增 `icons.js` & `maplibre.js` 按需加载） |
| `1abaf58` | 蒸馏 iOS 设备连接器体系（`devicetools`：日历/提醒/健康/位置/地图卡片/Apple Music 卡片/相册/闹钟、`ConnectorsView`、16 套资产与 `Info.plist` 权限） |
| `658bd35` | 接入 `ShareExtension` & `ActionExtension`（`ShareInbox`、`IncomingShareCoordinator`、`Sharing.entitlements` 与双扩展 Target） |
| `661065c` | 修复 `project.pbxproj` 中 4 个扩展 `XCBuildConfiguration` 块闭合语法并统一版本号为 `1.8.4 (43)` |

### 上一轮（2026-11-23 下午）完成的四件事（`998ca83` ~ `d10b1aa`）

| 提交 | 内容 |
|---|---|
| `998ca83` | 同步上游 `953e4ab`（版本号 `1.8.4` / build `43`、网关 `0.12.2`、发布说明、`Localizable.xcstrings` 三方键级合并），并从 `f36c872` 补齐 `WorkspaceChangesView` 缺失的 4 个审阅 SVG 图标集与许可证 |
| `2d0fd7c` | 蒸馏上游 `86d702d` iOS 会话图片画廊与工作区 Markdown 图片加载（`WorkspaceMarkdownImageLoader`、`WorkspaceMarkdownImageContext`、`MarkdownImageAsset`、`ConversationImageGalleryModel`、`SessionConversationImageGallery`），完整保留划词引用 |
| `819dec8` | 优化「跳转到轮次」：`TurnJumpSheet` 倒序展示；`AppStore` 新增本地 SQLite 缓存按 `seq` 毫秒直达（复用 `presentSearchContext`）；`ConversationView` 改用 `.task` 异步回溯循环 + 优先按 `seq` 精确匹配 + 顶部可取消进度胶囊，根治卡死与重复短句误匹配 |
| `d10b1aa` | iOS GenUI 全面加固：`genui.html` 原地卸载重挂与脚本去重 + `#root` 可缩矮测量 + `fontScale` 联动；`GenuiBlockView` 200ms 流式防抖原地重挂、共享 `WKProcessPool`（并发上限 `6`）、`GenuiRuntime.prepareAsync` 异步准备不阻塞主线程、捕获 JS 执行错误，并新增 `GenuiBlockViewTests.swift` |

### 上一轮会话完成的两件事

**1. 划词引用修复**（`eaf3f8f`）

原 bug：引用条被塞进 `ComposerAttachmentStack` 的 preview 槽，显示条件是 `composerExpanded && hasContent`（有图片/文件），划词时输入框没聚焦、引用也不是附件 → 引用条永不显示。

修法（`ConversationView.swift`）：
```swift
// 1646 行
let hasQuoteContent = !quoteInbox.isEmpty || selectionOffer.excerpt != nil
return ComposerAttachmentStack(shown: composerExpanded || hasQuoteContent,
        hasContent: ... || hasQuoteContent) {

// 2125 行：点引用后直接弹键盘
composerIsFocused = true
```

**2. 上游蒸馏 10 项**（`fd5c3f9` ~ `86a5fed`）

| 提交 | 内容 |
|---|---|
| `8e7c9de` | 会话时间分隔条 + 地图名本地化 |
| `f86f005` | 工作区文件变更 UI + 用户消息 Markdown 渲染 |
| `c714a2b` | 上述 UI 的多语言 |
| `37f1d89` | composer 草稿保留 + 音乐播放确认 |
| `f8c5b76` | 轨迹模型计时从请求起点算 |
| `bb981a6` | 流式 Markdown 身份稳定 + Apple Music 卡片修复 |
| `852d34e` | `dshmobile://` 链接按网关 ID 直开会话 |
| `e20bfd7` | 外观偏好持久化 + 未匹配生成图兜底 |
| `f4bb701` | composer 相机拍照 |
| `b7f27e8` | 后台任务日志续记 + 待办保留 |

---

## 三、⚠️ 最重要的教训：Swift 编译验证

**本机（Windows）无 macOS、无 Java、无 Android SDK，无法编译任何东西。**

### 唯一可靠的本地验证手段：cue 服务器

cue = `100.64.0.13`（tailscale），有 `/opt/iosbuild/`（5.1G，Swift 6.3.1 Linux 编译器 + iPhoneOS26.5 SDK + ld64.lld）。

连接：
```bash
wsl.exe -d Ubuntu-24.04 -e bash -lc "ssh -i /root/.ssh/hermes-ssh root@100.64.0.13"
```

**typecheck 工作流**（脚本在 `/tmp/cue-typecheck.sh`，也可从本文档复制）：

```bash
# 1. 本地打包源码
cd "D:/DeepSeek Harness/workspace/dsh-mobile"
git archive HEAD --format=tar DeepSeekHarnessMobile Vendor/swift-markdown-ui > /tmp/swift-src.tar

# 2. 传到 cue
wsl.exe -d Ubuntu-24.04 -e bash -lc "scp -i /root/.ssh/hermes-ssh /mnt/d/.../swift-src.tar root@100.64.0.13:/tmp/"

# 3. cue 上解包 + typecheck
ssh ... 'cd /tmp && rm -rf dsh-src && mkdir dsh-src && tar -xf swift-src.tar -C dsh-src && bash /tmp/cue-typecheck.sh'
```

脚本内容：
```bash
#!/bin/bash
set -u
cd /tmp/dsh-src/DeepSeekHarnessMobile
SDK=/opt/iosbuild/sdk/iPhoneOS26.5
SWIFT=/opt/iosbuild/swift/usr/bin/swiftc
find . ../Vendor/swift-markdown-ui/Sources -name '*.swift' \
  | grep -v 'Extensibility/CodeSyntaxHighlighter' \
  | grep -v 'Theme/Theme.swift' > /tmp/swift-files.txt
timeout 500 "$SWIFT" -typecheck \
  -sdk "$SDK" -target arm64-apple-ios17.0 \
  -I /opt/iosbuild/swift/usr/lib/swift_static/shims \
  -I /opt/iosbuild/swift/usr/include \
  $(cat /tmp/swift-files.txt | tr '\n' ' ') > /tmp/typecheck.log 2>&1
grep -c 'error:' /tmp/typecheck.log
grep 'error:' /tmp/typecheck.log | head -10
```

**预期结果**：只剩 1 个错误 `no such module 'DeepSeekHarnessShared'`（KMP 产物，CI 会提供）。除此之外零错误 = 可以推。

### 关键坑（血泪教训）

1. **cue 的 Swift 6.3.1 比 CI 的 Xcode 26.6 新**。cue 通过 ≠ CI 通过。
   - 具体案例：`func chatXxx(_ base: some View) -> some View` 这种 opaque 参数方法链，cue 认，Xcode 26.6 报 `some View has no member`。
   - **修法：改用中间 let 变量**，每步类型显式：
     ```swift
     let v1 = content.overlayPreferenceValue(...)
     let v2 = v1.onPreferenceChange(...)
     return v2
     ```

2. **Python 脚本批量改大文件不可靠**。正则边界匹配出错会留下孤儿代码或误删。改完必须做双重验证：
   - 修饰符序列比对（`grep '^\s*\.' | sed 's/(.*//'`）
   - 逐行文本 diff（0 diff 才算过）

3. **CI 每轮 20 分钟，一次只报第一个致命错误**。不要盲推，本地能验的必须验完。

4. **`git add -A` 会带上未跟踪杂物**（`tmp/`、`package.json`）。用 `git add -A ':!package.json' ':!tmp'`。

---

## 四、fork 与上游的差异（合并时必须保留）

| 文件 | fork 的改动 | 上游的改动 | 合并策略 |
|---|---|---|---|
| `Vendor/.../InlineText.swift` | **无图分支走 `SelectableInlineText`（UITextView）**，实现划词引用 | 上游删掉了这个分支 | **必须保留 fork 版**，否则引用功能全废 |
| `ConversationView.swift` | 引用条显示条件、`composerIsFocused = true`、chatContent 中间 let 链 | 上游持续改动 | 手工解，保留 fork 的引用逻辑 |
| `Localizable.xcstrings` | 6 个 GenUI 键 + 引用相关键 | 上游大量新增 | JSON 三方键级合并（见下） |
| `DeepSeekHarnessMobileApp.swift` | DEBUG 分支含相机/审阅 harness | 上游含 Gallery/Connector harness | 保留 fork 有的，删掉依赖缺失的 |
| `AGENTS.md` | fork 的工程说明 | 上游换成了视频约定 | 保留 fork 版 |

### xcstrings 冲突的正确解法（JSON 三方合并）

```python
import json, subprocess
def get(ref):
    return json.loads(subprocess.run(['git','show',ref+':DeepSeekHarnessMobile/Resources/Localizable.xcstrings'],
                                     capture_output=True,text=True,encoding='utf-8').stdout)
base, upstream, fork = get('<cherry-pick>^'), get('<cherry-pick>'), get('HEAD')
merged = dict(fork['strings'])
for k, v in upstream['strings'].items():
    if k not in base['strings']:                    # 上游新增
        merged[k] = v
    elif base['strings'][k] != upstream['strings'][k] and k in fork['strings']:  # 上游更新
        merged[k] = v
out = dict(fork); out['strings'] = dict(sorted(merged.items()))
open('DeepSeekHarnessMobile/Resources/Localizable.xcstrings','w',encoding='utf-8',newline='\n').write(
    json.dumps(out, ensure_ascii=False, indent=2)+'\n')
```

---

## 五、本地化检查（CI 会拦）

`scripts/verify-localizations.py` 要求**所有中文字面量**走本地化入口：

- iOS：`String(localized: "...")` 且键必须在 `Localizable.xcstrings` 里有英文
- Android：`appText("...")` 且键必须在 `AndroidStrings.kt` 的 `english` 表里

**推送前本地预检**（Windows 需要 UTF-8 模式）：
```bash
PYTHONUTF8=1 python3 scripts/verify-localizations.py
```
期望输出：`本地化检查通过：1602 条 iOS 文案，19 条 Android 系统文案，1414 条 Android 界面文案。`

---

## 六、剩余 12 个上游提交（未蒸馏）

### A 档：可跳过

| 提交 | 内容 | 说明 |
|---|---|---|
| `d655212` | 赞助二维码换新 | 与本 fork 无关，可跳 |

> 已完成：`953e4ab`（已在 `998ca83` 同步）、`86d702d` iOS 图片画廊（已在 `2d0fd7c` 蒸馏）、`f36c872` 缺失审阅图标（已在 `998ca83` 补齐）。

### B 档：剩余可选

| 提交 | 内容 | 缺什么 |
|---|---|---|
| `f36c872`（余项） | 工作区审阅自定义字体包 + `SharedTeamStore.kt` 团队兼容微调 | 17.7 MB `Design/review-fonts` 字体包（暂按轻量原则跳过，iOS 审阅视图与 4 个图标均已就位） |

### C 档：剩余按需项（第一批 10 项 + `devicetools` + Share/Action Extension 均已完成）

| 模块 | 来源提交 | 说明 |
|---|---|---|
| **DS Bot 模式（纯 iOS 版）** | `350275b` `bd5b71f` `8aa6be3` `fc3c5a3` | 上游 v1.8.4 主打功能，剔除 Android 后约 5000 行核心代码（`BotModeView`/`BotManagementView`/`SharedBotStore`），可按需独立接入 |
| 可直接跳过 | `6fdd34c`、`d5d677d`/`cba7284` 的 `androidApp/` 与 `Docs/` | 与 iOS fork 无关 |

> 注：`Vendor/SwiftMath` 公式补丁、语音防闪退、WebRTC 清理、问答历史还原、新建会话工作区、Agent Team 模式开关、网关连接方式记忆、定时任务修复、表格图片列宽及 `SharedChatHistoryCache` `@Throws` 已全部合入 `main`。

---

## 七、如果要做全量合并（不推荐，但记录方法）

冲突预检：
```bash
git merge-tree --write-tree HEAD upstream/main 2>/dev/null | tail -n +2 | awk -F'\t' '{print $2}' | sort -u
```
当前结果：**36 个冲突文件**（昨晚蒸馏前是 6 个）。

危险文件：
- `Vendor/.../InlineText.swift` — 上游删了 fork 的 `SelectableInlineText` 分支，合并必须手工恢复
- `ConversationView.swift`、`AppStore.swift`、`ConversationViewport.swift`、`Glass.swift`、`AgentBackgroundExecutionController.swift`、`GatewayClient.swift` — 全是昨晚刚修过的

**正确姿势**：建分支 `merge/upstream-YYYYMMDD`，在分支上解冲突 + cue 验证，绿了再合 main。**不要直接推 main 试错**（昨晚 10 轮构建失败就是这么来的）。

---

## 八、构建与发布

### CI 工作流

- `.github/workflows/ios-unsigned-ipa.yml` — push main 触发，`runs-on: macos-26`，Xcode 26.6
- `.github/workflows/localization.yml` — 本地化检查

### 手动触发

```bash
gh workflow run ios-unsigned-ipa.yml --ref main -R Aionrhine/dsh-mobile
```

### 下载 IPA

```bash
gh run download <run-id> -R Aionrhine/dsh-mobile -D ./dist
```

### 发布 Release

```bash
gh release create unsigned-<日期>-auto <ipa路径> -R Aionrhine/dsh-mobile \
  --prerelease --title "..." --notes "..."
```

### 已知 CI 问题

- **macOS runner 饥饿**：表现为 `completed/cancelled`、`runner=null`、`steps=0`，不是编译错误。凌晨队列空闲，成功率高
- **`macos-14` 标签已弃用**，3 秒内取消

---

## 九、环境与凭据

- **gh CLI**：已登录 `Aionrhine`，有 admin 权限（可改 Actions 权限）
- **cue**：`ssh -i /root/.ssh/hermes-ssh root@100.64.0.13`（从 WSL 连）
- **Hindsight 记忆**：`http://100.64.0.1:18888`，库 `dsh`
  - 已写入两条 Correction：cue typecheck 工作流、蒸馏 cherry-pick 检查清单

---

## 十、给下一轮开发的建议

1. **本 fork 仅专注 iOS 端开发**；继续跟踪真机体验反馈（划词引用、图片画廊、轮次跳转、GenUI 渲染）按需修复
2. **改 Swift 前必读** `ARCHITECTURE.md` + `Docs/kmp-development.md`
3. **不要碰** `Vendor/swift-markdown-ui/Sources/MarkdownUI/Views/Inlines/InlineText.swift` 的 `SelectableInlineText` 分支
4. **推送前必跑**：`PYTHONUTF8=1 python3 scripts/verify-localizations.py` + `cue` 全量/增量 typecheck（建议只打包 `.swift` 源码目录压缩传输并加 `-o ServerAliveInterval=15` 防断连）
5. **大文件批量编辑后**必须做修饰符序列 + 逐行文本双重比对

---

## 十一、关键文件索引

| 文件 | 作用 |
|---|---|
| `ARCHITECTURE.md` | 架构与测试门禁 SSOT |
| `AGENTS.md` | 工作区说明（本机限制、构建命令、目录） |
| `AppRelease/release-info.json` | 版本号 + 网关最低版本 |
| `scripts/verify-localizations.py` | 本地化检查 |
| `scripts/apply-text-selection.py` | fork 的划词补丁（幂等，CI 构建前自动应用） |
| `DeepSeekHarnessMobile/Core/MessageQuote.swift` | 引用功能核心（`ConversationQuoteInbox`、`ConversationSelectionObserver`） |
| `DeepSeekHarnessMobile/Views/ConversationView.swift` | 会话主界面（引用条、chatContent 主链） |
| `shared/src/commonMain/.../protocol/ComposerQuoteDraft.kt` | 引用草稿（KMP 侧） |
