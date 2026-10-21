import XCTest
#if DEBUG
@testable import MarkdownUI
#else
import MarkdownUI
#endif
import class DeepSeekHarnessShared.SharedQueueStore
import UIKit
import SwiftUI
import WebKit
import ChatLayout
import ImageIO
import UniformTypeIdentifiers
import class DeepSeekHarnessShared.SharedQuestionResult
import class DeepSeekHarnessShared.SharedMviEvent
import class DeepSeekHarnessShared.SharedMviDispatchResult
import class DeepSeekHarnessShared.SharedHistoryProjectionSnapshot
import class DeepSeekHarnessShared.SharedPreparedHistoryPage
import class DeepSeekHarnessShared.SharedTrajectoryStore
import class DeepSeekHarnessShared.SharedSessionControlResult
import class DeepSeekHarnessShared.SharedSessionControlStore
import class DeepSeekHarnessShared.SharedSessionListResult
import class DeepSeekHarnessShared.KotlinLong
import class DeepSeekHarnessShared.KotlinInt
import class DeepSeekHarnessShared.KotlinDouble
import class DeepSeekHarnessShared.WorkspaceCodePreviewSupport
@testable import DeepSeekHarnessMobile

private enum GatewayProtocolParityFixtures {
    // 这些样本与 shared/commonTest/GatewayProtocolFixtures.kt 逐字保持一致。
    static let liveEventWithoutKind = #"{"sessionId":"s1","seq":7,"time":1001,"event":{"type":"assistant/chunk","turn":1,"step":1,"chunkType":"reasoning-delta","text":"thinking"}}"#
    static let replayedQuestionRequest = #"{"kind":"question-requested","rpcId":"rpc-1","sessionId":"s1","replay":true,"questions":[{"id":"direction","header":"研究方向","question":"你想研究哪个方向？","detail":"请选择最感兴趣的方向","options":[{"label":"核心架构 (推荐)","description":"了解插件分层"},{"label":"移动端"}],"multiSelect":true},{"id":"notes","question":"还有什么要求？","multiSelect":false}]}"#
    static let replayedApprovalRequest = #"{"kind":"approval-requested","rpcId":"rpc-approval-1","sessionId":"s1","approvalId":"approval-1","toolName":"Bash","callId":"call-1","reason":"需要读取系统版本","displayReason":{"en":"Allow reading system version?","zh-CN":"允许读取系统版本？"},"replay":true}"#
    static let imageAttachment = #"{"kind":"attachment","sessionId":"s1","attachment":{"attachmentId":"att-1","mediaType":"image/png","bytes":8,"width":1,"height":1},"data":"iVBORw0K"}"#
    static let historyImage = #"{"kind":"history","events":[{"type":"user/message","seq":1,"time":1786937352,"data":{"content":[{"type":"image","attachment":{"attachmentId":"att-history","mediaType":"image/webp","bytes":42,"width":100,"height":80,"name":"image.webp"}}],"source":{"kind":"user"}}}],"hasMore":false}"#
}

@MainActor
final class AgentIdleBackgroundAllowanceTests: XCTestCase {
    func testIdleEntryRequestsOneAllowanceWithoutStartingAgentWork() {
        let application = BackgroundTaskApplicationSpy()
        let keepAlive = AgentLongRunningKeepAliveSpy()
        let controller = AgentBackgroundExecutionController(application: application, longRunningKeepAlive: keepAlive)
        controller.applicationDidEnterBackground()
        controller.applicationDidEnterBackground()
        controller.updateQueuedSessions([])
        controller.reconcileSessions(runningBySessionID: ["session": false])
        XCTAssertEqual(application.beginCallCount, 1)
        XCTAssertTrue(application.endedIdentifiers.isEmpty)
        XCTAssertTrue(controller.keepsConnectionAlive)
        XCTAssertFalse(controller.isAgentWorkActive)
        XCTAssertFalse(keepAlive.agentWorkIsActive)
    }

    func testIdleExpirationReleasesAllowanceWithoutRenewingInSameBackgroundVisit() async {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)
        controller.applicationDidEnterBackground()
        application.expirationHandler?()
        await Task.yield()
        XCTAssertFalse(controller.keepsConnectionAlive)
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        controller.applicationDidEnterBackground()
        XCTAssertEqual(application.beginCallCount, 1)
        controller.applicationDidBecomeActive()
        controller.applicationDidEnterBackground()
        XCTAssertEqual(application.beginCallCount, 2)
    }

    func testForegroundAndManualCancelReleaseIdleAllowance() {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)
        controller.applicationDidEnterBackground()
        controller.applicationDidBecomeActive()
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        XCTAssertFalse(controller.keepsConnectionAlive)
        controller.applicationDidEnterBackground()
        controller.cancel()
        XCTAssertEqual(application.endedIdentifiers.count, 2)
        XCTAssertFalse(controller.keepsConnectionAlive)
    }

    func testAgentTurnReusesIdleAllowanceUntilSystemExpiration() async {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)
        controller.applicationDidEnterBackground()
        controller.begin(sessionID: "session", startsNewTurn: true)
        controller.turnEnded(sessionID: "session")
        XCTAssertEqual(application.beginCallCount, 1)
        XCTAssertTrue(application.endedIdentifiers.isEmpty)
        XCTAssertTrue(controller.keepsConnectionAlive)
        XCTAssertFalse(controller.isAgentWorkActive)
        application.expirationHandler?()
        await Task.yield()
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        XCTAssertFalse(controller.keepsConnectionAlive)
    }

    func testStaleExpirationCannotReleaseNewAllowance() async {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)
        controller.applicationDidEnterBackground()
        let oldExpiration = application.expirationHandler
        controller.applicationDidBecomeActive()
        controller.applicationDidEnterBackground()
        oldExpiration?()
        await Task.yield()
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        XCTAssertTrue(controller.keepsConnectionAlive)
        application.expirationHandler?()
        await Task.yield()
        XCTAssertEqual(application.endedIdentifiers.count, 2)
    }
}

@MainActor
final class AgentLiveActivityLifecycleTests: XCTestCase {
    func testBackgroundEventsWaitForForegroundAndUseLatestState() {
        var appState: UIApplication.State = .background
        var requestedDetails: [String?] = []
        let manager = AgentLiveActivityManager(
            applicationState: { appState },
            requestActivity: { _, content in
                requestedDetails.append(content.state.detail)
                throw URLError(.unknown)
            },
            restoresSystemActivities: false
        )
        manager.sessionStarted(gatewayID: "gateway", sessionID: "session", title: "任务", turn: 1)
        manager.toolStarted(gatewayID: "gateway", sessionID: "session", title: "任务", toolName: "Bash")
        manager.applicationDidBecomeActive()
        XCTAssertTrue(requestedDetails.isEmpty)
        appState = .active
        manager.applicationDidBecomeActive()
        XCTAssertEqual(requestedDetails, ["正在执行 Bash"])
        // 请求失败后，后续高频进度不能不断重试系统调用。
        manager.stepStarted(gatewayID: "gateway", sessionID: "session", title: "任务", step: 2)
        XCTAssertEqual(requestedDetails.count, 1)
        appState = .inactive
        manager.applicationDidBecomeActive()
        XCTAssertEqual(requestedDetails.count, 1)
        appState = .active
        manager.applicationDidBecomeActive()
        XCTAssertEqual(requestedDetails.count, 2)
    }

    func testTaskEndedInBackgroundIsNotCreatedOnReturn() {
        var appState: UIApplication.State = .background
        var requestCount = 0
        let manager = AgentLiveActivityManager(
            applicationState: { appState },
            requestActivity: { _, _ in
                requestCount += 1
                throw URLError(.unknown)
            },
            restoresSystemActivities: false
        )
        manager.sessionStarted(gatewayID: "gateway", sessionID: "session", title: "任务", turn: 1)
        manager.sessionEnded(gatewayID: "gateway", sessionID: "session", title: "任务", failed: false)
        appState = .active
        manager.applicationDidBecomeActive()
        XCTAssertEqual(requestCount, 0)
    }

    func testSessionSnapshotCancelsDeferredCreation() {
        var appState: UIApplication.State = .background
        var requestCount = 0
        let manager = AgentLiveActivityManager(
            applicationState: { appState },
            requestActivity: { _, _ in
                requestCount += 1
                throw URLError(.unknown)
            },
            restoresSystemActivities: false
        )
        manager.sessionStarted(gatewayID: "gateway", sessionID: "session", title: "任务", turn: 1)
        manager.reconcileSessions(gatewayID: "gateway", runningBySessionID: ["session": false])
        appState = .active
        manager.applicationDidBecomeActive()
        XCTAssertEqual(requestCount, 0)
    }
}

final class AgentLiveActivityEventProjectionTests: XCTestCase {
    func testPendingApprovalOnlyAlertsOnceForTheSameRPC() {
        let running = activityState(phase: .running)
        let pending = activityState(phase: .awaitingApproval, rpcID: "rpc-1")
        var enriched = pending
        enriched.command = "git status"

        XCTAssertTrue(AgentLiveActivityAlertPolicy.shouldAlert(current: running, incoming: pending))
        XCTAssertFalse(AgentLiveActivityAlertPolicy.shouldAlert(current: pending, incoming: pending))
        XCTAssertFalse(AgentLiveActivityAlertPolicy.shouldAlert(current: pending, incoming: enriched))
        XCTAssertTrue(AgentLiveActivityAlertPolicy.shouldAlert(
            current: pending,
            incoming: activityState(phase: .awaitingApproval, rpcID: "rpc-2")
        ))
    }

    func testPendingChoiceOnlyAlertsOnceForTheSameRPC() {
        let running = activityState(phase: .running)
        let pending = activityState(phase: .awaitingChoice, rpcID: "question-1")

        XCTAssertTrue(AgentLiveActivityAlertPolicy.shouldAlert(current: running, incoming: pending))
        XCTAssertFalse(AgentLiveActivityAlertPolicy.shouldAlert(current: pending, incoming: pending))
    }

    func testRunningProgressCannotOverwritePendingApproval() {
        let pending = activityState(phase: .awaitingApproval, rpcID: "rpc-1")
        let running = activityState(phase: .running)

        XCTAssertFalse(AgentLiveActivityUpdatePolicy.allows(current: pending, incoming: running))
    }

    func testRunningProgressCannotOverwritePendingChoice() {
        let pending = activityState(phase: .awaitingChoice, rpcID: "rpc-question-1")
        let running = activityState(phase: .running)

        XCTAssertFalse(AgentLiveActivityUpdatePolicy.allows(current: pending, incoming: running))
    }

    func testRunningProgressCannotOverwriteApprovalSubmissionOrUnknownResult() {
        let running = activityState(phase: .running)

        XCTAssertFalse(AgentLiveActivityUpdatePolicy.allows(
            current: activityState(phase: .submittingApproval, rpcID: "rpc-1"),
            incoming: running
        ))
        XCTAssertFalse(AgentLiveActivityUpdatePolicy.allows(
            current: activityState(phase: .failed, rpcID: "rpc-1"),
            incoming: running
        ))
    }

    func testRunningProgressResumesAfterApprovalIsConfirmed() {
        let approved = activityState(phase: .approved, rpcID: "rpc-1")
        let running = activityState(phase: .running)

        XCTAssertTrue(AgentLiveActivityUpdatePolicy.allows(current: approved, incoming: running))
    }

    func testPluginContextMessageKeepsItsSourceAndContent() throws {
        let projected = try XCTUnwrap(AgentLiveActivityEventProjection.progress(for: GatewayEvent(
            type: "user/message",
            text: "Use the repository skill catalog before choosing a workflow.",
            source: "skill-catalog"
        )))

        XCTAssertEqual(projected.headline, "上下文注入 · skill-catalog")
        XCTAssertEqual(projected.detail, "Use the repository skill catalog before choosing a workflow.")
        XCTAssertEqual(projected.kind, .context)
    }

    func testWriteToolUsesTheSameHumanReadableSummaryAsConversation() throws {
        let projected = try XCTUnwrap(AgentLiveActivityEventProjection.progress(for: GatewayEvent(
            type: "tool/call",
            turn: 1,
            step: 2,
            name: "write_file",
            arguments: .object([
                "path": .string("articles/北京中轴线.md"),
                "content": .string("第一行\n第二行")
            ])
        )))

        XCTAssertEqual(projected.headline, "写入")
        XCTAssertEqual(projected.detail, "articles/北京中轴线.md · 2 行")
        XCTAssertEqual(projected.kind, .writing)
    }

    func testReasoningStreamIsCondensedForTheLiveActivity() throws {
        let projected = try XCTUnwrap(AgentLiveActivityEventProjection.streamingProgress(
            chunkType: "reasoning-delta",
            text: "Now   check\ncharacter count",
            toolName: nil
        ))

        XCTAssertEqual(projected.headline, "思考")
        XCTAssertEqual(projected.detail, "Now check character count")
        XCTAssertEqual(projected.kind, .reasoning)
    }

    func testToolResultRetainsTheStartedToolLabel() throws {
        let projected = try XCTUnwrap(AgentLiveActivityEventProjection.progress(
            for: GatewayEvent(type: "tool/result", isError: false, preview: "saved"),
            completedToolLabel: "写入"
        ))

        XCTAssertEqual(projected.headline, "写入完成")
        XCTAssertEqual(projected.detail, "saved")
        XCTAssertEqual(projected.kind, .result)
    }

    private func activityState(
        phase: AgentActivityPhase,
        rpcID: String? = nil
    ) -> AgentActivityAttributes.ContentState {
        AgentActivityAttributes.ContentState(
            phase: phase,
            status: phase.rawValue,
            detail: nil,
            secondaryDetail: nil,
            sourceLabel: nil,
            command: nil,
            rpcID: rpcID,
            approvalID: nil,
            toolName: nil,
            stepKind: nil,
            updatedAt: .now
        )
    }
}

private func swiftAuditRange(
    from startMarker: String,
    through endMarker: String,
    in source: NSString
) throws -> NSRange {
    let startRange = source.range(of: startMarker)
    guard startRange.location != NSNotFound else {
        throw NSError(
            domain: "Stage9SourceAudit",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "找不到源码审计起始标记：\(startMarker)"]
        )
    }
    let searchRange = NSRange(
        location: NSMaxRange(startRange),
        length: source.length - NSMaxRange(startRange)
    )
    let endRange = source.range(of: endMarker, options: [], range: searchRange)
    guard endRange.location != NSNotFound else {
        throw NSError(
            domain: "Stage9SourceAudit",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "找不到源码审计结束标记：\(endMarker)"]
        )
    }
    return NSRange(
        location: startRange.location,
        length: NSMaxRange(endRange) - startRange.location
    )
}

private func stage9WriteMatches(for property: String, in source: String) throws -> [NSTextCheckingResult] {
    let escapedProperty = NSRegularExpression.escapedPattern(for: property)
    let nestedAccess = "(?:(?:\\s*\\[[^\\]\\n]+\\])|(?:\\s*[?!]?\\.\\s*[A-Za-z_][A-Za-z0-9_]*))*"
    let writePatterns = [
        "(?<![A-Za-z0-9_\\.])(?:self\\.)?\(escapedProperty)\(nestedAccess)\\s*(?:=|[+\\-*/%&|^]=)(?!=)",
        "(?<![&])&(?![&=])\\s*(?:self\\.)?\(escapedProperty)\(nestedAccess)(?![A-Za-z0-9_])",
        "(?<![A-Za-z0-9_\\.])(?:self\\.)?\(escapedProperty)\(nestedAccess)\\s*\\.\\s*(?:append|appendContentsOf|insert|popFirst|popLast|remove|removeAll|removeFirst|removeLast|removeSubrange|replaceSubrange|removeValue|updateValue|update|merge|swapAt|sort|reverse|shuffle|partition|reserveCapacity|formUnion|formIntersection|formSymmetricDifference|subtract|toggle|withUnsafeMutableBytes|withUnsafeMutablePointer|withUnsafeMutableBufferPointer|withContiguousMutableStorageIfAvailable)\\s*\\("
    ]
    return try writePatterns.flatMap { pattern in
        try NSRegularExpression(pattern: pattern).matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
    }
}

final class SlashCommandComposerPresentationTests: XCTestCase {
    func testActiveCommandPresentationRendersOneCompleteTextLayer() {
        let hint = slashCommandComposerPresentation(
            draft: "/plan ",
            token: "/plan",
            hint: "描述你的任务以生成计划"
        )
        XCTAssertEqual(hint?.token, "/plan")
        XCTAssertEqual(hint?.argument, " ")
        XCTAssertTrue(hint?.showsHint == true)
        XCTAssertEqual(hint?.hintLeadingWhitespace, " ")

        let argument = slashCommandComposerPresentation(
            draft: "/plan 重构移动端",
            token: "/plan",
            hint: "描述你的任务以生成计划"
        )
        XCTAssertEqual(argument?.argument, " 重构移动端")
        XCTAssertFalse(argument?.showsHint == true)

        XCTAssertNil(
            slashCommandComposerPresentation(
                draft: "/planning",
                token: "/plan",
                hint: "描述你的任务以生成计划"
            )
        )
        XCTAssertNil(
            slashCommandComposerPresentation(
                draft: "/pla",
                token: "/plan",
                hint: "描述你的任务以生成计划"
            )
        )
        XCTAssertNil(
            slashCommandComposerPresentation(
                draft: "",
                token: "/plan",
                hint: "描述你的任务以生成计划"
            )
        )
    }

    @MainActor
    func testTypingKeepsTheSameTextViewAndFirstResponderAcrossMenuUpdates() async throws {
        let controller = UIHostingController(rootView: SlashCommandFocusHarness())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let original = try XCTUnwrap(firstDescendant(of: UITextView.self, in: controller.view))
        XCTAssertTrue(original.becomeFirstResponder())

        // 第一个字符会令命令菜单从 EmptyView 切成真实内容。这个状态更新不能
        // 替换输入控件，也不能让 SwiftUI 的旧焦点值反向结束 UIKit 编辑会话。
        original.insertText("/")
        try await Task.sleep(for: .milliseconds(80))
        controller.view.layoutIfNeeded()

        let afterFirstCharacter = try XCTUnwrap(
            firstDescendant(of: UITextView.self, in: controller.view)
        )
        XCTAssertTrue(original === afterFirstCharacter)
        XCTAssertTrue(afterFirstCharacter.isFirstResponder)

        afterFirstCharacter.insertText("p")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(afterFirstCharacter.text, "/p")
        XCTAssertTrue(afterFirstCharacter.isFirstResponder)
    }
}

private struct SlashCommandFocusHarness: View {
    @State private var text = ""
    @State private var isFocused = false

    var body: some View {
        VStack {
            if text.hasPrefix("/") {
                Text("命令")
                    .frame(height: 120)
            }
            SlashCommandTextView(
                text: $text,
                presentation: slashCommandComposerPresentation(
                    draft: text,
                    token: text.hasPrefix("/plan") ? "/plan" : nil,
                    hint: "描述你的任务以生成计划"
                ),
                placeholder: "描述你想要构建的内容",
                isFocused: $isFocused
            )
        }
        .frame(width: 390, height: 400)
    }
}

private struct ExpandingConversationCellTestView: View {
    @State private var usesResolvedHeight = false

    var body: some View {
        Text("主要产出目录： `/Users/lichaofan/测试 2/MyFirstApp/`。")
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: usesResolvedHeight ? 120 : 24, alignment: .top)
            .onAppear {
                DispatchQueue.main.async {
                    usesResolvedHeight = true
                }
            }
    }
}

private func firstDescendant<T: UIView>(of type: T.Type, in view: UIView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
        if let match = firstDescendant(of: type, in: subview) { return match }
    }
    return nil
}

final class WorkspaceCodeTextKitPerformanceTests: XCTestCase {
    @MainActor
    func testReportSizedHtmlConfiguresWithoutEagerSwiftUILayout() throws {
        var lines = ["<!DOCTYPE html>", "<html lang=\"zh-CN\"><head><style>"]
        for index in 0..<590 {
            lines.append(
                ".report-\(index) { color: #8a8f99; margin: \(index % 24)px; " +
                    "content: \"DeepSeek 深度调研报告 \(index)\"; }"
            )
        }
        lines.append("</style></head><body><main class=\"report\">报告</main></body></html>")
        let source = lines.joined(separator: "\n")
        let document = WorkspaceCodePreviewSupport.shared.prepare(
            source: source,
            name: "deepseek_report.html",
            mediaType: "text/html"
        )
        let view = WorkspaceCodeTextKitContainer(
            frame: CGRect(x: 0, y: 0, width: 390, height: 760)
        )

        let started = CFAbsoluteTimeGetCurrent()
        view.configure(document: document, isDark: false)
        view.layoutIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let textView = try XCTUnwrap(firstDescendant(of: UITextView.self, in: view))
        let lineNumberLabel = try XCTUnwrap(firstDescendant(of: UILabel.self, in: view))
        XCTAssertEqual(textView.attributedText.length, (source as NSString).length)
        XCTAssertFalse(textView.textContainer.widthTracksTextView)
        XCTAssertTrue(textView.isSelectable)
        let scrollView = try XCTUnwrap(firstDescendant(of: UIScrollView.self, in: view))
        let initialLineNumberY = lineNumberLabel.frame.minY
        scrollView.contentOffset = CGPoint(x: 80, y: 120)
        view.scrollViewDidScroll(scrollView)
        XCTAssertEqual(lineNumberLabel.frame.minY, initialLineNumberY - 120, accuracy: 0.5)
        XCTAssertLessThan(elapsed, 1.0, "TextKit 预览配置耗时异常：\(elapsed)s")
    }

    @MainActor
    func testLongLinesScrollHorizontallyWithFixedGutterAndSurviveResize() throws {
        let source = (1...80).map { "第\($0)行 " + String(repeating: "long_value_", count: 45) }.joined(separator: "\n")
        let document = WorkspaceCodePreviewSupport.shared.prepare(source: source, name: "long.swift", mediaType: nil)
        let view = WorkspaceCodeTextKitContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.configure(document: document, isDark: false)
        view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(firstDescendant(of: UIScrollView.self, in: view))
        let textView = try XCTUnwrap(firstDescendant(of: UITextView.self, in: view))
        let gutter = try XCTUnwrap(firstDescendant(of: UILabel.self, in: view))
        XCTAssertGreaterThan(scrollView.contentSize.width, scrollView.bounds.width + 1_000)
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height)
        XCTAssertTrue(scrollView.panGestureRecognizer.isEnabled)
        let originalX = textView.convert(.zero, to: view).x
        let gutterX = gutter.convert(.zero, to: view).x
        scrollView.contentOffset = CGPoint(x: 400, y: 120)
        view.scrollViewDidScroll(scrollView)
        view.layoutIfNeeded()
        XCTAssertEqual(textView.convert(.zero, to: view).x, originalX - 400, accuracy: 1)
        XCTAssertEqual(gutter.convert(.zero, to: view).x, gutterX, accuracy: 1)
        XCTAssertEqual(gutter.frame.minY, 14 - 120, accuracy: 1)
        XCTAssertEqual(textView.text, source)

        view.frame.size.width = 1_024
        view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, 400, accuracy: 1)
        view.configure(document: WorkspaceCodePreviewSupport.shared.prepare(source: "short", name: "short.txt", mediaType: nil), isDark: true)
        view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset, .zero)
        XCTAssertEqual(scrollView.contentSize.width, scrollView.bounds.width, accuracy: 1)
    }

    @MainActor
    func testMarkdownSwitchRendersDocumentAndPreservesSourceScroll() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).md")
        try ("# 预览标题\n\n**强调内容**\n\n| 列 | 值 |\n|---|---|\n| A | B |\n\n" +
             (1...70).map { "- 项目 \($0) " + String(repeating: "长文本", count: 40) }.joined(separator: "\n"))
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = WorkspaceLocalFile(url: url, sessionID: "test", remotePath: url.lastPathComponent,
                                      name: url.lastPathComponent, mediaType: "text/markdown", purpose: "preview")
        let host = UIHostingController(rootView: WorkspaceCodePreview(file: file, onOpenSystem: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for _ in 0..<100 {
            if firstDescendant(of: UISegmentedControl.self, in: host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        host.view.layoutIfNeeded()
        let picker = try XCTUnwrap(firstDescendant(of: UISegmentedControl.self, in: host.view))
        let source = try XCTUnwrap(firstDescendant(of: WorkspaceCodeTextKitContainer.self, in: host.view))
        let scroll = try XCTUnwrap(firstDescendant(of: UIScrollView.self, in: source))
        func scrollCount(in view: UIView) -> Int {
            (view is UIScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollCount(in: $1) }
        }
        let sourceScrollCount = scrollCount(in: host.view)
        scroll.contentOffset = CGPoint(x: 150, y: 120)
        for (index, mode) in [1, 0, 1, 0].enumerated() {
            picker.selectedSegmentIndex = mode
            picker.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let code = try XCTUnwrap(firstDescendant(of: UITextView.self, in: source))
            if mode == 0 {
                XCTAssertGreaterThan(code.layoutManager.usedRect(for: code.textContainer).height, 500,
                                     "切换后源码仍须有实际文本布局，不能只保留空白滚动区域")
            }
            XCTAssertEqual(picker.selectedSegmentIndex, mode)
            XCTAssertEqual(scroll.contentOffset.x, 150, accuracy: 1)
            XCTAssertEqual(scroll.contentOffset.y, 120, accuracy: 1)
            if mode == 1 {
                XCTAssertGreaterThan(scrollCount(in: host.view), sourceScrollCount,
                                     "切换后应创建独立的 Markdown 滚动预览，不能只改变选择器")
            }
            if index < 2 {
                let attachment = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                })
                attachment.name = mode == 1 ? "Markdown 渲染预览" : "Markdown 源码"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}

@MainActor
final class ConversationHistoryPrependTests: XCTestCase {
    func testLoadingMoreWithButtonRemainingKeepsFirstMessageAtSamePosition() async throws {
        try await assertPrependPreservesReadingPosition(removesButton: false, offset: 0)
    }

    func testFinalHistoryPageRemovingButtonKeepsFirstMessageAtSamePosition() async throws {
        try await assertPrependPreservesReadingPosition(removesButton: true, offset: 0)
    }

    func testPrependingVariableHeightHistoryKeepsPartiallyVisibleMessageStable() async throws {
        try await assertPrependPreservesReadingPosition(removesButton: false, offset: 180)
    }

    func testRemovingLoadMoreAfterEmptyPageKeepsReadingPosition() async throws {
        try await assertPrependPreservesReadingPosition(removesButton: true, offset: 180, olderCount: 0)
    }

    func testLoadingHistoryKeepsMainQueueResponsiveBeforeCommittingNewRows() async throws {
        try await assertPrependPreservesReadingPosition(
            removesButton: false, offset: 180, olderCount: 60, checksResponsiveness: true
        )
    }

    func testDraggingWhileHistoryIsPreparingKeepsLatestReadingPosition() async throws {
        try await assertPrependPreservesReadingPosition(
            removesButton: false, offset: 180, olderCount: 60, scrollsDuringPreparation: true
        )
    }

    func testLatestHistoryRequestReplacesPendingRequest() async throws {
        try await assertPrependPreservesReadingPosition(
            removesButton: false, offset: 180, olderCount: 60, coalescesRequests: true
        )
    }

    func testChangingSessionCancelsPendingHistoryPreparation() async throws {
        try await assertPrependPreservesReadingPosition(
            removesButton: false, offset: 180, olderCount: 60, switchesSession: true
        )
    }

    private func assertPrependPreservesReadingPosition(
        removesButton: Bool, offset: CGFloat, olderCount: Int = 15,
        checksResponsiveness: Bool = false, scrollsDuringPreparation: Bool = false,
        coalescesRequests: Bool = false, switchesSession: Bool = false
    ) async throws {
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in }, onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {}, onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var measuredHistoryIDs = Set<Int>()
        let measurementYield = checksResponsiveness ? expectation(description: "测量分批执行，主队列可以穿插响应") : nil
        func rows(_ prefix: String, count: Int) -> [ConversationViewportEntry] {
            (0..<count).map { index in
                let height = CGFloat(44 + index % 3 * 40)
                let content: AnyView
                if checksResponsiveness, prefix == "older" {
                    content = AnyView(HistoryHeightProbe(height: height) {
                        let isFirstMeasurement = measuredHistoryIDs.insert(index).inserted
                        if isFirstMeasurement, measuredHistoryIDs.count == 1 {
                            DispatchQueue.main.async {
                                XCTAssertLessThan(measuredHistoryIDs.count, count,
                                                  "不能只把整页同步测量延迟到下一个主线程调用")
                                measurementYield?.fulfill()
                            }
                        }
                    })
                } else {
                    content = AnyView(Text("\(prefix) \(index)").frame(height: height))
                }
                return .init(id: "\(prefix)-\(index)", revision: 0, content: content)
            }
        }
        let button = ConversationViewportEntry(id: "history-more", revision: 0,
            content: AnyView(Button("加载更早记录") {}.frame(height: 40)), allowsScrollAnchoring: false)
        let existing = rows("existing", count: 18)
        controller.apply(entries: [button] + existing, revision: 1, bottomInset: 0, hasConversationContent: true)
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutIfNeeded()
        let list = try XCTUnwrap(firstDescendant(of: UICollectionView.self, in: controller.view))
        list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        controller.scrollViewDidScroll(list)
        list.layoutIfNeeded()
        let oldPath = try XCTUnwrap(list.indexPathsForVisibleItems.sorted().first { $0.item > 0 })
        let oldFrame = try XCTUnwrap(list.layoutAttributesForItem(at: oldPath)).frame
        var originalY = oldFrame.minY - list.contentOffset.y
        var older = rows("older", count: olderCount)
        controller.apply(entries: (removesButton ? [] : [button]) + older + existing,
                         revision: 2, bottomInset: 0, hasConversationContent: true)
        if switchesSession {
            controller.setSessionID("replacement-session")
            controller.apply(entries: rows("replacement", count: 1), revision: 1,
                             bottomInset: 0, hasConversationContent: true)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(list.numberOfItems(inSection: 0), 1,
                           "旧会话准备完成后不能把历史页提交到新会话")
            return
        }
        if coalescesRequests {
            older = rows("older", count: olderCount + 3)
            controller.apply(entries: [button] + older + existing, revision: 3,
                             bottomInset: 0, hasConversationContent: true)
        }
        if scrollsDuringPreparation {
            controller.scrollViewWillBeginDragging(list)
            list.setContentOffset(CGPoint(x: 0, y: offset + 20), animated: false)
            controller.scrollViewDidScroll(list)
            originalY = oldFrame.minY - list.contentOffset.y
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(list.numberOfItems(inSection: 0), existing.count + 1,
                           "拖动期间应保持旧列表，不能改变手指下的内容")
            controller.scrollViewDidEndDragging(list, willDecelerate: false)
        }
        if checksResponsiveness {
            XCTAssertEqual(list.numberOfItems(inSection: 0), existing.count + 1,
                           "准备历史消息时保留旧列表，不能同步测量整页并提交")
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    XCTAssertEqual(list.numberOfItems(inSection: 0), existing.count + 1,
                                   "整页测量完成前，主队列应能继续响应其他事件")
                    continuation.resume()
                }
            }
        }
        let expectedCount = older.count + existing.count + (removesButton ? 0 : 1)
        for _ in 0..<300 {
            if list.numberOfItems(inSection: 0) == expectedCount { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(list.numberOfItems(inSection: 0), expectedCount)
        if let measurementYield { await fulfillment(of: [measurementYield], timeout: 3) }
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(80))
            list.layoutIfNeeded()
            let newItem = oldPath.item - 1 + older.count + (removesButton ? 0 : 1)
            let newFrame = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: newItem, section: 0))).frame
            XCTAssertEqual(newFrame.minY - list.contentOffset.y, originalY, accuracy: 1,
                           "加载历史后应保留原消息的屏幕位置，不能跳到新列表顶部")
        }
        if olderCount > 0 { XCTAssertGreaterThan(list.contentOffset.y, offset + 500) }
    }
}

private struct HistoryHeightProbe: UIViewRepresentable {
    let height: CGFloat
    let onMeasure: () -> Void

    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        onMeasure()
        return CGSize(width: proposal.width ?? 390, height: height)
    }
}

final class ConversationViewportLayoutTests: XCTestCase {
    @MainActor
    func testWarmSessionRestoresReadingAnchorAndSearchDoesNotSnapBackToTail() async throws {
        ConversationViewportController.clearReusableHeights()
        defer { ConversationViewportController.clearReusableHeights() }
        let rows = (0..<60).map { index in
            ConversationViewportEntry(id: "row-\(index)", revision: 1,
                content: AnyView(Text("消息 \(index)").frame(height: 70)))
        }
        func controller(target: String? = nil) -> ConversationViewportController {
            let view = ConversationViewportController(onContentAvailabilityChanged: { _, _ in },
                onPinnedToBottomChanged: { _ in }, onBottomAlignmentCompleted: {}, onApproachingTop: {})
            view.cacheScope = "warm-anchor-gateway"
            view.searchTargetID = target
            view.loadViewIfNeeded()
            view.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
            view.view.layoutIfNeeded()
            return view
        }
        let old = controller()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = old.view.frame
        window.rootViewController = old
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func configure(_ controller: ConversationViewportController) {
            controller.configure(sessionID: "warm-anchor-session", timeline: ConversationTimeline(),
                supplementalEntries: rows, makeEntries: { _ in [] }, bottomInset: 0)
        }
        configure(old)
        try await Task.sleep(for: .milliseconds(120))
        let oldList = try XCTUnwrap(firstDescendant(of: UICollectionView.self, in: old.view))
        old.scrollViewWillBeginDragging(oldList)
        oldList.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        old.scrollViewDidEndDragging(oldList, willDecelerate: false)
        old.view.layoutIfNeeded()
        let offset = oldList.contentOffset.y
        old.persistReusableHeights()
        let restored = controller()
        window.rootViewController = restored
        configure(restored)
        try await Task.sleep(for: .milliseconds(120))
        restored.view.layoutIfNeeded()
        let restoredList = try XCTUnwrap(firstDescendant(of: UICollectionView.self, in: restored.view))
        XCTAssertEqual(restoredList.contentOffset.y, offset, accuracy: 1)
        let search = controller(target: "row-4")
        window.rootViewController = search
        configure(search)
        try await Task.sleep(for: .milliseconds(120))
        search.view.layoutIfNeeded()
        let list = try XCTUnwrap(firstDescendant(of: UICollectionView.self, in: search.view))
        XCTAssertTrue(list.indexPathsForVisibleItems.contains(IndexPath(item: 4, section: 0)))
        XCTAssertLessThan(list.contentOffset.y, list.contentSize.height - list.bounds.height - 500)
    }

    @MainActor
    func testReusableGeometryIsIsolatedByRevisionWidthFontAndGateway() async throws {
        ConversationViewportController.clearReusableHeights()
        let defaults = UserDefaults.standard
        let previousScale = defaults.object(forKey: AppFontScale.key)
        let previousSystem = defaults.object(forKey: AppFontScale.followsSystemKey)
        defer {
            defaults.set(previousScale, forKey: AppFontScale.key)
            defaults.set(previousSystem, forKey: AppFontScale.followsSystemKey)
            ConversationViewportController.clearReusableHeights()
        }
        defaults.set(false, forKey: AppFontScale.followsSystemKey)
        defaults.set(1.0, forKey: AppFontScale.key)
        func measured(scope: String, width: CGFloat, revision: Int, height: CGFloat) async throws -> CGFloat {
            let controller = ConversationViewportController(onContentAvailabilityChanged: { _, _ in },
                onPinnedToBottomChanged: { _ in }, onBottomAlignmentCompleted: {}, onApproachingTop: {})
            controller.cacheScope = scope
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            controller.view.layoutIfNeeded()
            controller.configure(sessionID: "reusable-geometry", timeline: ConversationTimeline(),
                supplementalEntries: [.init(id: "row", revision: revision, content: AnyView(Text("内容").frame(height: height)))],
                makeEntries: { _ in [] }, bottomInset: 0)
            try await Task.sleep(for: .milliseconds(50))
            controller.view.layoutIfNeeded()
            let list = try XCTUnwrap(firstDescendant(of: UICollectionView.self, in: controller.view))
            let frame = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
            controller.persistReusableHeights()
            return frame.height
        }
        let first = try await measured(scope: "g1", width: 390, revision: 1, height: 80)
        let hot = try await measured(scope: "g1", width: 390, revision: 1, height: 80)
        XCTAssertEqual(first, hot, accuracy: 1)
        let revised = try await measured(scope: "g1", width: 390, revision: 2, height: 160)
        XCTAssertGreaterThan(revised, first + 50)
        let resized = try await measured(scope: "g1", width: 280, revision: 2, height: 220)
        XCTAssertGreaterThan(resized, revised + 40)
        let otherGateway = try await measured(scope: "g2", width: 390, revision: 2, height: 260)
        XCTAssertGreaterThan(otherGateway, revised + 80)
        defaults.set(1.4, forKey: AppFontScale.key)
        let differentFont = try await measured(scope: "g1", width: 390, revision: 2, height: 300)
        XCTAssertGreaterThan(differentFont, revised + 100)
    }

    func testLongInlineCodeCanWrapAtPathSeparatorsWithoutChangingSourceText() {
        let source = "主要产出目录：`/Users/lichaofan/测试 2/My_FirstApp/`。"

        let rendered = InlineCodePadding.apply(to: source)

        XCTAssertTrue(rendered.contains("/\u{200B}"))
        XCTAssertTrue(rendered.contains("_\u{200B}"))
        XCTAssertEqual(
            rendered
                .replacingOccurrences(of: "\u{200B}", with: "")
                .replacingOccurrences(of: "\u{2009}", with: ""),
            source
        )
    }

    @MainActor
    func testLiveHostedHeightPushesFollowingCellInsteadOfClippingContent() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        // iPhone 17 app width (402pt) minus ConversationView's 20pt
        // horizontal padding on each side.
        controller.view.frame = CGRect(x: 0, y: 0, width: 362, height: 300)
        controller.view.layoutIfNeeded()
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.configure(
            sessionID: "live-hosted-height",
            timeline: timeline,
            supplementalEntries: [
                ConversationViewportEntry(
                    id: "assistant",
                    revision: 1,
                    content: AnyView(ExpandingConversationCellTestView()),
                    clipsContentToBounds: true
                ),
                ConversationViewportEntry(
                    id: "process",
                    revision: 1,
                    content: AnyView(Text("耗时 9 秒 · 1 项上下文 · 1 次工具调用").frame(height: 34)),
                    clipsContentToBounds: true
                )
            ],
            makeEntries: { _ in [] },
            bottomInset: 0
        )

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        for _ in 0..<100 {
            controller.view.layoutIfNeeded()
            let height = collectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: 0)
            )?.frame.height ?? 0
            if height >= 120 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let assistant = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        )
        let process = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame
        )
        XCTAssertGreaterThanOrEqual(assistant.height, 120)
        XCTAssertEqual(process.minY, assistant.maxY, accuracy: 0.5)
    }

    @MainActor
    func testViewportDisablesRecursiveAutomaticSelfSizingInvalidation() throws {
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        controller.view.layoutIfNeeded()

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        let layout = try XCTUnwrap(
            collectionView.collectionViewLayout as? CollectionViewChatLayout
        )
        if #available(iOS 16.0, *) {
            XCTAssertEqual(collectionView.selfSizingInvalidation, .disabled)
            XCTAssertFalse(layout.supportSelfSizingInvalidation)
        }
    }

    @MainActor
    func testStreamingHeightEstimateDoesNotClipTextKitContent() {
        let payload = ConversationViewportEntry.StreamingAssistant(
            title: "DeepSeek · 正在生成",
            text: """
            第一段正在生成的中文内容，用于验证自动换行后的真实高度。
            第二段继续增长，并包含 a/very/long/path/with/separators/file.txt。
            第三段用于覆盖多行 TextKit 的字体行高。
            """
        )
        let width: CGFloat = 390
        let cell = StreamingAssistantCell(frame: CGRect(x: 0, y: 0, width: width, height: 80))
        cell.contentView.bounds.size.width = width
        cell.apply(payload)
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()

        let measured = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let estimated = StreamingAssistantCell.estimatedHeight(for: payload, width: width)

        XCTAssertGreaterThanOrEqual(estimated + 1, measured)
    }

    @MainActor
    func testStreamingChunksGrowVisibleCellBeforeFinalMarkdownReplacement() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 362, height: 300)
        controller.view.layoutIfNeeded()
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.configure(
            sessionID: "streaming-chunk-growth",
            timeline: timeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map { item in
                    ConversationViewportEntry(
                        id: item.id,
                        revision: item.text.count,
                        streamingAssistant: .init(title: item.title, text: item.text)
                    )
                }
            },
            bottomInset: 0
        )

        func item(_ text: String) -> ConversationItem {
            ConversationItem(
                id: "streaming-response",
                kind: .assistant,
                title: "DeepSeek · 正在生成",
                text: text,
                isError: false,
                date: Date(timeIntervalSince1970: 1)
            )
        }

        let firstChunk = "好嘞，先输出第一行。"
        timeline.publish([item(firstChunk)])
        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        for _ in 0..<100 {
            controller.view.layoutIfNeeded()
            if let cell = collectionView.cellForItem(
                at: IndexPath(item: 0, section: 0)
            ) as? StreamingAssistantCell,
               cell.renderedCharacterCount == firstChunk.count {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstHeight = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        ).frame.height

        let laterChunks = firstChunk + String(
            repeating: "程序员点外卖的故事仍在逐个 chunk 持续输出，界面必须同步增长。",
            count: 18
        )
        timeline.publish([item(laterChunks)])
        for _ in 0..<100 {
            controller.view.layoutIfNeeded()
            let renderedCount = (collectionView.cellForItem(
                at: IndexPath(item: 0, section: 0)
            ) as? StreamingAssistantCell)?.renderedCharacterCount ?? 0
            let height = collectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: 0)
            )?.frame.height ?? 0
            if renderedCount == laterChunks.count, height > firstHeight + 40 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let streamingCell = try XCTUnwrap(
            collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
                as? StreamingAssistantCell
        )
        let grownHeight = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        ).frame.height
        XCTAssertEqual(streamingCell.renderedCharacterCount, laterChunks.count)
        XCTAssertGreaterThan(grownHeight, firstHeight + 40)
    }

    @MainActor
    func testLongStreamingReplyDoesNotRelayoutForEveryChunk() throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 362, height: 300)
        controller.view.layoutIfNeeded()
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.configure(
            sessionID: "streaming-layout-frequency",
            timeline: timeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map { item in
                    ConversationViewportEntry(
                        id: item.id,
                        revision: item.text.utf16.count,
                        streamingAssistant: .init(title: item.title, text: item.text)
                    )
                }
            },
            bottomInset: 0
        )

        func publish(_ text: String) {
            timeline.publish([
                ConversationItem(
                    id: "streaming-response",
                    kind: .assistant,
                    title: "DeepSeek · 正在生成",
                    text: text,
                    isError: false,
                    date: Date(timeIntervalSince1970: 1)
                )
            ])
        }

        var text = ""
        for _ in 0..<300 {
            text.append("abcdefghij")
            publish(text)
        }

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        let cell = try XCTUnwrap(
            collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
                as? StreamingAssistantCell
        )
        XCTAssertEqual(cell.renderedCharacterCount, text.count)
        XCTAssertLessThan(
            controller.streamingLayoutInvalidationCount,
            120,
            "流式布局应按实际新增行更新，不能重新退化为每个 chunk 一次"
        )
    }

    @MainActor
    func testRapidStreamingStructureUpdatesKeepExactNonOverlappingFrames() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
        controller.view.layoutIfNeeded()

        func makeEntries(_ items: [ConversationItem]) -> [ConversationViewportEntry] {
            items.map { item in
                ConversationViewportEntry(
                    id: item.id,
                    revision: item.text.count,
                    streamingAssistant: .init(title: item.title, text: item.text)
                )
            }
        }

        for revision in 1...24 {
            let processRows = (0..<min(revision, 6)).map { index in
                ConversationViewportEntry(
                    id: "process-\(index)",
                    revision: revision,
                    content: AnyView(
                        Text("耗时 \(revision) 秒 · \(index + 1) 次工具调用")
                            .frame(height: 34)
                    ),
                    clipsContentToBounds: true
                )
            }
            controller.configure(
                sessionID: "rapid-layout-updates",
                timeline: timeline,
                supplementalEntries: processRows,
                makeEntries: makeEntries,
                bottomInset: 0
            )
            timeline.publish([
                ConversationItem(
                    id: "streaming-response",
                    kind: .assistant,
                    title: "DeepSeek · 正在生成",
                    text: String(repeating: "第\(revision)轮内容 ", count: revision),
                    isError: false,
                    date: Date(timeIntervalSince1970: 1)
                )
            ])
            try await Task.sleep(for: .milliseconds(4))
        }

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        for _ in 0..<100 where collectionView.numberOfItems(inSection: 0) != 7 {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
        }

        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 7)
        let frames = try (0..<7).map { item in
            try XCTUnwrap(
                collectionView.layoutAttributesForItem(
                    at: IndexPath(item: item, section: 0)
                )?.frame
            )
        }
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(next.minY, previous.maxY, accuracy: 1)
        }
    }

    @MainActor
    func testHostedRowsKeepStableBoundariesWhileWidthAndScrollPositionChange() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        controller.view.layoutIfNeeded()

        let markdown = """
        Agent 输出必须按照当前列表宽度稳定换行。拖动聊天列表或改变容器宽度时，
        前一行的高度不能重新退回估算值，也不能让后面的思考过程覆盖正文。

        ## 验证内容

        - 第一段用于制造多行布局。
        - 第二段包含 `active/armed/complete` 等行内代码。
        - 第三段继续增加高度，确保测试过程能够实际滚动。
        """
        let entries: [ConversationViewportEntry] = (0..<4).flatMap { index in
            let response = ConversationItem(
                id: "assistant-\(index)",
                kind: .assistant,
                title: "DeepSeek",
                text: markdown,
                isError: false,
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
            return [
                ConversationViewportEntry(
                    id: "process-\(index)",
                    revision: 0,
                    content: AnyView(Text("思考过程 · 1 次工具调用").frame(height: 34)),
                    clipsContentToBounds: true
                ),
                ConversationViewportEntry(
                    id: "assistant-\(index)",
                    revision: 0,
                    content: AnyView(ConversationRow(
                        item: response,
                        showsCopyButton: false,
                        imageData: { _ in nil }
                    )),
                    clipsContentToBounds: true
                )
            ]
        }
        controller.configure(
            sessionID: "bounds-and-scroll-stability",
            timeline: timeline,
            supplementalEntries: entries,
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(200))

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        controller.view.frame.size.width = 326
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()

        let frames = try (0..<entries.count).map { item in
            try XCTUnwrap(
                collectionView.layoutAttributesForItem(
                    at: IndexPath(item: item, section: 0)
                )?.frame
            )
        }
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(next.minY, previous.maxY, accuracy: 1)
        }

        let maximumOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        for progress in stride(from: CGFloat.zero, through: 1, by: 0.1) {
            collectionView.contentOffset.y = maximumOffset * progress
            collectionView.layoutIfNeeded()
            for cell in collectionView.visibleCells {
                let hostedView = try XCTUnwrap(cell.contentView.subviews.first)
                XCTAssertEqual(hostedView.frame, cell.contentView.bounds)
                XCTAssertEqual(hostedView.bounds.origin, .zero)
                let idealHeight = hostedView.sizeThatFits(
                    CGSize(width: cell.contentView.bounds.width, height: .greatestFiniteMagnitude)
                ).height
                XCTAssertGreaterThanOrEqual(cell.bounds.height + 1, idealHeight)
            }
        }
    }

    @MainActor
    func testStreamingTextPublishesLatestBufferedTextAfterUserScrollingStops() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        controller.view.layoutIfNeeded()
        controller.configure(
            sessionID: "streaming-scroll-pause",
            timeline: timeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map { item in
                    ConversationViewportEntry(
                        id: item.id,
                        revision: item.text.count,
                        streamingAssistant: .init(title: item.title, text: item.text)
                    )
                }
            },
            bottomInset: 0
        )

        let initialText = "第一段"
        timeline.publish([
            ConversationItem(
                id: "streaming-response",
                kind: .assistant,
                title: "DeepSeek · 正在生成",
                text: initialText,
                isError: false,
                date: Date(timeIntervalSince1970: 1)
            )
        ])
        var initialCell: StreamingAssistantCell?
        for _ in 0..<200 where initialCell == nil {
            controller.view.layoutIfNeeded()
            if let collectionView = firstDescendant(
                of: UICollectionView.self,
                in: controller.view
            ), let cell = collectionView.cellForItem(
                at: IndexPath(item: 0, section: 0)
            ) as? StreamingAssistantCell,
               cell.renderedCharacterCount == initialText.count {
                initialCell = cell
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        let cell = try XCTUnwrap(initialCell)
        let intermediateText = "第一段，滑动期间收到第二段"
        let latestText = "第一段，滑动期间收到第二段，并继续累计到最终一段"
        controller.scrollViewWillBeginDragging(collectionView)
        timeline.publish([
            ConversationItem(
                id: "streaming-response",
                kind: .assistant,
                title: "DeepSeek · 正在生成",
                text: intermediateText,
                isError: false,
                date: Date(timeIntervalSince1970: 1)
            )
        ])
        timeline.publish([
            ConversationItem(
                id: "streaming-response",
                kind: .assistant,
                title: "DeepSeek · 正在生成",
                text: latestText,
                isError: false,
                date: Date(timeIntervalSince1970: 1)
            )
        ])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(cell.renderedCharacterCount, initialText.count)

        // Finger release with remaining inertia must stay paused.
        controller.scrollViewDidEndDragging(collectionView, willDecelerate: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cell.renderedCharacterCount, initialText.count)

        controller.scrollViewDidEndDecelerating(collectionView)
        for _ in 0..<200 where cell.renderedCharacterCount != latestText.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(cell.renderedCharacterCount, latestText.count)
    }

    @MainActor
    func testExpandedProcessAndRealMarkdownAssistantNeverOverlap() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        controller.view.layoutIfNeeded()

        let response = ConversationItem(
            id: "formal-response",
            kind: .assistant,
            title: "DeepSeek",
            text: """
            我把当前会话压缩成一份可持续使用的存档，并保留了完整的任务信息。

            1. 第一项包含较长的中文说明，用来验证 Markdown 段落会按真实宽度换行。
            2. 第二项继续补充内容，确保正式回复的高度明显超过布局的初始估算值。
            3. 第三项包含 `inline code`，并继续追加多行文本用于覆盖截图中的真实结构。

            ## 下一步

            这里还有一段正式回复。它必须完整位于过程节点下方，而且后续 cell 必须等它结束以后再开始布局。
            """,
            isError: false,
            date: Date(timeIntervalSince1970: 2)
        )
        let assistantView = ConversationRow(
            item: response,
            showsCopyButton: true,
            imageData: { _ in nil }
        )
        let expectedHeight = UIHostingController(rootView: assistantView).sizeThatFits(
            in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        ).height

        let collapsedEntries = [
            ConversationViewportEntry(
                id: "process-header",
                revision: 0,
                content: AnyView(Text("思考过程 · 1 次工具调用").frame(height: 34)),
                clipsContentToBounds: true
            ),
            ConversationViewportEntry(
                id: "assistant",
                revision: 0,
                content: AnyView(assistantView),
                clipsContentToBounds: true
            ),
            ConversationViewportEntry(
                id: "following",
                revision: 0,
                content: AnyView(Text("下一条消息").frame(height: 32)),
                clipsContentToBounds: true
            )
        ]
        controller.configure(
            sessionID: "process-assistant-boundary",
            timeline: timeline,
            supplementalEntries: collapsedEntries,
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutIfNeeded()

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        let collapsedHeader = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        )
        let collapsedAssistant = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame
        )
        let headerScreenY = collapsedHeader.minY - collectionView.contentOffset.y

        controller.prepareForDisclosureUpdate(anchorID: "process-header")
        controller.configure(
            sessionID: "process-assistant-boundary",
            timeline: timeline,
            supplementalEntries: [
                ConversationViewportEntry(
                    id: "process-header",
                    revision: 1,
                    content: AnyView(Text("思考过程 · 1 次工具调用").frame(height: 34)),
                    clipsContentToBounds: true
                ),
                ConversationViewportEntry(
                    id: "process-detail",
                    revision: 0,
                    content: AnyView(Text("compact · 已完成").frame(height: 42)),
                    clipsContentToBounds: true
                ),
                ConversationViewportEntry(
                    id: "assistant",
                    revision: 0,
                    content: AnyView(assistantView),
                    clipsContentToBounds: true
                ),
                ConversationViewportEntry(
                    id: "following",
                    revision: 0,
                    content: AnyView(Text("下一条消息").frame(height: 32)),
                    clipsContentToBounds: true
                )
            ],
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()

        let expandedHeader = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        )
        let processDetail = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame
        )
        let assistant = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame
        )
        let following = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame
        )

        XCTAssertEqual(expandedHeader.minY - collectionView.contentOffset.y, headerScreenY, accuracy: 1)
        XCTAssertGreaterThan(assistant.minY, collapsedAssistant.minY + 40)
        XCTAssertGreaterThanOrEqual(assistant.minY + 0.5, processDetail.maxY)
        XCTAssertGreaterThanOrEqual(assistant.height + 1, expectedHeight)
        XCTAssertGreaterThanOrEqual(following.minY + 0.5, assistant.maxY)
    }

    @MainActor
    func testFencedMarkdownKeepsExactHeightAndZeroPhantomSpacingAfterReuse() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 280)
        controller.view.layoutIfNeeded()

        let response = ConversationItem(
            id: "markdown-with-code",
            kind: .assistant,
            title: "DeepSeek",
            text: """
            构建结果如下，代码块和后续正文都必须完整显示。

            ```yaml
            launchable-activity: com.example.myfirstapp.MainActivity
            build-type: debug
            min-sdk: 24
            compile-sdk: 36
            ```

            ## 说明与下一步

            - 包含 debug 变体。
            - 产物已经完成验证。
            """,
            isError: false,
            date: Date(timeIntervalSince1970: 1)
        )
        let responseView = ConversationRow(
            item: response,
            showsCopyButton: true,
            imageData: { _ in nil }
        )
        let expectedResponseHeight = UIHostingController(rootView: responseView).sizeThatFits(
            in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        ).height
        let entries = [
            ConversationViewportEntry(
                id: "assistant-code",
                revision: 1,
                content: AnyView(responseView),
                clipsContentToBounds: true
            ),
            ConversationViewportEntry(
                id: "process-header",
                revision: 1,
                content: AnyView(Text("思考过程 · 1 次工具调用").frame(height: 34)),
                clipsContentToBounds: true
            ),
            ConversationViewportEntry(
                id: "next-assistant",
                revision: 1,
                content: AnyView(Text("下一条 DeepSeek 回复").frame(height: 48)),
                clipsContentToBounds: true
            )
        ]
        controller.configure(
            sessionID: "fenced-markdown-reuse",
            timeline: timeline,
            supplementalEntries: entries,
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        collectionView.setContentOffset(.zero, animated: false)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(
            at: IndexPath(item: 2, section: 0),
            at: .bottom,
            animated: false
        )
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(.zero, animated: false)
        collectionView.layoutIfNeeded()

        let assistant = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        )
        let process = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame
        )
        let nextAssistant = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame
        )

        XCTAssertGreaterThanOrEqual(assistant.height + 1, expectedResponseHeight)
        XCTAssertLessThanOrEqual(assistant.height, ceil(expectedResponseHeight) + 1)
        XCTAssertEqual(process.minY, assistant.maxY, accuracy: 1)
        XCTAssertEqual(nextAssistant.minY, process.maxY, accuracy: 1)
        for cell in collectionView.visibleCells {
            guard let hostedView = cell.contentView.subviews.first else { continue }
            XCTAssertEqual(hostedView.frame, cell.contentView.bounds)
            XCTAssertEqual(hostedView.bounds.origin, .zero)
        }
    }

    @MainActor
    func testHistorySnapshotWaitsForResolvedViewportWidth() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = .zero
        controller.view.layoutIfNeeded()

        let historyResponse = ConversationItem(
            id: "history-response",
            kind: .assistant,
            title: "DeepSeek",
            text: """
            APK 构建并验证成功。更新任务清单并标记目标完成。

            目标当前处于 `paused` / `disabled` 状态，自动 `complete` 被拒。
            打包任务本身已全部完成并验证。
            """,
            isError: false,
            date: Date(timeIntervalSince1970: 1)
        )
        let responseView = ConversationRow(
            item: historyResponse,
            showsCopyButton: false,
            imageData: { _ in nil }
        )
        let entries = [
            ConversationViewportEntry(
                id: "history-process",
                revision: 1,
                content: AnyView(Text("耗时 5 秒 · 3 次工具调用").frame(height: 34)),
                clipsContentToBounds: true
            ),
            ConversationViewportEntry(
                id: "history-assistant",
                revision: 1,
                content: AnyView(responseView),
                clipsContentToBounds: true
            )
        ]
        controller.configure(
            sessionID: "restored-history",
            timeline: timeline,
            supplementalEntries: entries,
            makeEntries: { _ in [] },
            bottomInset: 0
        )

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        XCTAssertEqual(collectionView.numberOfSections, 0)

        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 280)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutIfNeeded()

        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 2)
        let process = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        )
        let assistant = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame
        )
        let expectedAssistantHeight = UIHostingController(rootView: responseView).sizeThatFits(
            in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        ).height

        XCTAssertEqual(assistant.minY, process.maxY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(assistant.height + 1, expectedAssistantHeight)
    }

    @MainActor
    func testDisclosureItemsKeepHeaderStableAndPushFollowingRow() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        controller.view.layoutIfNeeded()
        controller.configure(
            sessionID: "layout-test",
            timeline: timeline,
            supplementalEntries: [
                ConversationViewportEntry(
                    id: "header",
                    revision: 0,
                    content: AnyView(Text("Expandable header").frame(height: 32))
                ),
                ConversationViewportEntry(
                    id: "following",
                    revision: 0,
                    content: AnyView(Text("Following row").frame(height: 32))
                )
            ],
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutIfNeeded()

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        let firstIndexPath = IndexPath(item: 0, section: 0)
        let secondIndexPath = IndexPath(item: 1, section: 0)
        let oldFirst = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: firstIndexPath)?.frame
        )
        let oldSecond = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: secondIndexPath)?.frame
        )
        let oldHeaderScreenY = oldFirst.minY - collectionView.contentOffset.y

        controller.prepareForDisclosureUpdate(anchorID: "header")
        controller.configure(
            sessionID: "layout-test",
            timeline: timeline,
            supplementalEntries: [
                ConversationViewportEntry(
                    id: "header",
                    revision: 1,
                    content: AnyView(Text("Expandable header").frame(height: 32))
                ),
                ConversationViewportEntry(
                    id: "detail",
                    revision: 0,
                    content: AnyView(Color.clear.frame(height: 180))
                ),
                ConversationViewportEntry(
                    id: "following",
                    revision: 0,
                    content: AnyView(Text("Following row").frame(height: 32))
                )
            ],
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()

        let newFirst = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: firstIndexPath)?.frame
        )
        let detail = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: secondIndexPath)?.frame
        )
        let newFollowing = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame
        )
        let newHeaderScreenY = newFirst.minY - collectionView.contentOffset.y

        XCTAssertEqual(newHeaderScreenY, oldHeaderScreenY, accuracy: 1)
        XCTAssertEqual(newFirst.height, oldFirst.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(detail.minY + 0.5, newFirst.maxY)
        XCTAssertGreaterThanOrEqual(newFollowing.minY + 0.5, detail.maxY)
        XCTAssertGreaterThan(newFollowing.minY, oldSecond.minY + 170)
    }

    @MainActor
    func testCellKindTransitionUsesFinalHeightInsteadOfOldStreamingEstimate() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
        controller.view.layoutIfNeeded()
        controller.configure(
            sessionID: "cell-kind-transition",
            timeline: timeline,
            supplementalEntries: [
                ConversationViewportEntry(
                    id: "assistant",
                    revision: 0,
                    streamingAssistant: .init(title: "DeepSeek", text: "short")
                ),
                ConversationViewportEntry(
                    id: "following",
                    revision: 0,
                    content: AnyView(Text("Following row").frame(height: 32))
                )
            ],
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(100))

        controller.configure(
            sessionID: "cell-kind-transition",
            timeline: timeline,
            supplementalEntries: [
                ConversationViewportEntry(
                    id: "assistant",
                    revision: 1,
                    content: AnyView(Color.clear.frame(height: 620)),
                    clipsContentToBounds: true
                ),
                ConversationViewportEntry(
                    id: "following",
                    revision: 0,
                    content: AnyView(Text("Following row").frame(height: 32))
                )
            ],
            makeEntries: { _ in [] },
            bottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()

        let collectionView = try XCTUnwrap(
            firstDescendant(of: UICollectionView.self, in: controller.view)
        )
        let assistant = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        )
        let following = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame
        )

        XCTAssertGreaterThanOrEqual(assistant.height, 619)
        XCTAssertGreaterThanOrEqual(following.minY + 0.5, assistant.maxY)
    }

    @MainActor
    func testLongSecondaryContextUsesBoundedScrollableViewport() {
        let item = ConversationItem(
            id: "long-context",
            kind: .context,
            title: "上下文注入",
            text: String(repeating: "A long compacted context line with markdown content. ", count: 80),
            isError: false,
            date: Date(timeIntervalSince1970: 1)
        )
        let host = UIHostingController(
            rootView: ConversationEventDetailRow(item: item, role: .context)
        )

        let size = host.sizeThatFits(
            in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        )

        XCTAssertGreaterThan(size.height, 300)
        XCTAssertLessThanOrEqual(size.height, 330)
    }
}

final class ConversationProcessProjectionTests: XCTestCase {
    func testExpansionCreatesStableHeaderAndIndependentDescendantItems() {
        let date = Date(timeIntervalSince1970: 1)
        let command = ConversationItem(
            id: "command",
            kind: .status,
            title: "goal",
            text: String(repeating: "Goal detail ", count: 12),
            isError: false,
            date: date
        )
        let context = ConversationItem(
            id: "context",
            kind: .context,
            title: "上下文注入",
            text: "context body",
            isError: false,
            date: date
        )
        let reasoning = ConversationItem(
            id: "reasoning",
            kind: .reasoning,
            title: "Think",
            text: "reasoning body",
            isError: false,
            date: date
        )
        let call = ConversationItem(
            id: "call",
            kind: .tool,
            title: "Read",
            text: #"{"path":"README.md"}"#,
            isError: false,
            date: date
        )
        let result = ConversationItem(
            id: "result",
            kind: .toolResult,
            title: "完成",
            text: "file contents",
            isError: false,
            date: date
        )
        let group = ConversationProcessGroup(
            id: "process-command",
            items: [command, context, reasoning, call, result]
        )

        let collapsed = ConversationProcessNode.make(from: group, expandedNodeIDs: [])
        XCTAssertEqual(collapsed.map(\.id), ["process-command"])

        let groupExpanded: Set<String> = ["process-command"]
        let firstLevel = ConversationProcessNode.make(from: group, expandedNodeIDs: groupExpanded)
        XCTAssertEqual(firstLevel.map(\.id), [
            "process-command",
            "process-command/command-detail",
            "process-command/context/context",
            "process-command/reasoning",
            "process-command/tools"
        ])
        XCTAssertEqual(firstLevel.first?.id, collapsed.first?.id)
        XCTAssertTrue(firstLevel.dropFirst().allSatisfy { $0.parentID == "process-command" })

        let fullyExpanded = ConversationProcessNode.make(
            from: group,
            expandedNodeIDs: groupExpanded.union([
                "process-command/context/context",
                "process-command/reasoning",
                "process-command/tools",
                "process-command/tools/call"
            ])
        )
        XCTAssertEqual(fullyExpanded.map(\.id), [
            "process-command",
            "process-command/command-detail",
            "process-command/context/context",
            "process-command/context/context/detail",
            "process-command/reasoning",
            "process-command/reasoning/detail",
            "process-command/tools",
            "process-command/tools/call",
            "process-command/tools/call/detail"
        ])
    }

    func testEmptyEventDetailsNeverCreateBlankDescendantRows() {
        let date = Date(timeIntervalSince1970: 1)
        let command = ConversationItem(
            id: "command",
            kind: .status,
            title: "compact",
            text: "完成",
            isError: false,
            date: date
        )
        let context = ConversationItem(
            id: "empty-context",
            kind: .context,
            title: "上下文注入",
            text: "",
            isError: false,
            date: date
        )
        let call = ConversationItem(
            id: "empty-call",
            kind: .tool,
            title: "Read",
            text: "",
            isError: false,
            date: date
        )
        let result = ConversationItem(
            id: "empty-result",
            kind: .toolResult,
            title: "完成",
            text: "",
            isError: false,
            date: date
        )
        let group = ConversationProcessGroup(
            id: "process-command",
            items: [command, context, call, result]
        )
        let expanded: Set<String> = [
            "process-command",
            "process-command/context/empty-context",
            "process-command/tools",
            "process-command/tools/empty-call"
        ]

        let nodes = ConversationProcessNode.make(from: group, expandedNodeIDs: expanded)

        XCTAssertEqual(nodes.map(\.id), [
            "process-command",
            "process-command/context/empty-context",
            "process-command/tools",
            "process-command/tools/empty-call"
        ])
    }
}

final class GatewayProtocolTests: XCTestCase {
    func testQueueFramesSurviveSwiftDecodeAndSharedBridge() throws {
        let json = #"{"kind":"session-queues","queues":{"s":[{"id":"q","placement":"queued","message":{"id":"m","content":[{"type":"text","text":"再写一个 👏"}]}}]}}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        let queue = DeepSeekHarnessShared.SharedQueueStore()
        let encoded = try JSONEncoder().encode(frame)
        let snapshot = queue.acceptFrame(json: String(decoding: encoded, as: UTF8.self))
        XCTAssertEqual(snapshot.queues["s"]?.first?.text, "再写一个 👏")
        XCTAssertNotNil(queue.beginAction(sessionId: "s", itemId: "q", action: "edit"))
        let ack = GatewayFrame(kind: "queue-item-updated", sessionId: "s", itemId: "q", action: "remove", accepted: true)
        _ = queue.acceptFrame(json: String(decoding: try JSONEncoder().encode(ack), as: UTF8.self))
        XCTAssertEqual(queue.takeDraft(sessionId: "s"), "再写一个 👏")
        XCTAssertNil(queue.takeDraft(sessionId: "s"))
    }

    func testWireDecoderAcceptsWellFormedPreviewAndPreservesUnicodeAndJSONTypes() throws {
        let data = Data(#"{"kind":"sessions","items":[{"projections":{"values":{"turnOutline":[{"response":"鼓掌 �…"}]}},"text":"👏中文","literal":"\\ud83d","values":[1,1.5,true,false,null]}]}"#.utf8)
        let frame = try GatewayWireDecoder.decode(data)
        let item = try XCTUnwrap(frame.items?.first)
        XCTAssertEqual(item["projections"]?["values"]?["turnOutline"]?.arrayValue?.first?["response"]?.stringValue, "鼓掌 �…")
        XCTAssertEqual(item["text"]?.stringValue, "👏中文")
        XCTAssertEqual(item["literal"]?.stringValue, #"\ud83d"#)
        XCTAssertEqual(item["values"]?.arrayValue, [.number(1), .number(1.5), .bool(true), .bool(false), .null])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item)), item)
    }

    func testWireDecoderReportsNestedFailureWithoutEchoingFrameContents() {
        let data = Data(#"{"kind":"models","current":{"provider":123},"token":"private-test-token"}"#.utf8)
        XCTAssertThrowsError(try GatewayWireDecoder.decode(data)) { error in
            let description = GatewayWireDecoder.failureDescription(error)
            XCTAssertTrue(description.contains("current.provider"))
            XCTAssertFalse(description.contains("private-test-token"))
        }
    }

    func testConversationRequestsAreSeparatedFromFilesAndSessionControls() {
        for type in ["message", "history", "subscribe", "unsubscribe"] {
            XCTAssertTrue(GatewayClient.usesConversationChannel(type))
        }
        for type in ["file-list", "file-download-open", "file-download-read", "file-download-cancel",
                     "session-rename", "session-archive", "session-cancel", "permission-options",
                     "question-answer", "approval-response", "commands", "ping"] {
            XCTAssertFalse(GatewayClient.usesConversationChannel(type))
        }
    }

    @MainActor
    func testStreamingBurstDoesNotPublishCommandMenuAndKeepsControlResponsesInOrder() throws {
        let gateway = GatewayClient()
        var commandDeliveries = 0
        var deliveredKinds: [String] = []
        gateway.onCommandFrame = { _ in commandDeliveries += 1 }
        gateway.onFrame = { deliveredKinds.append($0.kind) }
        let eventData = Data(GatewayProtocolParityFixtures.liveEventWithoutKind.utf8)
        let event = try GatewayWireDecoder.decode(eventData)
        for index in 0..<2_000 {
            gateway.deliverApplicationFrame(event, data: eventData)
            if index == 1_000 {
                for kind in ["file-list", "session-renamed", "permission-options"] {
                    gateway.deliverApplicationFrame(GatewayFrame(kind: kind), data: Data())
                }
            }
        }
        XCTAssertEqual(commandDeliveries, 0)
        XCTAssertEqual(deliveredKinds.count, 2_003)
        XCTAssertEqual(Array(deliveredKinds[1_001...1_003]), ["file-list", "session-renamed", "permission-options"])
        XCTAssertEqual(deliveredKinds.filter { $0 == "event" }.count, 2_000)
    }

    @MainActor
    func testCommandFramesKeepOriginalPayloadAndOnlyMatchingErrorsReachMenu() throws {
        let gateway = GatewayClient()
        var commandPayloads: [String] = []
        gateway.onCommandFrame = { commandPayloads.append($0) }
        let payloads = [
            #"{"kind":"commands","sessionId":"s1","groups":[]}"#,
            #"{"kind":"command-options","sessionId":"s1"}"#,
            #"{"kind":"command-selected","sessionId":"s1"}"#,
            #"{"kind":"error","requestType":"commands"}"#,
            #"{"kind":"error","requestType":"command-options"}"#,
            #"{"kind":"error","requestType":"command-select"}"#
        ]
        for payload in payloads + [#"{"kind":"error","requestType":"file-list"}"#, #"{"kind":"error"}"#] {
            let data = Data(payload.utf8)
            gateway.deliverApplicationFrame(try GatewayWireDecoder.decode(data), data: data)
        }
        XCTAssertEqual(commandPayloads, payloads)
    }

    @MainActor
    func testSessionCreationRejectsDisconnectedTransport() async {
        let gateway = GatewayClient()
        do {
            _ = try await gateway.createSession(workspaceId: "w1")
            XCTFail("Disconnected creation must fail without waiting for a timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    @MainActor
    func testLateSessionCreationFramesAreConsumedWithoutRoutingToCurrentConversation() throws {
        let gateway = GatewayClient()
        let created = try GatewayWireDecoder.decode(Data(#"{"kind":"session-created","requestId":"old-request","sessionId":"empty-1"}"#.utf8))
        XCTAssertEqual(created.sessionId, "empty-1")
        XCTAssertEqual(created.requestId, "old-request")
        XCTAssertTrue(gateway.acceptSessionCreationFrame(created))
        let failure = try GatewayWireDecoder.decode(Data(#"{"kind":"error","requestType":"session-create","requestId":"old-request","message":"failed"}"#.utf8))
        XCTAssertTrue(gateway.acceptSessionCreationFrame(failure))
        XCTAssertFalse(gateway.acceptSessionCreationFrame(GatewayFrame(kind: "sent", sessionId: "s1")))
    }

    @MainActor
    private func flushDeferredKMPEvents(in store: AppStore) async {
        await store.awaitPendingKMPEventDeliveriesForTesting()
    }

    func testWorkspaceFileProtocolFramesDecodeWithoutDirectoryHiddenField() throws {
        let frame = try GatewayWireDecoder.decode(Data(#"{"kind":"file-list","requestId":"files-1","sessionId":"s1","path":".","entries":[{"name":"build","path":"build","kind":"directory"},{"name":"app.apk","path":"app.apk","kind":"file","bytes":42,"modifiedAt":1787111700000,"mediaType":"application/vnd.android.package-archive"}]}"#.utf8))
        XCTAssertEqual(frame.requestId, "files-1")
        XCTAssertEqual(frame.entries?.map(\.name), ["build", "app.apk"])
        XCTAssertEqual(frame.entries?.first?.hidden, false)
        XCTAssertEqual(frame.entries?.last?.bytes, 42)

        let chunk = try GatewayWireDecoder.decode(Data(#"{"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"YQ==","eof":true,"sha256":"ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"}"#.utf8))
        XCTAssertEqual(chunk.transferId, "t1")
        XCTAssertEqual(chunk.offset, 0)
        XCTAssertEqual(chunk.eof, true)
    }

    @MainActor
    func testConversationViewportReportsOnlyEmptyContentBoundaries() async throws {
        let timeline = ConversationTimeline()
        var availability: [String] = []
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { sessionID, hasContent in
                availability.append("\(sessionID ?? "nil"):\(hasContent)")
            },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        controller.view.layoutIfNeeded()
        controller.configure(
            sessionID: "history-session",
            timeline: timeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map {
                    ConversationViewportEntry(
                        id: $0.id,
                        revision: 0,
                        content: AnyView(EmptyView())
                    )
                }
            },
            bottomInset: 0
        )
        XCTAssertEqual(availability, ["history-session:false"])

        let item = ConversationItem(
            id: "message-1",
            kind: .assistant,
            title: "DeepSeek",
            text: "first page",
            isError: false,
            date: Date(timeIntervalSince1970: 1)
        )
        let secondItem = ConversationItem(
            id: "message-2",
            kind: .assistant,
            title: "DeepSeek",
            text: "second page",
            isError: false,
            date: Date(timeIntervalSince1970: 2)
        )
        timeline.publish([item])
        timeline.publish([item, secondItem])

        // 内容可用事件必须晚于 diffable snapshot completion，不能在 cell
        // 真正显示前提前撤掉不透明加载层。
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            availability,
            ["history-session:false", "history-session:true"],
            "Timeline 仅在空/非空边界通知 SwiftUI，流式 token 不得重绘整页"
        )

        let nextTimeline = ConversationTimeline()
        nextTimeline.publish([ConversationItem(
            id: "next-message",
            kind: .user,
            title: "You",
            text: "next session",
            isError: false,
            date: Date(timeIntervalSince1970: 3)
        )])
        controller.configure(
            sessionID: "next-session",
            timeline: nextTimeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map {
                    ConversationViewportEntry(
                        id: $0.id,
                        revision: 0,
                        content: AnyView(EmptyView())
                    )
                }
            },
            bottomInset: 0
        )
        let collectionView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UICollectionView }.first
        )
        XCTAssertTrue(collectionView.isHidden, "新 session snapshot 提交前必须隐藏旧 cell")

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(collectionView.isHidden, "新 session snapshot 提交后应恢复显示")
        XCTAssertEqual(
            Array(availability.suffix(2)),
            ["next-session:false", "next-session:true"],
            "新 Session 必须先报告不可见，自己的 snapshot 提交后才能报告可见"
        )
    }

    @MainActor
    func testConversationPreparationCommitsDeferredSelectionBeforeNavigation() async {
        let first = SessionSummary(
            id: "first-session",
            title: "First",
            lastActivity: Date(timeIntervalSince1970: 1),
            isRunning: false,
            hasUnread: false
        )
        let second = SessionSummary(
            id: "second-session",
            title: "Second",
            lastActivity: Date(timeIntervalSince1970: 2),
            isRunning: false,
            hasUnread: false
        )
        let store = AppStore(preferences: AppPreferencesSpy(
            endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil,
            sessions: [first, second]
        ))

        let preparedFirst = await store.prepareConversation(for: first)
        XCTAssertTrue(preparedFirst)
        XCTAssertEqual(store.selectedSessionId, first.id)

        let preparedSecond = await store.prepareConversation(for: second)
        XCTAssertTrue(preparedSecond)
        XCTAssertEqual(
            store.selectedSessionId,
            second.id,
            "prepare 返回时目标 Session 的延迟 KMP Event 必须已经发布，导航不能看到旧 ID"
        )
    }

    @MainActor
    func testHelloWithoutHistoryFormatInvalidatesOldCoordinatesBeforeReload() async throws {
        let session = SessionSummary(
            id: "session-catch-up",
            title: "Catch Up",
            lastActivity: Date(timeIntervalSince1970: 103),
            isRunning: true,
            hasUnread: false
        )
        let store = AppStore(preferences: AppPreferencesSpy(
            endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil,
            sessions: [session]
        ))
        let prepared = await store.prepareConversation(for: session)
        XCTAssertTrue(prepared)

        // The restored subscription first sees only the Agent reply. The user
        // message was emitted while this client was suspended.
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"event","sessionId":"session-catch-up","seq":3,"time":103,"event":{"type":"assistant/message","turn":2,"step":1,"text":"Agent 回复"}}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(store.events[session.id]?.map(\.event.text), ["Agent 回复"])

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"hello","protocol":3,"capabilities":[],"authenticated":true,"clients":2}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(store.historyLoadingSessionIds.contains(session.id))
        XCTAssertTrue(store.events[session.id, default: []].isEmpty)

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"history","events":[{"type":"user/message","seq":2,"time":102,"data":{"content":[{"type":"text","text":"后台期间的问题"}],"source":{"kind":"user"}}},{"type":"assistant/message","seq":3,"time":103,"data":{"message":{"content":[{"type":"text","text":"重新加载的回复"}]}}}],"hasMore":false,"bytes":128}"#.utf8
        )))
        for _ in 0..<100 where store.historyLoadingSessionIds.contains(session.id) {
            try await Task.sleep(for: .milliseconds(10))
            await flushDeferredKMPEvents(in: store)
        }

        XCTAssertEqual(store.events[session.id]?.map(\.event.text), ["后台期间的问题", "重新加载的回复"])
        XCTAssertFalse(store.historyLoadingSessionIds.contains(session.id))
    }

    /// The defect this pins: DSH 0.1.5's live `agent/assistant-stream` channel
    /// emits every chunk of a turn under the SAME turn-level `session.seq`. The
    /// client classified the second and later chunks as an `upsert`, and every
    /// non-`append` patch took `kmpConversationStore.replace(...)` — a full
    /// conversation rebuild plus an `associateBy(seq)` collapse, once per
    /// streamed token. This drives real gateway-shaped frames through `AppStore`
    /// and asserts the row-local path is taken and the fragments accumulate.
    @MainActor
    func testRc2InvisiblePersistentEventsKeepTransientWatermarkInSync() throws {
        let adapter = KMPConversationStoreAdapter()
        try adapter.replace(sessionID: "s", events: [
            SessionEvent(sessionId: "s", seq: 40, time: 100, event: GatewayEvent(type: "user/message", text: "Hi"))
        ])
        var changes = 0
        adapter.onChange = { _ in changes += 1 }
        for (offset, type) in ["turn/start", "step/start", "request/header"].enumerated() {
            try adapter.receive(SessionEvent(sessionId: "s", seq: 41 + offset, time: 101,
                event: GatewayEvent(type: type, turn: 2, step: 1)))
        }
        XCTAssertEqual(adapter.lastSequenceBySessionID["s"], 43)
        XCTAssertEqual(changes, 0, "仅推进流水位不应触发对话重绘")
        try adapter.assistantChunks(sessionID: "s", attemptID: "attempt", chunksJSON:
            #"[{"time":102,"chunk":{"type":"text-delta","index":0,"text":"Hello"}}]"#)
        try adapter.receive(SessionEvent(sessionId: "s", seq: 44, time: 103,
            event: GatewayEvent(type: "step/end", turn: 2, step: 1)))
        try adapter.clearAssistantChunks(sessionID: "s")
        XCTAssertEqual(adapter.lastSequenceBySessionID["s"], 44)
        XCTAssertEqual(adapter.items(for: "s").map(\.text), ["Hi"])
        XCTAssertNil(adapter.runtimeError)
    }

    @MainActor
    func testRc2ReopeningCompletedSessionClearsStaleRunningState() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"sessions","items":[{"sessionId":"mask-session","updatedAt":100,"running":true,"blank":false}]}"#)
        XCTAssertTrue(store.selectedSession?.isRunning == true)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":12,"events":[{"type":"turn/start","seq":10,"time":100,"data":{"turn":1}},{"type":"assistant/message","seq":11,"time":101,"data":{"message":{"content":[{"type":"text","text":"已完成"}]}}},{"type":"turn/end","seq":12,"time":102,"data":{"turn":1,"reason":"completed"}}],"hasMore":false}"#)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "已完成")
        XCTAssertFalse(try XCTUnwrap(store.selectedSession).isRunning)
        XCTAssertNil(store.lastError)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"event","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","seq":13,"time":103,"event":{"type":"turn/start","turn":2}}"#)
        XCTAssertTrue(store.selectedSession?.isRunning == true)
    }

    @MainActor
    func testRc2ColdHistoryWaitsForMatchingSnapshotAndPreservesPagination() async throws {
        let (store, _) = try await makeRc2HistoryLoadingStore()
        XCTAssertTrue(store.historyLoadingSessionIds.contains("mask-session"))
        XCTAssertEqual(store.historyLoadProgress["mask-session"]?.loaded, 0)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        XCTAssertTrue(store.historyLoadingSessionIds.contains("mask-session"))
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"old","streamId":"old","historyFormatVersion":3,"cursor":10,"events":[],"hasMore":false}"#)
        XCTAssertTrue(store.historyLoadingSessionIds.contains("mask-session"), "迟到快照不能撤掉当前遮罩")
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":10,"events":[{"type":"assistant/message","seq":10,"time":100,"data":{"message":{"content":[{"type":"text","text":"历史回复"}]}}}],"hasMore":true,"nextBeforeSeq":10}"#)
        XCTAssertFalse(store.historyLoadingSessionIds.contains("mask-session"))
        XCTAssertEqual(store.historyHasMore["mask-session"], true)
        await store.awaitConversationProjectionForTesting(sessionID: "mask-session", expectedText: "历史回复")
        XCTAssertEqual(store.renderedConversationItems["mask-session"]?.last?.text, "历史回复")
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testRc2EmptySnapshotEndsLoadingAndCachedRefreshKeepsRows() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":10,"events":[{"type":"assistant/message","seq":10,"time":100,"data":{"message":{"content":[{"type":"text","text":"缓存回复"}]}}}],"hasMore":false}"#)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "缓存回复")
        let prepared = await store.prepareConversation(for: session)
        XCTAssertTrue(prepared)
        XCTAssertTrue(store.historyLoadingSessionIds.contains(session.id))
        XCTAssertEqual(store.renderedConversationItems[session.id]?.last?.text, "缓存回复", "刷新期间不能清空可读内容")
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"new","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"new","streamId":"new","historyFormatVersion":3,"cursor":0,"events":[],"hasMore":false}"#)
        XCTAssertFalse(store.historyLoadingSessionIds.contains(session.id))
        for _ in 0..<100 where !store.renderedConversationItems[session.id, default: []].isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.renderedConversationItems[session.id, default: []].isEmpty)
    }

    @MainActor
    func testRc2ReconnectKeepsVisibleHistoryAndSkipsIdenticalReplacement() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        let snapshot = #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":10,"events":[{"type":"assistant/message","seq":10,"time":100,"data":{"message":{"content":[{"type":"text","text":"已有历史"}]}}}],"hasMore":true,"nextBeforeSeq":10}"#
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store, snapshot)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "已有历史")
        let revision = store.conversationTimeline(for: session.id).currentSnapshot.revision
        // 主动后台挂起后的 hello，没有先调用 onConnectionFailure。
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"hello","historyFormatVersion":3,"capabilities":["assistant-stream-v1"]}"#)
        XCTAssertTrue(store.historyLoadingSessionIds.contains(session.id))
        XCTAssertFalse(store.isPreparingConversation(session.id), "有可用行时重连同步不能变成首屏等待")
        XCTAssertEqual(store.renderedConversationItems[session.id]?.last?.text, "已有历史")
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store, snapshot)
        XCTAssertFalse(store.historyLoadingSessionIds.contains(session.id))
        XCTAssertEqual(store.conversationTimeline(for: session.id).currentSnapshot.revision, revision,
            "相同快照不应重建投影或重新发布 UIKit 列表")
        XCTAssertTrue(store.historyHasMore[session.id] == true)
    }

    @MainActor
    func testRc2UnchangedEmptyHistoryStillRestoresNewAssistantPrefix() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        for (subscription, text) in [("first", "旧前缀"), ("second", "恢复后的新前缀")] {
            try await deliverHistoryLoadingFrame(store,
                #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"SUB","assistantStream":true}"#.replacingOccurrences(of: "SUB", with: subscription))
            let snapshot = #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"SUB","streamId":"SUB","historyFormatVersion":3,"cursor":0,"events":[],"hasMore":false,"assistantStream":{"revision":2,"activeAttempt":{"attemptId":"attempt","turn":1,"step":1,"startedAfterSeq":0,"nextIndex":1,"stream":[{"type":"text-chunks","index":0,"time0":100,"texts":["TEXT"],"dt":[]}]}}}"#
                .replacingOccurrences(of: "SUB", with: subscription).replacingOccurrences(of: "TEXT", with: text)
            try await deliverHistoryLoadingFrame(store, snapshot)
            await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: text)
            XCTAssertEqual(store.renderedConversationItems[session.id]?.map(\.text), [text],
                "持久历史不变时仍须恢复新前缀，且只恢复一次")
        }
    }

    @MainActor
    func testRc2SnapshotWaitCleansUpOnSwitchExitAndDisconnect() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        let next = SessionSummary(id: "next", title: "Next", lastActivity: Date(), isRunning: false, hasUnread: false)
        let prepared = await store.prepareConversation(for: next)
        XCTAssertTrue(prepared)
        XCTAssertFalse(store.historyLoadingSessionIds.contains(session.id))
        XCTAssertTrue(store.historyLoadingSessionIds.contains(next.id))
        store.resumeWorkspace()
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(store.historyLoadingSessionIds.isEmpty)
        _ = await store.prepareConversation(for: session)
        store.gateway.onConnectionFailure?("测试断连")
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(store.historyLoadingSessionIds.isEmpty)
    }

    @MainActor
    func testDisconnectPreservesVisibleAssistantPrefixAndOfflineNavigationDoesNotResubscribe() async throws {
        let session = SessionSummary(id: "offline-prefix", title: "进行中的会话", lastActivity: .now,
            isRunning: true, hasUnread: false)
        let store = AppStore(preferences: AppPreferencesSpy(endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil, sessions: [session]), historyRequestTimeout: .milliseconds(20), chatHistoryCache: nil)
        _ = await store.prepareConversation(for: session)
        for json in [
            #"{"kind":"hello","historyFormatVersion":3,"capabilities":["assistant-stream-v1"]}"#,
            #"{"kind":"subscribed","sessionId":"offline-prefix","subscriptionId":"sub","assistantStream":true}"#,
            #"{"kind":"session-snapshot","sessionId":"offline-prefix","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":0,"events":[],"hasMore":false,"assistantStream":{"revision":2,"activeAttempt":{"attemptId":"attempt","turn":1,"step":1,"startedAfterSeq":0,"nextIndex":1,"stream":[{"type":"text-chunks","index":0,"time0":100,"texts":["断线前可见的生成内容"],"dt":[]}]}}}"#
        ] {
            try await deliverHistoryLoadingFrame(store, json)
        }
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "断线前可见的生成内容")
        store.gateway.onConnectionFailure?("连接已中断")
        store.disconnect()
        store.resumeWorkspace()
        _ = await store.prepareConversation(for: session)
        try await Task.sleep(for: .milliseconds(70))
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(store.selectedConversationItems.last?.text, "断线前可见的生成内容")
        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        XCTAssertTrue(store.historyLoadingSessionIds.isEmpty)
        XCTAssertFalse(store.isPreparingConversation(session.id))
        XCTAssertNil(store.lastError)
        store.deactivateGateway()
    }

    @MainActor
    func testRc2SnapshotWaitTimesOutInsteadOfLeavingMaskForever() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore(timeout: .milliseconds(50))
        for _ in 0..<100 where store.historyLoadingSessionIds.contains(session.id) {
            try await Task.sleep(for: .milliseconds(10))
            await flushDeferredKMPEvents(in: store)
        }
        XCTAssertFalse(store.historyLoadingSessionIds.contains(session.id))
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testSnapshotDoesNotExposeEmptyStateBeforeConversationProjection() async throws {
        let (store, _) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":10,"events":[{"type":"assistant/message","seq":10,"time":100,"data":{"message":{"content":[{"type":"text","text":"已到达的历史"}]}}}],"hasMore":false}"#)
        XCTAssertTrue(store.isPreparingConversation("mask-session") || !store.renderedConversationItems["mask-session", default: []].isEmpty,
            "网络结束到列表发布之间必须保持加载态，不能出现空会话")
        await store.awaitConversationProjectionForTesting(sessionID: "mask-session", expectedText: "已到达的历史")
        XCTAssertFalse(store.isPreparingConversation("mask-session"))
        XCTAssertEqual(store.renderedConversationItems["mask-session"]?.last?.text, "已到达的历史")
    }

    @MainActor
    func testTrulyEmptySnapshotCompletesPresentation() async throws {
        let (store, _) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":0,"events":[],"hasMore":false}"#)
        for _ in 0..<200 where store.isPreparingConversation("mask-session") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.isPreparingConversation("mask-session"))
        XCTAssertTrue(store.renderedConversationItems["mask-session", default: []].isEmpty)
    }

    func testStreamValidationSkipsHistoryBodyButPreservesAtomicBaseline() throws {
        var frame = try GatewayWireDecoder.decode(Data(#"{"kind":"session-snapshot","sessionId":"s","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":65,"events":[{"type":"assistant/message","seq":60,"time":100,"data":{"message":{"content":[{"type":"text","text":"正文"}]}}}],"hasMore":true,"nextBeforeSeq":60,"assistantStream":{"revision":2},"projections":{"asOfSeq":65,"values":{}}}"#.utf8))
        let envelope = frame.assistantStreamValidationFrame
        XCTAssertNil(envelope.events)
        XCTAssertNil(envelope.projections)
        XCTAssertEqual(envelope.cursor, 65)
        XCTAssertEqual(envelope.subscriptionId, "sub")
        XCTAssertEqual(envelope.streamId, "stream")
        XCTAssertEqual(envelope.historyFormatVersion, 3)
        XCTAssertEqual(try JSONEncoder().encode(envelope.assistantStream), try JSONEncoder().encode(frame.assistantStream))
        XCTAssertEqual(frame.events?.count, 1, "校验优化不能修改原始快照")
        frame.kind = "history"
        XCTAssertNil(frame.assistantStreamValidationFrame.events)
        frame.kind = "event"
        XCTAssertEqual(frame.assistantStreamValidationFrame.events?.count, 1, "其他帧不能被精简")
    }

    @MainActor
    func testLargeSnapshotProcessingBenchmarkPreservesEveryMessage() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        let body = String(repeating: "历史正文测试。", count: 3_000)
        let records: [[String: Any]] = (1...60).map { index in
            ["type": "assistant/message", "seq": index, "time": 100 + index,
             "turn": index, "step": 1,
             "data": ["message": ["content": [["type": "text", "text": "\(index):\(body)"]]]]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "session-snapshot", "sessionId": session.id, "subscriptionId": "sub",
            "streamId": "stream", "historyFormatVersion": 3, "cursor": 65,
            "events": records, "hasMore": true, "nextBeforeSeq": 1
        ])
        let started = CFAbsoluteTimeGetCurrent()
        try await deliverHistoryLoadingFrame(store, String(decoding: data, as: UTF8.self))
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "60:\(body)")
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        print("HISTORY_BENCH bytes=\(data.count) messages=60 processingSeconds=\(elapsed)")
        let items = (store.renderedConversationItems[session.id] ?? [])
        XCTAssertEqual(items.filter { $0.kind == .assistant }.count, 60)
        XCTAssertEqual(items.last?.text, "60:\(body)")
        XCTAssertEqual(store.historyHasMore[session.id], true)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testFailedOpeningKeepsHistoryFailureInsteadOfEmptyWelcome() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-stream-reset","sessionId":"mask-session","subscriptionId":"sub","streamId":"opening","retrying":false,"message":"Host refuses this format v0 Session"}"#)
        XCTAssertFalse(store.isPreparingConversation(session.id))
        XCTAssertEqual(store.historyLoadErrors[session.id], "Host refuses this format v0 Session")
        _ = await store.prepareConversation(for: session)
        XCTAssertNil(store.historyLoadErrors[session.id])
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub2","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub2","streamId":"ok","historyFormatVersion":3,"cursor":0,"events":[],"hasMore":false}"#)
        XCTAssertNil(store.historyLoadErrors[session.id])
    }

    @MainActor
    func testHistoryPresentationAdmissionCoversWorkerGapAndNeedsActualFinalAck() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":10,"events":[{"type":"assistant/message","seq":10,"time":100,"data":{"message":{"content":[{"type":"text","text":"existing"}]}}}],"hasMore":true,"nextBeforeSeq":10}"#)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "existing")
        let consumerID = UUID()
        var completed: [HistoryPresentationOutcome] = []
        store.attachHistoryPresentationConsumer(sessionID: session.id, consumer: .init(id: consumerID) {
            if case .finished(_, let outcome) = $0 { completed.append(outcome) }
        })
        XCTAssertTrue(store.requestOlderHistoryPresentation(sessionID: session.id, consumerID: consumerID))
        XCTAssertFalse(store.requestOlderHistoryPresentation(sessionID: session.id, consumerID: consumerID))
        // 真实网关响应在 request-page effect 已发送之后才可能到达。
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        XCTAssertTrue(store.historyLoadingSessionIds.contains(session.id))
        let entered = expectation(description: "older history worker entered")
        let gate = ConversationHistoryPreparationGate(entered: entered)
        store.conversationHistoryPreparationForTesting = { input in
            await gate.pause()
            return try KMPConversationStoreAdapter.prepareHistory(input)
        }
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"history","sessionId":"mask-session","historyFormatVersion":3,"events":[{"type":"user/message","seq":9,"time":9,"data":{"content":[{"type":"text","text":"older"}]}}],"hasMore":false}"#.utf8)))
        await fulfillment(of: [entered], timeout: 3)
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        XCTAssertFalse(store.historyLoadingSessionIds.contains(session.id))
        XCTAssertFalse(store.requestOlderHistoryPresentation(sessionID: session.id, consumerID: consumerID),
            "网络已经完成而 worker 尚未发布 timeline 时仍须拒绝新的 UI 分页")
        XCTAssertTrue(completed.isEmpty)
        XCTAssertNil(store.conversationTimeline(for: session.id).currentSnapshot.historyPresentationStamp)
        await gate.release()
        await flushDeferredKMPEvents(in: store)
        let timeline = store.conversationTimeline(for: session.id)
        for _ in 0..<200 where timeline.currentSnapshot.historyPresentationStamp == nil { try await Task.sleep(for: .milliseconds(5)) }
        let stamp = try XCTUnwrap(timeline.currentSnapshot.historyPresentationStamp)
        XCTAssertEqual(store.renderedConversationItems[session.id]?.map(\.text), ["older", "existing"])
        XCTAssertTrue(completed.isEmpty)
        store.acknowledgeHistoryPresentation(sessionID: session.id, consumerID: consumerID,
            stamp: .init(operationID: stamp.operationID, projectionEpoch: 999))
        XCTAssertTrue(completed.isEmpty)
        store.acknowledgeHistoryPresentation(sessionID: session.id, consumerID: consumerID, stamp: stamp)
        XCTAssertEqual(completed, [.presented])
        XCTAssertNil(timeline.currentSnapshot.historyPresentationStamp)
        store.detachHistoryPresentationConsumer(sessionID: session.id, consumerID: consumerID)
    }

    @MainActor
    func testHistoryPresentationEmptyBatchAndDetachedConsumerReleaseWithoutPublishingRows() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        let snapshot = #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":10,"events":[{"type":"assistant/message","seq":10,"time":100,"data":{"message":{"content":[{"type":"text","text":"existing"}]}}}],"hasMore":true,"nextBeforeSeq":10}"#
        try await deliverHistoryLoadingFrame(store, snapshot)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "existing")
        let consumerID = UUID()
        var completed: [HistoryPresentationOutcome] = []
        store.attachHistoryPresentationConsumer(sessionID: session.id, consumer: .init(id: consumerID) {
            if case .finished(_, let outcome) = $0 { completed.append(outcome) }
        })
        XCTAssertTrue(store.requestOlderHistoryPresentation(sessionID: session.id, consumerID: consumerID))
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        XCTAssertTrue(store.historyLoadingSessionIds.contains(session.id))
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"history","sessionId":"mask-session","historyFormatVersion":3,"events":[],"hasMore":false}"#)
        // page 的纯 parse 在 detached worker；MVI 队列短暂无待办不代表它已完成。
        for _ in 0..<200 where completed.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completed, [.empty])
        XCTAssertEqual(store.renderedConversationItems[session.id]?.last?.text, "existing")
        store.detachHistoryPresentationConsumer(sessionID: session.id, consumerID: consumerID)
        XCTAssertFalse(store.requestOlderHistoryPresentation(sessionID: session.id, consumerID: consumerID))
        XCTAssertNil(store.conversationTimeline(for: session.id).currentSnapshot.historyPresentationStamp)
    }

    @MainActor
    func testStaticHistoryWorkerCoalescesLatestBeforeLiveAndCannotRollbackAfterFinishing() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        let entered = expectation(description: "worker entered")
        let gate = ConversationHistoryPreparationGate(entered: entered)
        store.conversationHistoryPreparationForTesting = { input in
            await gate.pause()
            return try KMPConversationStoreAdapter.prepareHistory(input)
        }
        try sendStaticHistorySnapshot(store, texts: ["one"])
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(store.conversationHistoryWorkerCountForTesting, 1)
        try sendStaticHistorySnapshot(store, texts: ["one", "two"])
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        XCTAssertEqual(store.conversationHistoryWorkerCountForTesting, 1)
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"event","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","seq":3,"time":3,"event":{"type":"assistant/message","turn":1,"step":1,"text":"live"}}"#.utf8)))
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "live")
        XCTAssertEqual(store.renderedConversationItems[session.id]?.map(\.text), ["one", "two", "live"])
        await gate.release()
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(store.events[session.id]?.map(\.seq), [1, 2, 3])
        XCTAssertEqual(store.renderedConversationItems[session.id]?.map(\.text), ["one", "two", "live"])
        XCTAssertEqual(store.conversationHistoryWorkerCountForTesting, 0)
    }

    @MainActor
    func testStaticHistoryWorkerCannotResurrectDeletedSession() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        let entered = expectation(description: "worker entered")
        let gate = ConversationHistoryPreparationGate(entered: entered)
        store.conversationHistoryPreparationForTesting = { input in
            await gate.pause()
            return try KMPConversationStoreAdapter.prepareHistory(input)
        }
        try sendStaticHistorySnapshot(store, texts: ["must disappear"])
        await fulfillment(of: [entered], timeout: 3)
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(#"{"kind":"sessions","items":[]}"#.utf8)))
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        await gate.release()
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.events[session.id, default: []].isEmpty)
        XCTAssertEqual(store.conversationHistoryWorkerCountForTesting, 0)
        for _ in 0..<100 where store.isPreparingConversation(session.id) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isPreparingConversation(session.id))
        XCTAssertTrue(store.renderedConversationItems[session.id, default: []].isEmpty)
    }

    @MainActor
    func testStaticHistoryWorkerFailureFallsBackWithoutLeavingLoading() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        store.conversationHistoryPreparationForTesting = { _ in throw NSError(domain: "test-pure-prepare", code: 1) }
        try sendStaticHistorySnapshot(store, texts: ["fallback"])
        await flushDeferredKMPEvents(in: store)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "fallback")
        XCTAssertEqual(store.renderedConversationItems[session.id]?.map(\.text), ["fallback"])
        XCTAssertFalse(store.isPreparingConversation(session.id))
        XCTAssertEqual(store.conversationHistoryWorkerCountForTesting, 0)
    }

    @MainActor
    func testStaticHistoryWorkerFlushesBeforeSteeringAndStreamWithoutDuplicatingPrefix() async throws {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        let entered = expectation(description: "worker entered")
        let gate = ConversationHistoryPreparationGate(entered: entered)
        store.conversationHistoryPreparationForTesting = { input in
            await gate.pause()
            return try KMPConversationStoreAdapter.prepareHistory(input)
        }
        try sendStaticHistorySnapshot(store, texts: ["one"])
        await fulfillment(of: [entered], timeout: 3)
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"session-queue","sessionId":"mask-session","items":[{"id":"q","placement":"steering","message":{"id":"m","content":[{"type":"text","text":"queued"}]}}]}"#.utf8)))
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "queued")
        XCTAssertEqual(store.renderedConversationItems[session.id]?.map(\.text), ["one", "queued"])
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":1,"events":[{"type":"user/message","seq":1,"time":1,"data":{"content":[{"type":"text","text":"one"}]}}],"hasMore":false,"assistantStream":{"revision":2,"activeAttempt":{"attemptId":"attempt","turn":2,"step":1,"startedAfterSeq":1,"nextIndex":1,"stream":[{"type":"text-chunks","index":0,"time0":100,"texts":["Hello"],"dt":[]}]}}}"#.utf8)))
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"assistant-stream","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","frame":{"type":"chunk","attemptId":"attempt","revision":3,"index":1,"time":101,"turn":2,"step":1,"chunk":{"type":"text-delta","index":0,"text":" world"}}}"#.utf8)))
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        await gate.release()
        await flushDeferredKMPEvents(in: store)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "Hello world")
        XCTAssertEqual(store.renderedConversationItems[session.id]?.filter { $0.kind == .assistant }.map(\.text), ["Hello world"])
        XCTAssertEqual(store.conversationHistoryWorkerCountForTesting, 0)
    }

    @MainActor
    private func sendStaticHistorySnapshot(_ store: AppStore, texts: [String]) throws {
        let raw: [[String: Any]] = texts.enumerated().map { index, text in
            ["type": "user/message", "seq": index + 1, "time": index + 1,
             "data": ["content": [["type": "text", "text": text]]]]
        }
        let payload: [String: Any] = ["kind": "session-snapshot", "sessionId": "mask-session",
            "subscriptionId": "sub", "streamId": "stream", "historyFormatVersion": 3,
            "cursor": texts.count, "events": raw, "hasMore": false]
        store.gateway.onFrame?(try GatewayWireDecoder.decode(JSONSerialization.data(withJSONObject: payload)))
    }

    @MainActor
    private func makeReadingWindowFixture() async throws -> (AppStore, SessionSummary, UUID, HistoryReadingProbe) {
        let (store, session) = try await makeRc2HistoryLoadingStore()
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"subscribed","sessionId":"mask-session","subscriptionId":"sub","assistantStream":true}"#)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"session-snapshot","sessionId":"mask-session","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":100,"events":[{"type":"assistant/message","seq":100,"time":100,"data":{"message":{"content":[{"type":"text","text":"existing"}]}}}],"hasMore":true,"nextBeforeSeq":100}"#)
        await store.awaitConversationProjectionForTesting(sessionID: session.id, expectedText: "existing")
        let consumer = UUID(), probe = HistoryReadingProbe()
        store.attachHistoryPresentationConsumer(sessionID: session.id, consumer: .init(id: consumer) { probe.receive($0) })
        XCTAssertTrue(store.requestOlderHistoryPresentation(sessionID: session.id, consumerID: consumer,
            readingWindow: CGSize(width: 320, height: 200)))
        await store.awaitPendingKMPEventDeliveriesForTesting(includingHistoryPreparation: false)
        return (store, session, consumer, probe)
    }

    @MainActor
    private func readingPage(_ store: AppStore, _ range: ClosedRange<Int>, tools: Bool = false, more: Bool) async throws {
        let events: [[String: Any]] = range.map { seq -> [String: Any] in
            let payload: [String: Any]
            if tools { payload = ["name": "fixture", "arguments": ["value": "tool use"]] }
            else { payload = ["content": [["type": "text", "text": "short \(seq)"]]] }
            return ["type": tools ? "tool/call" : "user/message", "seq": seq, "time": seq, "data": payload]
        }
        let data = try JSONSerialization.data(withJSONObject: ["kind": "history", "sessionId": "mask-session",
            "historyFormatVersion": 3, "events": events, "hasMore": more, "nextBeforeSeq": range.lowerBound])
        store.gateway.onFrame?(try GatewayWireDecoder.decode(data))
        // 解析在后台完成；下一页只能在上一响应真正归并后送达。
        try await waitReading { store.events["mask-session"]?.first?.seq == range.lowerBound }
        await store.awaitPendingKMPEventDeliveriesForTesting()
    }

    @MainActor
    private func waitReading(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("阅读批次状态等待超时", file: file, line: line)
    }

    @MainActor
    func testReadingBatchToolsContinueUnderOneAdmissionAndPublishOnlyWithBody() async throws {
        let (store, session, consumer, probe) = try await makeReadingWindowFixture()
        defer { store.detachHistoryPresentationConsumer(sessionID: session.id, consumerID: consumer); store.deactivateGateway() }
        let timeline = store.conversationTimeline(for: session.id), revision = timeline.currentSnapshot.revision
        try await readingPage(store, 40...99, tools: true, more: true)
        try await waitReading { store.events[session.id]?.first?.seq == 40 && store.historyLoadingOlderSessionIds.contains(session.id) }
        XCTAssertEqual(timeline.currentSnapshot.revision, revision)
        try await readingPage(store, 10...39, tools: true, more: true)
        try await waitReading { store.events[session.id]?.first?.seq == 10 && store.historyLoadingOlderSessionIds.contains(session.id) }
        XCTAssertEqual(timeline.currentSnapshot.revision, revision)
        XCTAssertEqual(probe.began, 1)
        XCTAssertEqual(probe.terminals, 0)
        XCTAssertFalse(store.requestOlderHistoryPresentation(sessionID: session.id, consumerID: consumer))
        try await readingPage(store, 1...9, more: false)
        try await waitReading { timeline.currentSnapshot.historyPresentationStamp != nil }
        XCTAssertEqual(timeline.currentSnapshot.items.filter { $0.kind == .tool }.count, 90)
        XCTAssertEqual(timeline.currentSnapshot.items.filter { $0.kind == .user }.count, 9)
        XCTAssertEqual(probe.began, 1)
        XCTAssertEqual(probe.terminals, 1)
        XCTAssertTrue(probe.outcomes.isEmpty, "必须等实际呈现确认，不能在收到数据时结束")
        store.acknowledgeHistoryPresentation(sessionID: session.id, consumerID: consumer,
            stamp: try XCTUnwrap(timeline.currentSnapshot.historyPresentationStamp))
        XCTAssertEqual(probe.outcomes, [.presented])
    }

    @MainActor
    func testReadingBatchShortPagesStayFrozenUntilReadingWindowIsFilled() async throws {
        let (store, session, consumer, probe) = try await makeReadingWindowFixture()
        defer { store.detachHistoryPresentationConsumer(sessionID: session.id, consumerID: consumer); store.deactivateGateway() }
        let timeline = store.conversationTimeline(for: session.id), revision = timeline.currentSnapshot.revision
        try await readingPage(store, 99...99, more: true)
        try await readingPage(store, 98...98, more: true)
        try await waitReading { store.events[session.id]?.first?.seq == 98 && store.historyLoadingOlderSessionIds.contains(session.id) }
        XCTAssertEqual(timeline.currentSnapshot.revision, revision)
        try await readingPage(store, 90...97, more: true)
        XCTAssertEqual(timeline.currentSnapshot.revision, revision)
        try await readingPage(store, 80...89, more: true)
        try await waitReading { timeline.currentSnapshot.historyPresentationStamp != nil }
        XCTAssertEqual(timeline.currentSnapshot.items.filter { $0.kind == .user }.count, 20)
        XCTAssertFalse(store.historyLoadingOlderSessionIds.contains(session.id))
        XCTAssertTrue(store.selectedHistoryHasMore)
        XCTAssertEqual(probe.began, 1)
        store.acknowledgeHistoryPresentation(sessionID: session.id, consumerID: consumer,
            stamp: try XCTUnwrap(timeline.currentSnapshot.historyPresentationStamp))
        XCTAssertEqual(probe.outcomes, [.presented])
    }

    @MainActor
    func testReadingBatchFailureReleasesAlreadyReceivedTools() async throws {
        let (store, session, consumer, probe) = try await makeReadingWindowFixture()
        defer { store.detachHistoryPresentationConsumer(sessionID: session.id, consumerID: consumer); store.deactivateGateway() }
        try await readingPage(store, 40...99, tools: true, more: true)
        try await readingPage(store, 10...39, tools: true, more: true)
        try await waitReading { store.events[session.id]?.first?.seq == 10 && store.historyLoadingOlderSessionIds.contains(session.id) }
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"error","sessionId":"mask-session","requestType":"history","code":"fixture-failure","message":"fixture failure"}"#)
        let timeline = store.conversationTimeline(for: session.id)
        try await waitReading { !store.historyLoadingSessionIds.contains(session.id) && timeline.currentSnapshot.items.count == 91 }
        if let stamp = timeline.currentSnapshot.historyPresentationStamp {
            store.acknowledgeHistoryPresentation(sessionID: session.id, consumerID: consumer, stamp: stamp)
        }
        XCTAssertEqual(timeline.currentSnapshot.items.filter { $0.kind == .tool }.count, 90)
        XCTAssertEqual(probe.began, 1)
        XCTAssertFalse(probe.outcomes.isEmpty)
    }

    @MainActor
    private func makeRc2HistoryLoadingStore(timeout: Duration = .seconds(20)) async throws -> (AppStore, SessionSummary) {
        let session = SessionSummary(id: "mask-session", title: "History", lastActivity: Date(),
            isRunning: false, hasUnread: false)
        let store = AppStore(preferences: AppPreferencesSpy(endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil, sessions: [session]), historyRequestTimeout: timeout, chatHistoryCache: nil)
        store.gateway.installConnectedTransportForTesting()
        _ = await store.prepareConversation(for: session)
        try await deliverHistoryLoadingFrame(store,
            #"{"kind":"hello","historyFormatVersion":3,"capabilities":["assistant-stream-v1"]}"#)
        return (store, session)
    }

    @MainActor
    private func deliverHistoryLoadingFrame(_ store: AppStore, _ json: String) async throws {
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(json.utf8)))
        await flushDeferredKMPEvents(in: store)
    }

    @MainActor
    func testRc2SnapshotRestoresPrefixAndDeduplicatesFinalMessage() async throws {
        let session = SessionSummary(id: "s", title: "Stream", lastActivity: Date(timeIntervalSince1970: 100),
            isRunning: true, hasUnread: false)
        let store = AppStore(preferences: AppPreferencesSpy(endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil, sessions: [session]))
        let prepared = await store.prepareConversation(for: session)
        XCTAssertTrue(prepared)
        func deliver(_ json: String) async throws {
            store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(json.utf8)))
            await flushDeferredKMPEvents(in: store)
        }
        try await deliver(#"{"kind":"hello","historyFormatVersion":3,"capabilities":["assistant-stream-v1"]}"#)
        try await deliver(#"{"kind":"subscribed","sessionId":"s","subscriptionId":"sub","assistantStream":true}"#)
        try await deliver(#"{"kind":"session-snapshot","sessionId":"s","subscriptionId":"sub","streamId":"stream","historyFormatVersion":3,"cursor":41,"events":[],"hasMore":true,"nextBeforeSeq":20,"assistantStream":{"revision":2,"activeAttempt":{"attemptId":"s:1","turn":2,"step":3,"startedAfterSeq":41,"nextIndex":1,"stream":[{"type":"text-chunks","index":0,"time0":100,"texts":["Hello"],"dt":[]}]}}}"#)
        await store.awaitConversationProjectionForTesting(sessionID: "s", expectedText: "Hello")
        XCTAssertEqual(store.renderedConversationItems["s", default: []].last?.text, "Hello")
        XCTAssertTrue(store.events["s", default: []].isEmpty)
        let chunk = #"{"kind":"assistant-stream","sessionId":"s","subscriptionId":"sub","streamId":"stream","frame":{"type":"chunk","attemptId":"s:1","revision":3,"index":1,"time":101,"turn":2,"step":3,"chunk":{"type":"text-delta","index":0,"text":" world"}}}"#
        try await deliver(chunk)
        try await deliver(chunk)
        await store.awaitConversationProjectionForTesting(sessionID: "s", expectedText: "Hello world")
        XCTAssertEqual(store.renderedConversationItems["s", default: []].last?.text, "Hello world")
        try await deliver(#"{"kind":"history","sessionId":"s","historyFormatVersion":3,"events":[],"hasMore":false}"#)
        await store.awaitConversationProjectionForTesting(sessionID: "s", expectedText: "Hello world")
        XCTAssertEqual(store.renderedConversationItems["s", default: []].last?.text, "Hello world")
        let final = #"{"kind":"event","sessionId":"s","subscriptionId":"sub","streamId":"stream","seq":42,"time":102,"event":{"type":"assistant/message","turn":2,"step":3,"text":"Hello world","interrupted":true}}"#
        try await deliver(final)
        try await deliver(final)
        try await deliver(#"{"kind":"assistant-stream","sessionId":"s","subscriptionId":"sub","streamId":"stream","frame":{"type":"end","attemptId":"s:1","revision":4,"index":2,"turn":2,"step":3,"outcome":{"kind":"committed","eventType":"assistant/message","seq":42}}}"#)
        XCTAssertEqual(store.events["s"]?.map(\.seq), [42])
        XCTAssertEqual(store.renderedConversationItems["s", default: []].count, 1)
        await store.awaitConversationProjectionForTesting(sessionID: "s", expectedText: "Hello world")
        XCTAssertEqual(store.renderedConversationItems["s", default: []].last?.text, "Hello world")
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testSameSequenceStreamChunksAccumulateRowLocallyWithoutRebaseline() async throws {
        let session = SessionSummary(
            id: "session-stream",
            title: "Stream",
            lastActivity: Date(timeIntervalSince1970: 100),
            isRunning: true,
            hasUnread: false
        )
        let store = AppStore(preferences: AppPreferencesSpy(
            endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil,
            sessions: [session]
        ))
        let prepared = await store.prepareConversation(for: session)
        XCTAssertTrue(prepared)

        func deliver(_ json: String) async throws {
            store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(json.utf8)))
            await flushDeferredKMPEvents(in: store)
        }

        // The user's prompt is a durable event and takes the append path.
        try await deliver(#"{"kind":"event","sessionId":"session-stream","seq":4,"time":100,"event":{"type":"user/message","text":"hi","source":"user"}}"#)
        XCTAssertEqual(store.events[session.id]?.count, 1)

        // Four chunks of ONE step, all at the turn watermark `seq` 5, exactly as
        // the gateway forwards them from `agent/assistant-stream`. Measured
        // against a real qualification host: 195 live chunks shared one seq, and
        // the finalizing `assistant/message` carried that same seq.
        //
        // This mirror keeps one record per durable seq and each stream patch
        // carries the new fragment, so the mirror holds the newest delta — that is
        // the platform contract. The visible accumulated text lives in the
        // projected row below; the retained journal is deliberately NOT a stream
        // log and is asserted as such in `SharedHistoryStoreTest`.
        for fragment in ["Hel", "lo", " there", "!"] {
            try await deliver(
                #"{"kind":"event","sessionId":"session-stream","seq":5,"time":101,"event":{"type":"assistant/chunk","turn":1,"step":1,"chunkType":"text-delta","text":"\#(fragment)"}}"#
            )
            XCTAssertEqual(store.events[session.id]?.last?.event.text, fragment)
            XCTAssertNil(store.lastError)
        }
        XCTAssertEqual(store.events[session.id]?.count, 2)

        // The streaming row accumulated every fragment rather than rebuilding
        // from the last one.
        await store.awaitConversationProjectionForTesting(
            sessionID: session.id,
            expectedText: "Hello there!"
        )
        XCTAssertEqual(
            store.renderedConversationItems[session.id]?.last?.text,
            "Hello there!"
        )

        // The authoritative finalization arrives at the SAME durable seq as its
        // chunks on a real host (measured: max chunk seq 17 = final seq 17). That
        // is exactly the record `receiveEvent` refuses as not strictly newer, so
        // the same-seq route must carry it and apply the authoritative text.
        try await deliver(#"{"kind":"event","sessionId":"session-stream","seq":5,"time":102,"event":{"type":"assistant/message","turn":1,"step":1,"text":"Hello there! (final)"}}"#)
        await store.awaitConversationProjectionForTesting(
            sessionID: session.id,
            expectedText: "Hello there! (final)"
        )
        let finalized = try XCTUnwrap(store.renderedConversationItems[session.id]?.last)
        XCTAssertEqual(finalized.text, "Hello there! (final)")
        XCTAssertEqual(finalized.title, "DeepSeek")
        XCTAssertEqual(store.events[session.id]?.last?.event.text, "Hello there! (final)")

        // The rebuild-vs-fold distinction is asserted where it is observable:
        // `SharedHistoryStoreTest` pins the patch kind and the stream-delta marker
        // that select the row-local lane, and this test pins the projected text
        // through the real `AppStore` path.
    }

    /// `reasoning-delta` and `tool-call-delta` share the same turn watermark, so
    /// they must take the same row-local route and merge into their own rows.
    @MainActor
    func testSameSequenceReasoningAndToolCallDeltasAccumulateRowLocally() async throws {
        let session = SessionSummary(
            id: "session-stream-2",
            title: "Stream 2",
            lastActivity: Date(timeIntervalSince1970: 100),
            isRunning: true,
            hasUnread: false
        )
        let store = AppStore(preferences: AppPreferencesSpy(
            endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil,
            sessions: [session]
        ))
        let prepared = await store.prepareConversation(for: session)
        XCTAssertTrue(prepared)

        func deliver(_ json: String) async throws {
            store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(json.utf8)))
            await flushDeferredKMPEvents(in: store)
        }

        var reasoningText = ""
        for fragment in ["Let me ", "think ", "about it"] {
            reasoningText += fragment
            try await deliver(
                #"{"kind":"event","sessionId":"session-stream-2","seq":7,"time":101,"event":{"type":"assistant/chunk","turn":1,"step":1,"chunkType":"reasoning-delta","text":"\#(fragment)"}}"#
            )
            XCTAssertEqual(store.events[session.id]?.last?.event.text, fragment)
        }
        await store.awaitConversationProjectionForTesting(
            sessionID: session.id,
            expectedText: reasoningText
        )
        let reasoningRow = try XCTUnwrap(
            store.renderedConversationItems[session.id]?.last { $0.kind == .reasoning },
            "reasoning row missing from \(store.renderedConversationItems[session.id]?.map(\.kind) ?? [])"
        )
        XCTAssertEqual(reasoningRow.text, reasoningText)

        // Real tool-argument deltas are pieces of a JSON document, so the
        // fragments themselves contain quotes. They must be JSON-escaped before
        // being spliced into the frame, or the frame stops being valid JSON.
        var arguments = ""
        for fragment in ["{\"path\"", ":\"a.txt\"", "}"] {
            arguments += fragment
            let escaped = fragment
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            try await deliver(
                #"{"kind":"event","sessionId":"session-stream-2","seq":8,"time":102,"event":{"type":"assistant/chunk","turn":1,"step":1,"chunkType":"tool-call-delta","tool":{"id":"call-1","name":"read_file","argumentsDelta":"\#(escaped)"}}}"#
            )
        }
        await store.awaitConversationProjectionForTesting(
            sessionID: session.id,
            expectedText: arguments
        )
        // A plain tool name projects as a tool row (`run_code` would be a
        // `jsonTool` row by design).
        let toolRow = try XCTUnwrap(
            store.renderedConversationItems[session.id]?.last { $0.kind == .tool },
            "tool row missing from \(store.renderedConversationItems[session.id]?.map(\.kind) ?? [])"
        )
        XCTAssertEqual(toolRow.text, arguments)

    }

    @MainActor
    func testKMPConversationAdapterConsumesIncrementalPushEvents() throws {
        let adapter = KMPConversationStoreAdapter()
        var publishedTexts: [[String]] = []
        adapter.onChange = { change in
            publishedTexts.append(change.items.map(\.text))
        }

        try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(
                type: "assistant/chunk", turn: 1, step: 1,
                text: "Hel", chunkType: "text-delta"
            )
        ))
        try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 2, time: 2,
            event: GatewayEvent(
                type: "assistant/chunk", turn: 1, step: 1,
                text: "lo", chunkType: "text-delta"
            )
        ))

        XCTAssertTrue(adapter.isOperational)
        XCTAssertEqual(adapter.items(for: "s1").map(\.text), ["Hello"])
        XCTAssertEqual(publishedTexts, [["Hel"], ["Hello"]])
        let streamingItemID = try XCTUnwrap(adapter.items(for: "s1").first?.id)

        try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 3, time: 3,
            event: GatewayEvent(
                type: "assistant/message", turn: 1, step: 1,
                text: "Hello!"
            )
        ))
        XCTAssertEqual(adapter.items(for: "s1").first?.id, streamingItemID)
        XCTAssertEqual(adapter.items(for: "s1").first?.text, "Hello!")
        XCTAssertEqual(adapter.items(for: "s1").first?.title, "DeepSeek")
        try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 4, time: 4,
            event: GatewayEvent(
                type: "assistant/chunk", turn: 2, step: 1,
                text: "第二轮正在", chunkType: "text-delta"
            )
        ))
        XCTAssertEqual(adapter.items(for: "s1").last?.text, "第二轮正在")
        XCTAssertEqual(adapter.items(for: "s1").last?.title, L10n.streamingAssistantTitle)

        let baseline = [
            SessionEvent(
                sessionId: "s1", seq: 5, time: 5,
                event: GatewayEvent(type: "user/message", text: "新基线", source: "user")
            )
        ]
        try adapter.replace(sessionID: "s1", events: baseline)
        XCTAssertEqual(adapter.items(for: "s1").map(\.text), ["新基线"])

        try adapter.clear(sessionID: "s1")
        XCTAssertTrue(adapter.items(for: "s1").isEmpty)
    }

    @MainActor
    func testSteeringBubblePromotesToDurableUserMessageWithoutDuplicate() throws {
        let adapter = KMPConversationStoreAdapter()
        let rows = try JSONDecoder().decode([JSONValue].self, from: Data("""
        [{"id":"q","placement":"steering","message":{"id":"m","content":[{"type":"text","text":"Go"}]}}]
        """.utf8))
        try adapter.replaceSteeringMessages(sessionID: "s", items: rows)
        let pending = try XCTUnwrap(adapter.items(for: "s").first)
        XCTAssertEqual(pending.kind, .user)
        XCTAssertEqual(pending.text, "Go")
        try adapter.receive(SessionEvent(sessionId: "s", seq: 1, time: 100,
            event: GatewayEvent(type: "user/message", text: "Go", raw: .object(["id": .string("m")]))))
        try adapter.replaceSteeringMessages(sessionID: "s", items: rows)
        try adapter.replaceSteeringMessages(sessionID: "s", items: [])
        XCTAssertEqual(adapter.items(for: "s").map(\.id), [pending.id])
        XCTAssertTrue(adapter.isOperational)
    }

    @MainActor
    func testKMPConversationAdapterFailsClosedBeforeMalformedPatchPublishes() {
        let bridge = MalformedConversationEventBridge()
        let adapter = KMPConversationStoreAdapter(bridge: bridge)
        var publishCount = 0
        adapter.onChange = { _ in publishCount += 1 }

        XCTAssertThrowsError(try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(
                type: "assistant/chunk", turn: 1, step: 1,
                text: "x", chunkType: "text-delta"
            )
        )))
        XCTAssertFalse(adapter.isOperational)
        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(adapter.items(for: "s1").isEmpty)
        XCTAssertEqual(bridge.receiveCallCount, 1)

        XCTAssertThrowsError(try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 2, time: 2,
            event: GatewayEvent(type: "user/message", text: "不会进入 KMP", source: "user")
        )))
        XCTAssertEqual(bridge.receiveCallCount, 1)
    }

    @MainActor
    func testKMPConversationProjectionProducesExpectedPlatformItems() throws {
        let image = GatewayImageAttachment(
            attachmentId: "image-1", mediaType: "image/png", bytes: 4,
            width: 1, height: 1, name: "pixel.png"
        )
        let records = [
            SessionEvent(sessionId: "s1", seq: 1, time: 1, event: GatewayEvent(
                type: "user/message", text: "上下文", source: "plugin",
                raw: .object(["source": .object(["plugin": .string("skill")])])
            )),
            SessionEvent(sessionId: "s1", seq: 2, time: 2, event: GatewayEvent(
                type: "user/message", text: "看图", source: "user", images: [image]
            )),
            SessionEvent(sessionId: "s1", seq: 3, time: 3, event: GatewayEvent(
                type: "assistant/chunk", turn: 1, step: 1,
                text: "临时", chunkType: "text-delta"
            )),
            SessionEvent(sessionId: "s1", seq: 4, time: 4, event: GatewayEvent(
                type: "assistant/message", turn: 1, step: 1,
                text: "完成", reasoning: "思考"
            )),
            SessionEvent(sessionId: "s1", seq: 5, time: 5, event: GatewayEvent(
                type: "tool/call", callId: "call-1", name: "Read",
                arguments: .object(["path": .string("README.md")])
            )),
            SessionEvent(sessionId: "s1", seq: 6, time: 6, event: GatewayEvent(
                type: "tool/result", callId: "call-1", isError: false, preview: "内容"
            ))
        ]
        let adapter = KMPConversationStoreAdapter()

        try adapter.replace(sessionID: "s1", events: records)
        let kmp = adapter.items(for: "s1")

        XCTAssertEqual(kmp.map(\.id), [
            records[0].id,
            records[1].id,
            records[3].id + "-reason",
            records[3].id,
            records[4].id,
            records[5].id
        ])
        XCTAssertEqual(kmp.map(\.kind), [.context, .user, .reasoning, .assistant, .tool, .toolResult])
        XCTAssertEqual(kmp.map(\.title), [
            L10n.contextInjectionTitle("skill"),
            L10n.userMessageTitle,
            "Think",
            "DeepSeek",
            "Read",
            L10n.toolResultDoneTitle
        ])
        XCTAssertEqual(kmp.filter { $0.kind != .tool }.map(\.text), [
            "上下文", "看图", "思考", "完成", "内容"
        ])
        XCTAssertTrue(kmp.first(where: { $0.kind == .tool })?.text.contains("README.md") == true)
        XCTAssertEqual(kmp.map(\.images), [[], [image], [], [], [], []])
        XCTAssertEqual(kmp.map(\.isError), [false, false, false, false, false, false])
        XCTAssertEqual(kmp.map(\.date), [
            records[0].date,
            records[1].date,
            records[3].date,
            records[3].date,
            records[4].date,
            records[5].date
        ])
    }

    @MainActor
    func testKMPTrajectoryAdapterProjectsNodesAndTokenUsage() throws {
        let usage: JSONValue = .object([
            "inputTokens": .number(10),
            "cacheReadTokens": .number(4),
            "outputTokens": .number(8),
            "reasoningTokens": .number(3)
        ])
        let records = [
            SessionEvent(
                sessionId: "s1", seq: 1, time: 1,
                event: GatewayEvent(type: "user/message", text: "执行", source: "user")
            ),
            SessionEvent(
                sessionId: "s1", seq: 2, time: 2,
                event: GatewayEvent(
                    type: "assistant/message", turn: 1, step: 1,
                    text: "完成", usage: usage
                )
            ),
            SessionEvent(
                sessionId: "s1", seq: 3, time: 3,
                event: GatewayEvent(
                    type: "tool/call", turn: 1, step: 1,
                    callId: "c1", name: "Read"
                )
            )
        ]
        let adapter = KMPTrajectoryStoreAdapter()
        var changes: [KMPTrajectoryChange] = []
        adapter.onChange = { changes.append($0) }

        try adapter.replace(sessionID: "s1", events: records)
        let kmp = adapter.nodes(for: "s1")

        XCTAssertFalse(
            kmp.isEmpty,
            "KMP Trajectory 为空：error=\(String(describing: adapter.runtimeError)), changes=\(changes.map { ($0.sessionID, $0.nodes.count) })"
        )
        XCTAssertEqual(kmp.map(\.kind), [.input, .request, .assistant, .tool])
        XCTAssertEqual(kmp.first?.subtitle, "执行")
        XCTAssertEqual(kmp.first(where: { $0.kind == .assistant })?.subtitle, "完成")
        let request = try XCTUnwrap(kmp.first(where: { $0.kind == .request })?.request)
        XCTAssertEqual(request.usage.uncachedInput, 10)
        XCTAssertEqual(request.usage.cachedInput, 4)
        XCTAssertEqual(request.usage.output, 8)
        XCTAssertEqual(request.usage.reasoning, 3)
        XCTAssertEqual(request.usage.content, 5)
    }

    @MainActor
    func testKMPTrajectoryAdapterFailsClosedBeforeMalformedUpdatePublishes() {
        let bridge = MalformedTrajectoryEventBridge()
        let adapter = KMPTrajectoryStoreAdapter(bridge: bridge)
        var publishCount = 0
        adapter.onChange = { _ in publishCount += 1 }

        XCTAssertThrowsError(try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(
                type: "assistant/chunk", turn: 1, step: 1,
                text: "x", chunkType: "text-delta"
            )
        )))
        XCTAssertFalse(adapter.isOperational)
        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(adapter.nodes(for: "s1").isEmpty)
    }

    @MainActor
    func testAppStoreActivatesTrajectoryProjectionOnlyForVisiblePage() async {
        let bridge = CountingTrajectoryBridge()
        let store = AppStore(preferences: AppPreferencesSpy(
            endpoint: "ws://127.0.0.1:3080/ws/mobile",
            selectedWorkspaceID: nil,
            sessions: []
        ), trajectoryBridge: bridge)
        store.events["s1"] = [
            SessionEvent(
                sessionId: "s1", seq: 1, time: 1,
                event: GatewayEvent(type: "user/message", text: "one", source: "user")
            )
        ]
        let timeline = store.trajectoryTimeline(for: "s1")
        XCTAssertTrue(timeline.nodes.isEmpty)

        store.setTrajectoryProjectionActive(sessionID: "s1", isActive: true)
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(timeline.nodes.map(\.subtitle), ["one"])
        XCTAssertEqual(bridge.replaceCount, 1)

        store.setTrajectoryProjectionActive(sessionID: "s1", isActive: false)
        store.setTrajectoryProjectionActive(sessionID: "s1", isActive: true)
        XCTAssertEqual(bridge.replaceCount, 1)
        store.setTrajectoryProjectionActive(sessionID: "s1", isActive: false)
        store.events["s1"]?.append(SessionEvent(
            sessionId: "s1", seq: 2, time: 2,
            event: GatewayEvent(type: "user/message", text: "two", source: "user")
        ))
        XCTAssertEqual(timeline.nodes.map(\.subtitle), ["one"])
        store.setTrajectoryProjectionActive(sessionID: "s1", isActive: true)
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(timeline.nodes.map(\.subtitle), ["one", "two"])
        XCTAssertEqual(bridge.replaceCount, 2)
    }

    @MainActor
    func testPreparedHistoryPageFactoryThrowsSwiftErrorsWithoutNativeTermination() throws {
        XCTAssertThrowsError(try SharedPreparedHistoryPage.companion.parse(sessionId: "s1", eventsJson: "{"))
        XCTAssertThrowsError(try SharedPreparedHistoryPage.companion.parse(sessionId: "s1", eventsJson:
            #"[{"sessionId":"other","seq":1,"time":1,"event":{"type":"user/message","text":"wrong"}}]"#))
        let input = SessionEvent(sessionId: "s1", seq: 1, time: 1, event: GatewayEvent(type: "user/message", text: "one"))
        let prepared = try KMPHistoryStoreAdapter.preparePage(sessionID: "s1", events: [input])
        let adapter = KMPHistoryStoreAdapter()
        var published = 0
        adapter.onChange = { _ in published += 1 }
        XCTAssertThrowsError(try adapter.pageReceived(sessionID: "other", preparedPage: prepared, byteCount: 1,
            hasMore: false, nextBeforeSequence: nil, remoteActivityTimestamp: nil))
        XCTAssertEqual(published, 0)
        XCTAssertTrue(adapter.events(for: "other").isEmpty)
        XCTAssertThrowsError(try KMPHistoryStoreAdapter.preparePage(sessionID: "other", events: [input]))
    }

    @MainActor
    func testPreparedHistoryPageKeepsLivePriorityAfterPureBackgroundParsing() async throws {
        let adapter = KMPHistoryStoreAdapter()
        try adapter.start(sessionID: "s1", older: false, hasLocalEvents: false, earliestLocalSequence: nil)
        let incoming = [
            SessionEvent(sessionId: "s1", seq: 1, time: 1, event: GatewayEvent(type: "user/message", text: "history")),
            SessionEvent(sessionId: "s1", seq: 2, time: 2, event: GatewayEvent(type: "assistant/message", text: "stale"))
        ]
        let page = try await Task.detached { try KMPHistoryStoreAdapter.preparePage(sessionID: "s1", events: incoming) }.value
        XCTAssertTrue(adapter.events(for: "s1").isEmpty, "pure parse must not touch the live owner")
        try adapter.receive(SessionEvent(sessionId: "s1", seq: 2, time: 3,
            event: GatewayEvent(type: "assistant/message", text: "live")))
        try adapter.pageReceived(sessionID: "s1", preparedPage: page, byteCount: 10,
            hasMore: false, nextBeforeSequence: nil, remoteActivityTimestamp: 3)
        XCTAssertEqual(adapter.events(for: "s1").map(\.seq), [1, 2])
        XCTAssertEqual(adapter.events(for: "s1").map(\.event.text), ["history", "live"])
        XCTAssertTrue(adapter.isOperational)
    }

    @MainActor
    func testKMPHistoryReferencePatchesRejectInvalidCommandsBeforePublishing() throws {
        let incoming = SessionEvent(sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(type: "user/message", text: "incoming"))
        let validReference: [String: Any] = ["source": "incoming", "index": 0, "sequence": 1]
        let malformed: [[String: Any]] = [
            ["kind": "replace", "replacementReferences": [["source": "other", "index": 0, "sequence": 1]], "referenceBaseEventSequence": 0],
            ["kind": "replace", "replacementReferences": [["source": "incoming", "index": -1, "sequence": 1]], "referenceBaseEventSequence": 0],
            ["kind": "replace", "replacementReferences": [["source": "retained", "index": -1, "sequence": 1]], "referenceBaseEventSequence": 0],
            ["kind": "replace", "replacementReferences": [["source": "incoming", "index": 1, "sequence": 1]], "referenceBaseEventSequence": 0],
            ["kind": "replace", "replacementReferences": [["source": "incoming", "index": 0, "sequence": 2]], "referenceBaseEventSequence": 0],
            ["kind": "replace", "replacementReferences": [validReference, validReference], "referenceBaseEventSequence": 0],
            ["kind": "replace", "replacementReferences": [["source": "retained", "index": 999, "sequence": 0],
                ["source": "other", "index": 0, "sequence": 1]], "referenceBaseEventSequence": 0],
            ["kind": "replace", "replacementReferences": [validReference], "referenceBaseEventSequence": 99],
            ["kind": "replace", "replacementReferences": [validReference], "referenceBaseEventSequence": 0, "replacementEvents": []],
            ["kind": "append", "replacementReferences": [validReference], "referenceBaseEventSequence": 0]
        ]
        for eventPatch in malformed {
            let payload: [String: Any] = ["schema": 1, "sessionId": "s1", "pendingSessionChanged": false,
                "eventPatch": eventPatch, "outcome": "none"]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let adapter = KMPHistoryStoreAdapter(bridge: MalformedHistoryEventBridge(payload: json))
            var changes = 0
            adapter.onChange = { _ in changes += 1 }
            XCTAssertThrowsError(try adapter.pageReceived(sessionID: "s1", events: [incoming], byteCount: 1,
                hasMore: false, nextBeforeSequence: nil, remoteActivityTimestamp: nil), json)
            XCTAssertEqual(changes, 0, json)
            XCTAssertTrue(adapter.events(for: "s1").isEmpty, json)
            XCTAssertNotNil(adapter.runtimeError, json)
        }
    }

    @MainActor
    func testKMPHistorySnapshotsKeepExactContentAfterLaterLiveAndClear() throws {
        let history = KMPHistoryStoreAdapter()
        var firstSnapshot: SharedHistoryProjectionSnapshot?
        history.onChange = { change in
            if firstSnapshot == nil { firstSnapshot = change.projectionSnapshot }
        }
        try history.receive(SessionEvent(sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(type: "user/message", text: "original")))
        let captured = try XCTUnwrap(firstSnapshot)
        try history.receive(SessionEvent(sessionId: "s1", seq: 1, time: 2,
            event: GatewayEvent(type: "user/message", text: "newer")))
        try history.clear(sessionID: "s1")
        XCTAssertNil(history.projectionSnapshot(for: "s1"))
        let original = try JSONDecoder().decode([SessionEvent].self, from: Data(captured.eventsJson().utf8))
        let conversation = KMPConversationStoreAdapter()
        try conversation.replace(sessionID: "s1", events: original, historySnapshot: captured)
        XCTAssertEqual(conversation.items(for: "s1").map(\.text), ["original"])
        XCTAssertEqual(conversation.lastSequenceBySessionID["s1"], 1)
        XCTAssertTrue(history.events(for: "s1").isEmpty)
    }

    @MainActor
    func testKMPHistoryAdapterOwnsPaginationWatermarkAndLiveTailMerge() throws {
        let adapter = KMPHistoryStoreAdapter()
        var changes: [KMPHistoryChange] = []
        adapter.onChange = { changes.append($0) }

        try adapter.start(
            sessionID: "s1",
            older: false,
            hasLocalEvents: false,
            earliestLocalSequence: nil
        )
        XCTAssertEqual(changes.last?.effect, KMPHistoryEffect(action: "request-page", sessionId: "s1", beforeSequence: nil))
        XCTAssertTrue(changes.last?.loadingSessionIDs.contains("s1") == true)

        try adapter.processingStarted(sessionID: "s1", rawEventCount: 2, hasMore: false)
        let live = SessionEvent(
            sessionId: "s1", seq: 2, time: 2,
            event: GatewayEvent(type: "assistant/message", text: "live-final")
        )
        try adapter.receive(live)
        try adapter.pageReceived(
            sessionID: "s1",
            events: [
                SessionEvent(
                    sessionId: "s1", seq: 1, time: 1,
                    event: GatewayEvent(type: "user/message", text: "history")
                ),
                SessionEvent(
                    sessionId: "s1", seq: 2, time: 2,
                    event: GatewayEvent(type: "assistant/message", text: "stale-history")
                )
            ],
            byteCount: 32,
            hasMore: false,
            nextBeforeSequence: nil,
            remoteActivityTimestamp: 2
        )

        XCTAssertEqual(adapter.events(for: "s1").map(\.seq), [1, 2])
        XCTAssertEqual(adapter.events(for: "s1").last?.event.text, "live-final")
        XCTAssertEqual(adapter.syncedActivityTimestamp(for: "s1"), 2)
        XCTAssertEqual(changes.last?.outcome, "completed")
        XCTAssertEqual(changes.last?.completedEventCount, 2)
        XCTAssertFalse(changes.last?.loadingSessionIDs.contains("s1") == true)
    }

    @MainActor
    func testKMPHistoryAdapterFailsClosedBeforeMalformedEventPatchPublishes() {
        let adapter = KMPHistoryStoreAdapter(bridge: MalformedHistoryEventBridge())
        var publishCount = 0
        adapter.onChange = { _ in publishCount += 1 }

        XCTAssertThrowsError(try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(type: "assistant/message", text: "one")
        )))
        XCTAssertFalse(adapter.isOperational)
        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(adapter.events(for: "s1").isEmpty)
    }

    /// The additive marker, exercised through the real shared store. The wire
    /// `kind` stays `upsert` so a consumer that does not know the marker keeps its
    /// existing handling; only the marker selects the row-local lane, and its
    /// absence keeps ordinary upsert semantics.
    @MainActor
    func testHistoryAdapterPublishesStreamDeltaMarkerOnlyForCompatibleRepeats() throws {
        let adapter = KMPHistoryStoreAdapter()
        var changes: [KMPHistoryChange] = []
        adapter.onChange = { changes.append($0) }

        func chunk(_ seq: Int, _ text: String, turn: Int = 1, step: Int = 1) -> SessionEvent {
            SessionEvent(
                sessionId: "s1", seq: seq, time: Double(seq),
                event: GatewayEvent(
                    type: "assistant/chunk", turn: turn, step: step,
                    text: text, chunkType: "text-delta"
                )
            )
        }

        // The first chunk of a step is a plain append and carries no marker.
        try adapter.receive(chunk(5, "Hel"))
        XCTAssertEqual(changes.last?.eventPatchKind, "append")
        XCTAssertEqual(changes.last?.eventPatchIsStreamDelta, false)

        // A repeat at the same watermark is an upsert WITH the marker, and the
        // mirror keeps the raw fragment it was handed.
        try adapter.receive(chunk(5, "lo"))
        XCTAssertEqual(changes.last?.eventPatchKind, "upsert", "the wire kind must stay truthful")
        XCTAssertEqual(changes.last?.eventPatchIsStreamDelta, true)
        XCTAssertEqual(adapter.events(for: "s1").last?.event.text, "lo")

        // A chunk-type transition inside one step is still the same live row;
        // `chunkType` must not be part of the predicate.
        try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 5, time: 6,
            event: GatewayEvent(type: "assistant/chunk", turn: 1, step: 1, chunkType: "usage")
        ))
        XCTAssertEqual(changes.last?.eventPatchIsStreamDelta, true)

        // The authoritative finalization at the same seq is an upsert whose
        // marker is absent, so the ordinary upsert semantics apply and the
        // authoritative record is what the mirror retains.
        try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 5, time: 7,
            event: GatewayEvent(type: "assistant/message", text: "Hello")
        ))
        XCTAssertEqual(changes.last?.eventPatchKind, "upsert")
        XCTAssertEqual(changes.last?.eventPatchIsStreamDelta, false)
        XCTAssertEqual(adapter.events(for: "s1").last?.event.text, "Hello")

        // A chunk from another step is not a continuation.
        try adapter.receive(chunk(5, "other", step: 2))
        XCTAssertEqual(changes.last?.eventPatchIsStreamDelta, false)
        XCTAssertEqual(adapter.events(for: "s1").last?.event.text, "other")
    }

    /// A live-delta marker is only meaningful on a same-sequence upsert. Any other
    /// combination is a producer defect and must fail closed before the mirror or
    /// any conversation state is published.
    @MainActor
    func testHistoryAdapterFailsClosedOnStreamMarkerWithNonUpsertKind() {
        let adapter = KMPHistoryStoreAdapter(bridge: MalformedHistoryEventBridge(
            payload: #"{"schema":1,"sessionId":"s1","session":null,"pendingSessionId":null,"pendingSessionChanged":false,"eventPatch":{"kind":"append","record":{"sessionId":"s1","seq":1,"time":1,"event":{"type":"assistant/chunk","turn":1,"step":1,"chunkType":"text-delta","text":"x"}},"index":0,"replacementEvents":null,"streamDelta":true},"outcome":"none","failureCode":null,"completedEventCount":null,"completedByteCount":null,"completedHasMore":null}"#
        ))
        var publishCount = 0
        adapter.onChange = { _ in publishCount += 1 }

        XCTAssertThrowsError(try adapter.receive(SessionEvent(
            sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(type: "assistant/chunk", turn: 1, step: 1, text: "x", chunkType: "text-delta")
        )))
        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(adapter.events(for: "s1").isEmpty)
    }

    func testStage9WriteAuditRecognizesDirectNestedInoutAndCollectionMutations() throws {
        let defects: [(property: String, source: String)] = [
            ("sessions", "sessions = replacement"),
            ("sessions", "sessions += replacement"),
            ("sessions", "sessions.append(candidate)"),
            ("sessions", "sessions.popLast()"),
            ("sessions", "sessions[0].title = replacement"),
            ("modelCatalogs", "modelCatalogs[id]?.current = selection"),
            ("modelCatalogs", "modelCatalogs[id]?.groups[0].models[0].name = replacement"),
            ("modelCatalogs", "modelCatalogs.removeValue(forKey: id)"),
            ("pendingQuestionRequests", "pendingQuestionRequests.swapAt(0, 1)"),
            ("questionRequestStatuses", "consume(&questionRequestStatuses)"),
            ("sessions", "consume(&sessions[0])"),
            ("sessions", "mutate(&sessions[0].title)"),
            ("modelCatalogs", "mutate(&self.modelCatalogs[id]!.groups[0])"),
            ("pendingModelsSessionId", "pendingModelsSessionId = rogueSession"),
            ("isPendingGlobalModelsRequest", "isPendingGlobalModelsRequest = true"),
            ("pendingModelSelectionSessionId", "pendingModelSelectionSessionId = rogueSession"),
            ("pendingPermissionOptionsSessionId", "pendingPermissionOptionsSessionId = rogueSession")
        ]
        for defect in defects {
            XCTAssertFalse(
                try stage9WriteMatches(for: defect.property, in: defect.source).isEmpty,
                "静态写边界门禁必须识别：\(defect.source)"
            )
        }
        XCTAssertTrue(
            try stage9WriteMatches(for: "sessions", in: "let count = sessions.count").isEmpty,
            "只读属性访问不得被误判为写入"
        )
    }

    func testStage9WriteScannerDistinguishesReadsBooleanOperatorsAndWrites() throws {
        for read in [
            "sessions == other",
            "sessions[index].isRunning == false",
            "ready && sessions.first(where: { $0.id == id })?.isRunning == false",
            "ready&&sessions.isEmpty",
            "self.sessions[index] != nil"
        ] {
            XCTAssertTrue(try stage9WriteMatches(for: "sessions", in: read).isEmpty, read)
        }
        for write in [
            "sessions = []",
            "self.sessions[index].isRunning = false",
            "sessions += incoming",
            "sessions[index] &= mask",
            "sessions.append(item)",
            "mutate(&sessions)",
            "mutate(&self.sessions[index])"
        ] {
            XCTAssertFalse(try stage9WriteMatches(for: "sessions", in: write).isEmpty, write)
        }
    }

    func testStage11ProductSourcesContainNoParallelBasicDomainImplementation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productRoot = repositoryRoot.appendingPathComponent("DeepSeekHarnessMobile")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: productRoot,
                includingPropertiesForKeys: nil
            )
        )
        let sourceURLs = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
        XCTAssertFalse(sourceURLs.isEmpty)

        for removedFile in [
            "Core/SessionListReducer.swift",
            "Core/QuestionReducer.swift",
            "Core/SessionControlReducer.swift",
            "Core/HistoryReducer.swift"
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: productRoot.appendingPathComponent(removedFile).path),
                "阶段 11 不得恢复已由 KMP 取代的 Swift 文件：\(removedFile)"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: productRoot.appendingPathComponent("Core/KMPDomainIntents.swift").path
            ),
            "平台输入 DTO 必须与 Swift Reducer 解耦"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent(
                    "shared/src/commonMain/kotlin/com/clarklevis/dsh/shared/facade/SharedShadowFacade.kt"
                ).path
            ),
            "阶段 11 必须删除迁移期只读影子 Facade"
        )

        for reducerSymbol in [
            "SessionListReducer",
            "QuestionReducer",
            "SessionControlReducer",
            "QuestionState",
            "SessionControlState",
            "SessionListState"
        ] {
            let referencePattern = try NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: reducerSymbol))\\b"
            )
            for sourceURL in sourceURLs {
                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                let fullRange = NSRange(source.startIndex..., in: source)
                XCTAssertNil(
                    referencePattern.firstMatch(in: source, range: fullRange),
                    "阶段 11 已删除 Swift 平行领域实现，产品 Swift 源不得引用 \(reducerSymbol)：\(sourceURL.path)"
                )
            }
        }

        let identifierPattern = try NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*\\b")
        let rollbackTerms = ["use", "enable", "disable", "prefer", "force", "flag", "fallback", "rollback", "legacy"]
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let fullRange = NSRange(source.startIndex..., in: source)
            let suspiciousIdentifiers = identifierPattern.matches(in: source, range: fullRange).compactMap { match -> String? in
                guard let range = Range(match.range, in: source) else { return nil }
                let identifier = String(source[range])
                let normalized = identifier.lowercased()
                guard normalized.contains("kmp") || normalized.contains("swift") else { return nil }
                return rollbackTerms.contains(where: normalized.contains) ? identifier : nil
            }
            XCTAssertTrue(
                suspiciousIdentifiers.isEmpty,
                "阶段 9 人工验收后不得引入疑似 KMP/Swift 运行时切换标识符：\(sourceURL.path) \(suspiciousIdentifiers)"
            )
        }

        let appStoreSource = try String(
            contentsOf: productRoot.appendingPathComponent("Core/AppStore.swift"),
            encoding: .utf8
        )
        for requiredKMPWritePath in [
            "kmpSessionListStore.reduce",
            "kmpQuestionStore.reduce",
            "kmpSessionControlStore.reduce"
        ] {
            XCTAssertTrue(
                appStoreSource.contains(requiredKMPWritePath),
                "AppStore 必须继续通过 KMP 提交基础领域状态：\(requiredKMPWritePath)"
            )
        }

        let appStoreNSString = appStoreSource as NSString
        let allowedAssignmentScopes = try Dictionary(
            uniqueKeysWithValues: ["initialization", "session-list", "question", "session-control"].map { name in
                (
                    name,
                    try swiftAuditRange(
                        from: "// stage9-kmp-write-scope: \(name)-begin",
                        through: "// stage9-kmp-write-scope: \(name)-end",
                        in: appStoreNSString
                    )
                )
            }
        )
        let migratedProperties: [String: Set<String>] = [
            "selectedSessionId": ["initialization", "session-list"],
            "sessions": ["initialization", "session-list"],
            "archivedSessionIds": ["initialization", "session-list"],
            "pendingQuestionRequests": ["initialization", "question"],
            "questionRequestStatuses": ["initialization", "question"],
            "modelCatalogs": ["session-control"],
            "globalModelCatalog": ["session-control"],
            "sessionPermissions": ["session-control"],
            "contextSnapshots": ["session-control"],
            "sessionStatsSnapshots": ["session-control"],
            "sessionControlLoadingKinds": ["session-control"],
            "agentPresets": ["session-control"],
            "agentPresetsAuthorable": ["session-control"],
            "agentPresetsHasDocument": ["session-control"],
            "agentPresetDefault": ["session-control"],
            "permissionDefault": ["session-control"],
            "defaultModelSelection": ["session-control"],
            "defaultConfigurationLoadingKinds": ["session-control"],
            "pendingModelsSessionId": ["session-control"],
            "isPendingGlobalModelsRequest": ["session-control"],
            "pendingModelSelectionSessionId": ["session-control"],
            "pendingPermissionOptionsSessionId": ["session-control"]
        ]
        let privateRoutingProperties: Set<String> = [
            "pendingModelsSessionId",
            "isPendingGlobalModelsRequest",
            "pendingModelSelectionSessionId",
            "pendingPermissionOptionsSessionId"
        ]
        for (property, allowedScopes) in migratedProperties {
            if privateRoutingProperties.contains(property) {
                XCTAssertTrue(
                    appStoreSource.contains("private var \(property)"),
                    "已迁移 SessionControl 路由字段必须保持私有：\(property)"
                )
            } else {
                XCTAssertTrue(
                    appStoreSource.contains("@Published private(set) var \(property)"),
                    "已迁移 snapshot 属性必须使用 private(set) 限制外部写入：\(property)"
                )
            }
            let writeMatches = try stage9WriteMatches(for: property, in: appStoreSource)
            for match in writeMatches {
                let lineRange = appStoreNSString.lineRange(for: match.range)
                let line = appStoreNSString.substring(with: lineRange)
                if line.contains("@Published private(set) var \(property)")
                    || line.contains("private var \(property)") {
                    continue
                }
                let enclosingScopes = allowedAssignmentScopes.compactMap { name, range in
                    NSLocationInRange(match.range.location, range) ? name : nil
                }
                XCTAssertTrue(
                    enclosingScopes.contains(where: allowedScopes.contains),
                    "\(property) 只能在初始化或指定 KMP snapshot 发布函数写入，实际位置：\(line.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
        }
    }

    func testStage11ProductBasicDomainsUseIntentDispatchAndEventSubscription() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appStoreSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DeepSeekHarnessMobile/Core/AppStore.swift"),
            encoding: .utf8
        )
        let adapterSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DeepSeekHarnessMobile/Core/KMPSharedAdapter.swift"),
            encoding: .utf8
        )
        for callback in [
            "kmpSessionListStore.onSnapshot",
            "kmpQuestionStore.onTransition",
            "kmpSessionControlStore.onTransition"
        ] {
            XCTAssertTrue(appStoreSource.contains(callback), "产品必须订阅 KMP Event：\(callback)")
        }
        for subscription in [
            "extension SharedSessionListStore: KMPSessionListEventBridging",
            "extension SharedQuestionStore: KMPQuestionEventBridging",
            "extension SharedSessionControlStore: KMPSessionControlEventBridging"
        ] {
            XCTAssertTrue(adapterSource.contains(subscription), "Adapter 必须接入可取消订阅：\(subscription)")
        }
        for forbidden in [
            "applySessionControlTransition(kmpSessionControlStore.reduce",
            "applySessionControlTransition(self.kmpSessionControlStore.reduce"
        ] {
            XCTAssertFalse(
                appStoreSource.contains(forbidden),
                "产品不得从 mutation 返回值发布状态或执行 effect：\(forbidden)"
            )
        }
        XCTAssertEqual(
            appStoreSource.components(separatedBy: "executeQuestionEffect(transition.effect)").count - 1,
            1,
            "Question effect 只能在 KMP Event 订阅回调中执行一次"
        )
        XCTAssertFalse(appStoreSource.contains("KMPShadowValidator"))
        XCTAssertFalse(adapterSource.contains("SharedShadowFacade"))
    }

    func testStage11ProductSourcesContainNoParallelProjectionOrHistoryImplementation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productRoot = repositoryRoot.appendingPathComponent("DeepSeekHarnessMobile")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: productRoot,
            includingPropertiesForKeys: nil
        ))
        let productSources = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension == "swift" else { return nil }
            return url
        }
        for symbol in [
            "ConversationProjector", "ConversationHistoryRebase", "ConversationItem.fold",
            "HistoryReducer", "HistoryEventMerger"
        ] {
            for sourceURL in productSources {
                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                XCTAssertFalse(
                    source.contains(symbol),
                    "阶段 10.2 后产品 Swift 不得恢复 Conversation 领域投影：\(symbol) @ \(sourceURL.path)"
                )
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: productRoot.appendingPathComponent("Core/ConversationProjection.swift").path
            ),
            "旧 ConversationProjection 文件必须删除或收敛为纯平台 Timeline"
        )

        let appStoreSource = try String(
            contentsOf: productRoot.appendingPathComponent("Core/AppStore.swift"),
            encoding: .utf8
        )
        for required in [
            "kmpConversationStore.onChange",
            "kmpConversationStore.receive(record)",
            "kmpConversationStore.replace(sessionID:",
            "kmpTrajectoryStore.onChange",
            "kmpTrajectoryStore.receive(records)",
            "kmpTrajectoryStore.replace(sessionID:",
            "kmpHistoryStore.onChange",
            "kmpHistoryStore.receive(record)",
            "kmpHistoryStore.pageReceived("
        ] {
            XCTAssertTrue(appStoreSource.contains(required), "Conversation 产品路径缺少 KMP Intent/Event：\(required)")
        }
        XCTAssertFalse(
            appStoreSource.contains("conversationProjectors"),
            "AppStore 不得继续持有 Swift Conversation projector 状态"
        )
        let trajectoryViewSource = try String(
            contentsOf: productRoot.appendingPathComponent("Views/TrajectoryView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            trajectoryViewSource.contains("TrajectoryProjection.make("),
            "TrajectoryView 不得继续执行 Swift Trajectory 业务投影"
        )

        let appStoreNSString = appStoreSource as NSString
        let historyPublishScope = try swiftAuditRange(
            from: "// stage10-kmp-write-scope: history-begin",
            through: "// stage10-kmp-write-scope: history-end",
            in: appStoreNSString
        )
        for property in [
            "historyHasMore", "historyLoadingSessionIds",
            "historyLoadingOlderSessionIds", "historyLoadProgress"
        ] {
            XCTAssertTrue(
                appStoreSource.contains("@Published private(set) var \(property)"),
                "History UI 镜像必须对 AppStore 外部只读：\(property)"
            )
            let writes = try stage9WriteMatches(for: property, in: appStoreSource)
            XCTAssertFalse(writes.isEmpty, "History UI 镜像必须由 KMP event 发布：\(property)")
            XCTAssertTrue(
                writes.allSatisfy { NSLocationInRange($0.range.location, historyPublishScope) },
                "History UI 镜像只允许在 KMP History change 发布块内写入：\(property)"
            )
        }
    }

    func testDecodesDirectoryCreateResponse() throws {
        let data = #"{"kind":"directory-create","path":"/tmp/workspace/Sources"}"#.data(using: .utf8)!
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: data)

        XCTAssertEqual(frame.kind, "directory-create")
        XCTAssertEqual(frame.path, "/tmp/workspace/Sources")

        let context = GatewayFrameRoutingContext(
            selectedSessionID: nil,
            pendingHistorySessionID: nil,
            pendingModelsSessionID: nil,
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: nil,
            pendingPermissionOptionsSessionID: nil
        )
        guard case .workspace(.directoryCreated(let path)) =
                GatewayFrameRouter.route(frame, context: context) else {
            return XCTFail("directory-create 应路由为 workspace.directoryCreated")
        }
        XCTAssertEqual(path, "/tmp/workspace/Sources")
    }

    func testSessionMetadataFramesDoNotDependOnSelectedSession() throws {
        let context = GatewayFrameRoutingContext(
            selectedSessionID: "other",
            pendingHistorySessionID: nil,
            pendingModelsSessionID: nil,
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: nil,
            pendingPermissionOptionsSessionID: nil
        )
        for kind in ["session-title-changed", "session-renamed"] {
            let data = Data("{\"kind\":\"\(kind)\",\"sessionId\":\"s1\",\"title\":\"新名称\",\"seq\":129}".utf8)
            let frame = try GatewayWireDecoder.decode(data)
            guard case .content(.sessionTitle(let id, let title, let sequence, _)) =
                GatewayFrameRouter.route(frame, context: context) else {
                return XCTFail("名称回执及广播应路由为会话元数据")
            }
            XCTAssertEqual(id, "s1")
            XCTAssertEqual(title, "新名称")
            XCTAssertEqual(sequence, 129)
        }
        for kind in ["session-archives", "session-archived"] {
            let data = Data("{\"kind\":\"\(kind)\",\"archivedSessionIds\":[]}".utf8)
            guard case .content(.sessionArchives(let ids)) = GatewayFrameRouter.route(
                try GatewayWireDecoder.decode(data), context: context
            ) else { return XCTFail("空归档集合也必须完整应用") }
            XCTAssertTrue(ids.isEmpty)
        }
        let malformed = try GatewayWireDecoder.decode(Data(#"{"kind":"session-archives"}"#.utf8))
        guard case .ignored = GatewayFrameRouter.route(malformed, context: context) else {
            return XCTFail("缺失集合不能清空已有归档")
        }
    }

    func testGatewayFrameRouterMapsHelloAndLiveEventPayloads() throws {
        let context = GatewayFrameRoutingContext(
            selectedSessionID: "selected",
            pendingHistorySessionID: nil,
            pendingModelsSessionID: nil,
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: nil,
            pendingPermissionOptionsSessionID: nil
        )
        let hello = try GatewayWireDecoder.decode(Data(
            #"{"kind":"hello","protocol":3,"capabilities":["images"],"authenticated":true,"clients":2}"#.utf8
        ))
        guard case .connection(.hello(let payload)) = GatewayFrameRouter.route(hello, context: context) else {
            return XCTFail("hello 应路由为 connection.hello")
        }
        XCTAssertEqual(payload.protocolVersion, 3)
        XCTAssertEqual(payload.capabilities, ["images"])
        XCTAssertTrue(payload.authenticated)
        XCTAssertEqual(payload.clients, 2)

        let event = try GatewayWireDecoder.decode(Data(
            #"{"kind":"event","sessionId":"s1","seq":7,"time":1000,"event":{"type":"assistant/message","text":"done"}}"#.utf8
        ))
        guard case .content(.liveEvent(let record)) = GatewayFrameRouter.route(event, context: context) else {
            return XCTFail("event 应路由为 content.liveEvent")
        }
        XCTAssertEqual(record.sessionId, "s1")
        XCTAssertEqual(record.seq, 7)
        XCTAssertEqual(record.event.text, "done")
    }

    func testGatewayFrameRouterMapsSessionCancellationAcknowledgement() throws {
        let context = GatewayFrameRoutingContext(
            selectedSessionID: "s1",
            pendingHistorySessionID: nil,
            pendingModelsSessionID: nil,
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: nil,
            pendingPermissionOptionsSessionID: nil
        )
        let frame = try GatewayWireDecoder.decode(Data(
            #"{"kind":"session-cancelled","sessionId":"s1","accepted":true}"#.utf8
        ))

        guard case .control(.sessionCancelled(let sessionID, let accepted)) =
                GatewayFrameRouter.route(frame, context: context) else {
            return XCTFail("session-cancelled 应路由为 control.sessionCancelled")
        }
        XCTAssertEqual(sessionID, "s1")
        XCTAssertTrue(accepted)
    }

    func testGatewayFrameRouterBuildsQuestionPayloadAndRejectsMalformedRequest() throws {
        let context = GatewayFrameRoutingContext(
            selectedSessionID: nil,
            pendingHistorySessionID: nil,
            pendingModelsSessionID: nil,
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: nil,
            pendingPermissionOptionsSessionID: nil
        )
        let valid = try GatewayWireDecoder.decode(Data(
            #"{"kind":"question-requested","rpcId":"rpc-1","sessionId":"s1","replay":true,"questions":[{"id":"q1","question":"继续？"}]}"#.utf8
        ))
        guard case .question(.requested(let request, let sessionID, let preview, let replay)) =
                GatewayFrameRouter.route(valid, context: context) else {
            return XCTFail("有效问题应生成 requested action")
        }
        XCTAssertEqual(sessionID, "s1")
        XCTAssertEqual(preview, "继续？")
        XCTAssertTrue(replay)
        XCTAssertEqual(request.rpcId, "rpc-1")

        let invalid = try GatewayWireDecoder.decode(Data(
            #"{"kind":"question-requested","sessionId":"s1","questions":[]}"#.utf8
        ))
        guard case .question(.invalidRequest(let sessionID)) =
                GatewayFrameRouter.route(invalid, context: context) else {
            return XCTFail("缺少 rpcId 的问题必须显式路由为 invalidRequest")
        }
        XCTAssertEqual(sessionID, "s1")
    }

    func testScheduleCatalogSupportsStatusAndKeywordSearch() throws {
        let catalog = try GatewayWireDecoder.decode(Data(
            #"{"kind":"schedule-catalog","items":[{"id":"active-1","sessionId":"s1","status":"active","kind":"daily","title":"每日新闻汇总","prompt":"科技和金融新闻","scheduledAt":"2099-01-01T00:00:00.000Z"},{"id":"ended-1","sessionId":"s2","status":"ended","kind":"at","title":"构建检查","prompt":"检查发布结果","scheduledAt":"2098-01-01T00:00:00.000Z"}]}"#.utf8
        ))
        let tasks = try XCTUnwrap(catalog.items).compactMap(ScheduledTask.init)

        XCTAssertEqual(filteredScheduledTasks(tasks, status: .all, query: "新闻").map(\.id), ["active-1"])
        XCTAssertEqual(filteredScheduledTasks(tasks, status: .active, query: " 金融 ").map(\.id), ["active-1"])
        XCTAssertEqual(filteredScheduledTasks(tasks, status: .ended, query: "检查").map(\.id), ["ended-1"])
        XCTAssertTrue(filteredScheduledTasks(tasks, status: .active, query: "构建").isEmpty)
        XCTAssertEqual(filteredScheduledTasks(tasks, status: .all, query: " ").count, 2)
    }

    func testScheduleFramesPreserveCatalogHistoryAndConflict() throws {
        let catalog = try GatewayWireDecoder.decode(Data(
            #"{"kind":"schedule-catalog","items":[{"id":"task-1","sessionId":"s1","status":"active","kind":"every","title":"检查构建","prompt":"检查结果","everySeconds":300,"scheduledAt":"2099-01-01T00:00:00.000Z"}]}"#.utf8
        ))
        XCTAssertEqual(catalog.items?.first?["sessionId"]?.stringValue, "s1")
        let task = try XCTUnwrap(catalog.items?.first.flatMap(ScheduledTask.init))
        XCTAssertEqual(task.title, "检查构建")
        XCTAssertEqual(task.status, "active")
        XCTAssertEqual(task.raw["everySeconds"]?.doubleValue, 300)
        let history = try GatewayWireDecoder.decode(Data(
            #"{"kind":"schedule-history","sessionId":"s1","id":"task-1","records":[{"scheduledAt":"2099-01-01T00:00:00.000Z","deliveredAt":"2099-01-01T00:00:01.000Z","messageId":"message-1"}],"earlierRecordsUnavailable":false,"earlierRecordsPruned":false,"retention":{"days":30,"records":200},"nextBefore":"message-1"}"#.utf8
        ))
        XCTAssertEqual(history.records?.first?["messageId"]?.stringValue, "message-1")
        XCTAssertEqual(history.nextBefore, "message-1")
        let conflict = try GatewayWireDecoder.decode(Data(
            #"{"kind":"schedule-update","sessionId":"s1","id":"task-1","updated":false,"code":"schedule_conflict"}"#.utf8
        ))
        XCTAssertEqual(conflict.code, "schedule_conflict")
        XCTAssertEqual(conflict.updated, false)
        let updated = try GatewayWireDecoder.decode(Data(
            #"{"kind":"schedule-update","sessionId":"s1","id":"task-1","requestId":"edit-1","updated":true,"record":{"id":"task-1","kind":"daily","title":"检查构建","prompt":"检查结果","time":"09:00:00.000","timeZone":"Asia/Shanghai","scheduledAt":"2099-01-01T01:00:00.000Z"}}"#.utf8
        ))
        XCTAssertEqual(updated.requestId, "edit-1")
        XCTAssertEqual(updated.updated, true)
        let deleted = try GatewayWireDecoder.decode(Data(
            #"{"kind":"schedule-delete","sessionId":"s1","id":"task-1","requestId":"delete-1","deleted":true}"#.utf8
        ))
        XCTAssertEqual(deleted.requestId, "delete-1")
        XCTAssertEqual(deleted.deleted, true)
        let context = GatewayFrameRoutingContext(
            selectedSessionID: "s1",
            pendingHistorySessionID: nil,
            pendingModelsSessionID: nil,
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: nil,
            pendingPermissionOptionsSessionID: nil
        )
        let changed = try GatewayWireDecoder.decode(Data(#"{"kind":"schedule-changed"}"#.utf8))
        for frame in [catalog, history, conflict, updated, deleted, changed] {
            guard case .ignored = GatewayFrameRouter.route(frame, context: context) else {
                return XCTFail("已识别的定时任务帧不应触发未知响应提示")
            }
        }
    }

    @MainActor
    func testApprovalRequestRoutesThroughSharedReducerAndBuildsOneShotEffect() throws {
        let context = GatewayFrameRoutingContext(
            selectedSessionID: "s1",
            pendingHistorySessionID: nil,
            pendingModelsSessionID: nil,
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: nil,
            pendingPermissionOptionsSessionID: nil
        )
        let frame = try GatewayWireDecoder.decode(Data(
            GatewayProtocolParityFixtures.replayedApprovalRequest.utf8
        ))
        guard case .approval(.requested(let request)) =
                GatewayFrameRouter.route(frame, context: context) else {
            return XCTFail("有效审批请求应路由为 approval.requested")
        }
        XCTAssertEqual(request.rpcId, "rpc-approval-1")
        XCTAssertEqual(request.approvalId, "approval-1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.callId, "call-1")
        XCTAssertEqual(request.reason, "需要读取系统版本")
        XCTAssertEqual(request.displayReason?["zh-CN"], "允许读取系统版本？")
        XCTAssertTrue(request.replay)

        let adapter = KMPApprovalStoreAdapter()
        let received = adapter.reduce(.requestReceived(request))
        XCTAssertNil(received.error)
        XCTAssertEqual(received.snapshot.pendingRequests, [request])
        let submitted = adapter.reduce(.submitDecision(
            rpcID: request.rpcId,
            outcome: .allowedOnce,
            isConnected: true
        ))
        XCTAssertNil(submitted.error)
        XCTAssertEqual(submitted.effect?.action, "respond")
        XCTAssertEqual(submitted.effect?.approvalId, "approval-1")
        XCTAssertEqual(submitted.effect?.outcome, "allowed-once")
        XCTAssertEqual(submitted.snapshot.requestStatuses[request.rpcId]?.kind, "submitting")

        let duplicate = adapter.reduce(.submitDecision(
            rpcID: request.rpcId,
            outcome: .rejected,
            isConnected: true
        ))
        XCTAssertNil(duplicate.effect, "同一审批只能发出一次响应 effect")
    }

    func testApprovalArgumentsNormalizeJSONStringBeforeRendering() throws {
        let encodedArguments = JSONValue.string(
            #"{"command":"sw_vers && uname -a","description":"读取系统版本"}"#
        )
        let normalized = encodedArguments.normalizedValue

        XCTAssertEqual(normalized["command"]?.stringValue, "sw_vers && uname -a")
        XCTAssertEqual(normalized["description"]?.stringValue, "读取系统版本")
    }

    func testGatewayFrameRouterPreservesMissingSessionForKMPRequestCorrelation() throws {
        let context = GatewayFrameRoutingContext(
            selectedSessionID: "selected",
            pendingHistorySessionID: nil,
            pendingModelsSessionID: "models-session",
            isPendingGlobalModelsRequest: false,
            pendingModelSelectionSessionID: "selection-session",
            pendingPermissionOptionsSessionID: "permission-session"
        )
        let selected = try GatewayWireDecoder.decode(Data(
            #"{"kind":"select-model","selected":{"provider":"openai","model":"gpt-5"}}"#.utf8
        ))
        guard case .control(.modelSelected(let sessionID, let selection)) =
                GatewayFrameRouter.route(selected, context: context) else {
            return XCTFail("select-model 应保留网关原始 target")
        }
        XCTAssertNil(sessionID)
        XCTAssertEqual(selection?.model, "gpt-5")
    }

    func testAttachmentLoaderDeduplicatesAndHonorsConcurrencyLimit() {
        func attachment(_ id: String) -> GatewayImageAttachment {
            GatewayImageAttachment(
                attachmentId: id,
                mediaType: "image/png",
                bytes: 1,
                width: 1,
                height: 1
            )
        }
        var loader = AttachmentLoader(maximumConcurrentRequests: 2)
        let initial = loader.enqueue(
            [attachment("a"), attachment("b"), attachment("a"), attachment("cached"), attachment("c")],
            sessionID: "s1",
            isCached: { $0 == "cached" }
        )
        XCTAssertEqual(initial.map(\.attachment.id), ["a", "b"])
        XCTAssertEqual(loader.inFlightAttachmentIDs, ["a", "b"])
        XCTAssertEqual(loader.queuedAttachmentIDs, ["c"])

        let next = loader.complete(attachmentID: "a", isCached: { _ in false })
        XCTAssertEqual(next.map(\.attachment.id), ["c"])
        XCTAssertEqual(loader.inFlightAttachmentIDs, ["b", "c"])
        loader.reset()
        XCTAssertTrue(loader.inFlightAttachmentIDs.isEmpty)
        XCTAssertTrue(loader.queuedAttachmentIDs.isEmpty)
    }

    @MainActor
    func testQueueAndSteerDoNotLeakBackgroundTurnCounts() {
        let controller = AgentBackgroundExecutionController(application: BackgroundTaskApplicationSpy())
        controller.begin(sessionID: "s", startsNewTurn: true)
        controller.messageAccepted(sessionID: "s")
        controller.begin(sessionID: "s", startsNewTurn: true)
        controller.messageAccepted(sessionID: "s")
        XCTAssertEqual(controller.outstandingTurns, 1)
        controller.updateQueuedSessions(["s"])
        controller.turnEnded(sessionID: "s")
        XCTAssertTrue(controller.isAgentWorkActive)
        controller.updateQueuedSessions([])
        XCTAssertFalse(controller.isAgentWorkActive)
    }

    @MainActor
    func testAgentBackgroundExecutionControllerTracksTurnsAndEndsTask() {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)
        var expirationCount = 0
        controller.onBackgroundAllowanceExpired = { expirationCount += 1 }

        controller.begin(sessionID: nil, startsNewTurn: true)
        controller.associateSessionIfNeeded("s1")
        controller.begin(sessionID: "s1", startsNewTurn: true)
        XCTAssertTrue(controller.keepsConnectionAlive)
        XCTAssertEqual(controller.outstandingTurns, 2)
        XCTAssertEqual(application.beginCallCount, 0, "前台不应提前占用后台任务额度")

        controller.applicationDidEnterBackground()
        XCTAssertEqual(application.beginCallCount, 1)
        controller.turnEnded(sessionID: "s1")
        XCTAssertEqual(controller.outstandingTurns, 1)
        controller.turnEnded(sessionID: "s1")
        XCTAssertFalse(controller.keepsConnectionAlive)
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        XCTAssertEqual(expirationCount, 1)
    }

    @MainActor
    func testSessionSnapshotStopsMissedTurnAndLongRunningKeepAlive() {
        let application = BackgroundTaskApplicationSpy()
        let keepAlive = AgentLongRunningKeepAliveSpy()
        let controller = AgentBackgroundExecutionController(
            application: application,
            longRunningKeepAlive: keepAlive
        )

        controller.begin(sessionID: "finished", startsNewTurn: true)
        controller.beginQuestionAnswer(rpcID: "rpc-finished", sessionID: "finished")
        controller.updateQueuedSessions(["finished"])
        controller.applicationDidEnterBackground()

        XCTAssertTrue(controller.isAgentWorkActive)
        XCTAssertTrue(keepAlive.agentWorkIsActive)
        controller.reconcileSessions(runningBySessionID: ["finished": false])

        XCTAssertFalse(controller.isAgentWorkActive)
        XCTAssertFalse(keepAlive.agentWorkIsActive)
        XCTAssertTrue(controller.outstandingTurnsBySessionID.isEmpty)
        XCTAssertTrue(controller.questionAllowanceSessionIDs.isEmpty)
        XCTAssertEqual(application.endedIdentifiers.count, 1)
    }

    @MainActor
    func testQuestionBackgroundAllowanceDoesNotEndAnotherTurnAndAcceptedRestoresTurn() {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)

        controller.begin(sessionID: "s1", startsNewTurn: true)
        controller.beginQuestionAnswer(rpcID: "rpc-1", sessionID: "s1")
        controller.releaseQuestionAnswer(rpcID: "rpc-1")

        XCTAssertTrue(controller.isAgentWorkActive)
        XCTAssertEqual(controller.outstandingTurns, 1)
        XCTAssertTrue(controller.questionAllowanceSessionIDs.isEmpty)
        XCTAssertEqual(application.endedIdentifiers.count, 0)

        controller.turnEnded(sessionID: "s1")
        XCTAssertFalse(controller.isAgentWorkActive)
        XCTAssertEqual(application.endedIdentifiers.count, 0)

        controller.beginQuestionAnswer(rpcID: "rpc-restored", sessionID: "s2")
        XCTAssertEqual(controller.outstandingTurns, 0)
        controller.questionAnswerAccepted(rpcID: "rpc-restored")
        XCTAssertEqual(controller.outstandingTurns, 1)
        XCTAssertTrue(controller.questionAllowanceSessionIDs.isEmpty)
        XCTAssertTrue(controller.keepsConnectionAlive)

        controller.turnEnded(sessionID: "s2")
        XCTAssertFalse(controller.isAgentWorkActive)
        XCTAssertEqual(application.endedIdentifiers.count, 0)
    }

    @MainActor
    func testBackgroundExecutionTracksTurnsAndAcceptedQuestionsPerSession() {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)

        controller.begin(sessionID: "s1", startsNewTurn: true)
        controller.beginQuestionAnswer(rpcID: "rpc-s2-a", sessionID: "s2")
        controller.beginQuestionAnswer(rpcID: "rpc-s2-b", sessionID: "s2")
        controller.questionAnswerAccepted(rpcID: "rpc-s2-a")
        controller.questionAnswerAccepted(rpcID: "rpc-s2-b")

        XCTAssertEqual(controller.outstandingTurnsBySessionID, ["s1": 1, "s2": 1])
        XCTAssertEqual(controller.outstandingTurns, 2)
        XCTAssertNil(controller.sessionID)
        XCTAssertEqual(application.beginCallCount, 0)

        controller.turnEnded(sessionID: "s1")
        XCTAssertEqual(controller.outstandingTurnsBySessionID, ["s2": 1])
        XCTAssertTrue(controller.keepsConnectionAlive)
        XCTAssertEqual(application.endedIdentifiers.count, 0)

        controller.turnEnded(sessionID: "s2")
        XCTAssertFalse(controller.isAgentWorkActive)
        XCTAssertEqual(application.endedIdentifiers.count, 0)
    }

    @MainActor
    func testBackgroundExecutionReleasesOnlyTargetSessionAllowancesAndCancelClearsAll() {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)

        controller.beginQuestionAnswer(rpcID: "rpc-s1-a", sessionID: "s1")
        controller.beginQuestionAnswer(rpcID: "rpc-s1-b", sessionID: "s1")
        controller.beginQuestionAnswer(rpcID: "rpc-s2", sessionID: "s2")
        controller.releaseQuestionAnswers(sessionID: "s1")

        XCTAssertEqual(controller.questionAllowanceSessionIDs, ["rpc-s2": "s2"])
        XCTAssertTrue(controller.keepsConnectionAlive)
        XCTAssertEqual(application.endedIdentifiers.count, 0)

        controller.cancel()
        XCTAssertTrue(controller.outstandingTurnsBySessionID.isEmpty)
        XCTAssertEqual(controller.unassociatedOutstandingTurns, 0)
        XCTAssertTrue(controller.questionAllowanceSessionIDs.isEmpty)
        XCTAssertFalse(controller.keepsConnectionAlive)
        XCTAssertEqual(application.endedIdentifiers.count, 0)
    }

    @MainActor
    func testBackgroundAllowanceStartsOnlyInBackgroundAndRestartsAcrossForeground() {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)

        controller.begin(sessionID: "s1", startsNewTurn: true)
        XCTAssertEqual(application.beginCallCount, 0)

        controller.applicationDidEnterBackground()
        XCTAssertEqual(application.beginCallCount, 1)
        XCTAssertTrue(controller.keepsConnectionAlive)

        controller.applicationDidBecomeActive()
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        XCTAssertTrue(controller.isAgentWorkActive)
        XCTAssertTrue(controller.keepsConnectionAlive)

        controller.applicationDidEnterBackground()
        XCTAssertEqual(application.beginCallCount, 2)
        controller.turnEnded(sessionID: "s1")
        XCTAssertEqual(application.endedIdentifiers.count, 2)
        XCTAssertFalse(controller.keepsConnectionAlive)
    }

    @MainActor
    func testBackgroundTaskExpirationClearsAllInternalActivity() async {
        let application = BackgroundTaskApplicationSpy()
        let controller = AgentBackgroundExecutionController(application: application)
        var expirationCount = 0
        controller.onBackgroundAllowanceExpired = { expirationCount += 1 }

        controller.begin(sessionID: "s1", startsNewTurn: true)
        controller.beginQuestionAnswer(rpcID: "rpc-1", sessionID: "s1")
        controller.applicationDidEnterBackground()
        application.expirationHandler?()
        await Task.yield()

        XCTAssertFalse(controller.isAgentWorkActive)
        XCTAssertFalse(controller.keepsConnectionAlive)
        XCTAssertEqual(controller.outstandingTurns, 0)
        XCTAssertTrue(controller.outstandingTurnsBySessionID.isEmpty)
        XCTAssertEqual(controller.unassociatedOutstandingTurns, 0)
        XCTAssertNil(controller.sessionID)
        XCTAssertTrue(controller.questionAllowanceSessionIDs.isEmpty)
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        XCTAssertEqual(expirationCount, 1)
    }

    @MainActor
    func testLongRunningKeepAlivePreservesTurnWhenFiniteTaskExpires() async {
        let application = BackgroundTaskApplicationSpy()
        let keepAlive = AgentLongRunningKeepAliveSpy()
        let controller = AgentBackgroundExecutionController(
            application: application,
            longRunningKeepAlive: keepAlive
        )
        var expirationCount = 0
        var pulseCount = 0
        controller.onBackgroundAllowanceExpired = { expirationCount += 1 }
        controller.onKeepAlivePulse = { pulseCount += 1 }

        controller.begin(sessionID: "s1", startsNewTurn: true)
        XCTAssertTrue(keepAlive.agentWorkIsActive)
        controller.applicationDidEnterBackground()
        keepAlive.isKeepingAlive = true
        keepAlive.onPulse?()
        application.expirationHandler?()
        await Task.yield()

        XCTAssertEqual(controller.outstandingTurns, 1)
        XCTAssertTrue(controller.keepsConnectionAlive)
        XCTAssertEqual(application.endedIdentifiers.count, 1)
        XCTAssertEqual(expirationCount, 0)
        XCTAssertEqual(pulseCount, 1)

        controller.turnEnded(sessionID: "s1")
        XCTAssertFalse(keepAlive.agentWorkIsActive)
        XCTAssertEqual(expirationCount, 1)
    }

    func testUserDefaultsAppPreferencesUsesDefaultsAndRoundTripsValues() throws {
        let suiteName = "AppPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UserDefaultsAppPreferences(userDefaults: defaults)

        XCTAssertEqual(preferences.endpoint, UserDefaultsAppPreferences.defaultEndpoint)
        XCTAssertNil(preferences.selectedWorkspaceID)
        XCTAssertEqual(preferences.loadSessions(), [])

        let sessions = [
            SessionSummary(
                id: "session-1",
                title: "持久化测试",
                lastActivity: Date(timeIntervalSince1970: 1_000),
                isRunning: true,
                hasUnread: true,
                agentPreset: "default"
            )
        ]
        preferences.endpoint = "wss://gateway.example/ws/mobile"
        preferences.selectedWorkspaceID = "workspace-1"
        preferences.saveSessions(sessions)

        let reloaded = UserDefaultsAppPreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.endpoint, "wss://gateway.example/ws/mobile")
        XCTAssertEqual(reloaded.selectedWorkspaceID, "workspace-1")
        XCTAssertEqual(reloaded.loadSessions(), sessions)

        reloaded.selectedWorkspaceID = nil
        XCTAssertNil(defaults.object(forKey: "gateway.selectedWorkspaceId"))
    }

    func testUserDefaultsAppPreferencesPreservesExistingKeysAndRunsLegacyCleanup() throws {
        let suiteName = "AppPreferencesMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ws://legacy-host:3080/ws/mobile", forKey: "gateway.endpoint")
        defaults.set(["session-1": 42], forKey: "gateway.conversationScrollAnchors")
        defaults.set(["session-1"], forKey: "gateway.manuallyPositionedSessionIds")
        let preferences = UserDefaultsAppPreferences(userDefaults: defaults)

        preferences.performMigrations()

        XCTAssertEqual(preferences.endpoint, "ws://legacy-host:3080/ws/mobile")
        XCTAssertNil(defaults.object(forKey: "gateway.conversationScrollAnchors"))
        XCTAssertNil(defaults.object(forKey: "gateway.manuallyPositionedSessionIds"))
    }

    @MainActor
    func testAppStoreLoadsInjectedPreferencesAndPersistsEachSessionChangeOnce() async {
        let initialSession = SessionSummary(
            id: "existing",
            title: "已有会话",
            lastActivity: Date(timeIntervalSince1970: 900),
            isRunning: false,
            hasUnread: false
        )
        let preferences = AppPreferencesSpy(
            endpoint: "wss://injected.example/ws/mobile",
            selectedWorkspaceID: "workspace-injected",
            sessions: [initialSession]
        )

        let store = AppStore(preferences: preferences)

        XCTAssertEqual(store.endpoint, preferences.endpoint)
        XCTAssertEqual(store.selectedWorkspaceId, preferences.selectedWorkspaceID)
        XCTAssertEqual(store.sessions, [initialSession])
        XCTAssertEqual(preferences.performMigrationsCallCount, 1)
        XCTAssertEqual(preferences.savedSessionSnapshots, [])

        store.addKnownSession("new-session")
        XCTAssertEqual(
            preferences.savedSessionSnapshots,
            [],
            "KMP Event 不得在 UI Intent 的同一调用栈内发布 Swift 镜像"
        )
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(preferences.savedSessionSnapshots.count, 1)
        XCTAssertEqual(preferences.savedSessionSnapshots.last?.map(\.id), ["new-session", "existing"])

        store.addKnownSession("new-session")
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(preferences.savedSessionSnapshots.count, 1)
    }

    func testImageAttachmentCachePersistsAndExpires() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let payload = Data("cached-image".utf8)
        let cache = ImageAttachmentCache(
            directoryURL: directory,
            ttl: 60,
            memoryCostLimit: 1,
            now: { currentDate }
        )

        cache.store(payload, for: "attachment/unsafe-path")
        await cache.flushWrites()
        cache.removeAllFromMemory()
        let loaded = await cache.loadData(for: "attachment/unsafe-path")
        XCTAssertEqual(loaded, payload)

        cache.removeAllFromMemory()
        currentDate.addTimeInterval(61)
        let expired = await cache.loadData(for: "attachment/unsafe-path")
        XCTAssertNil(expired)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testImagePixelLimitPreflight() {
        let accepted = GatewayImageDimensions(width: 2_000, height: 2_000)
        let sideTooLong = GatewayImageDimensions(width: 2_001, height: 1_000)

        XCTAssertTrue(GatewayImageInspector.isWithinPixelLimits(accepted))
        XCTAssertFalse(GatewayImageInspector.isWithinPixelLimits(sideTooLong))
    }

    func testImagePreprocessorDownsizesToDSHLimits() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 1_500), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_500))
        }
        let source = try XCTUnwrap(image.pngData())
        let prepared = try GatewayImagePreprocessor.prepare(data: source, mediaType: "image/png")

        XCTAssertEqual(prepared.mediaType, "image/jpeg")
        XCTAssertLessThanOrEqual(prepared.data.count, GatewayImagePreprocessor.maximumBytes)
        XCTAssertLessThanOrEqual(prepared.dimensions.longestSide, GatewayImagePreprocessor.maximumPixelSide)
        XCTAssertLessThanOrEqual(
            prepared.dimensions.width * prepared.dimensions.height,
            GatewayImagePreprocessor.maximumPixels
        )
        XCTAssertEqual(prepared.dimensions.width, 2_000)
        XCTAssertEqual(prepared.dimensions.height, 1_000)
    }

    func testImagePreprocessorNormalizesOrientationWithoutChangingAspectRatio() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let sourceData = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sourceData as CFData, nil))
        let orientedData = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                orientedData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let input = orientedData as Data
        XCTAssertEqual(GatewayImageInspector.dimensions(of: input), GatewayImageDimensions(width: 20, height: 40))

        let prepared = try GatewayImagePreprocessor.prepare(data: input, mediaType: "image/jpeg")

        XCTAssertEqual(prepared.dimensions, GatewayImageDimensions(width: 20, height: 40))
        XCTAssertEqual(GatewayImageInspector.dimensions(of: prepared.data), GatewayImageDimensions(width: 20, height: 40))
        XCTAssertEqual(GatewayImageInspector.orientation(of: prepared.data), 1)
    }

    func testDecodesProtocolThreeImageCapability() throws {
        let json = #"{"kind":"hello","protocol":3,"capabilities":["images"],"authenticated":true}"#
        let frame = try GatewayWireDecoder.decode(Data(json.utf8))

        XCTAssertEqual(frame.protocol, 3)
        XCTAssertEqual(frame.capabilities, ["images"])
    }

    func testDecodesLiveImageReference() throws {
        let json = #"{"kind":"event","sessionId":"s1","seq":7,"time":1001,"event":{"type":"user/message","text":"描述它","source":"user","images":[{"attachmentId":"att-1","mediaType":"image/jpeg","bytes":12,"width":3,"height":4,"name":"photo.jpg"}]}}"#
        let frame = try GatewayWireDecoder.decode(Data(json.utf8))

        XCTAssertEqual(frame.event?.images?.first?.attachmentId, "att-1")
        XCTAssertEqual(frame.event?.images?.first?.mediaType, "image/jpeg")
    }

    func testDecodesAttachmentPayload() throws {
        let json = GatewayProtocolParityFixtures.imageAttachment
        let frame = try GatewayWireDecoder.decode(Data(json.utf8))

        XCTAssertEqual(frame.attachment?.attachmentId, "att-1")
        XCTAssertEqual(frame.data, "iVBORw0K")
    }

    func testDecodesToolEvent() throws {
        let json = #"{"kind":"event","sessionId":"s1","seq":4,"time":1000,"event":{"type":"tool/call","turn":1,"step":2,"callId":"c1","name":"Bash","arguments":{"cmd":"pwd"}}}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.sessionId, "s1")
        XCTAssertEqual(frame.event?.name, "Bash")
        XCTAssertEqual(frame.event?.arguments?.displayText.contains("pwd"), true)
    }

    func testDecodesStructuredToolFailure() throws {
        let structured = #"{"kind":"event","sessionId":"s1","seq":9000,"time":1,"event":{"type":"tool/result","isError":true,"error":{"name":"ToolError","code":"DENIED","reason":"permission denied"}}}"#
        let frame = try GatewayWireDecoder.decode(Data(structured.utf8))
        XCTAssertEqual(frame.event?.error, "permission denied")
        XCTAssertEqual(frame.event?.isError, true)

        let legacy = #"{"kind":"event","sessionId":"s1","seq":9001,"time":2,"event":{"type":"tool/result","error":"legacy error"}}"#
        XCTAssertEqual(try GatewayWireDecoder.decode(Data(legacy.utf8)).event?.error, "legacy error")
    }

    func testDecodesAssistantChunk() throws {
        let json = #"{"kind":"event","sessionId":"s1","seq":5,"time":1001,"event":{"type":"assistant/chunk","turn":1,"step":2,"chunkType":"text-delta","text":"hello"}}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.event?.chunkType, "text-delta")
        XCTAssertEqual(frame.event?.text, "hello")
    }

    func testDecodesLiveEventWhenGatewayOmitsKind() throws {
        let json = GatewayProtocolParityFixtures.liveEventWithoutKind
        let frame = try GatewayWireDecoder.decode(Data(json.utf8))
        XCTAssertEqual(frame.kind, "event")
        XCTAssertEqual(frame.event?.type, "assistant/chunk")
        XCTAssertEqual(frame.event?.text, "thinking")
    }

    @MainActor
    func testKMPConversationShowsPluginPromptsAsCompactContextRows() throws {
        let records = [
            SessionEvent(sessionId: "s1", seq: 1, time: 1, event: GatewayEvent(type: "permission/preset")),
            SessionEvent(sessionId: "s1", seq: 2, time: 2, event: GatewayEvent(type: "user/message", text: "runtime", source: "plugin")),
            SessionEvent(sessionId: "s1", seq: 3, time: 3, event: GatewayEvent(type: "user/message", text: "你好", source: "user")),
            SessionEvent(sessionId: "s1", seq: 4, time: 4, event: GatewayEvent(type: "assistant/message", text: "你好！", reasoning: "思考")),
            SessionEvent(sessionId: "s1", seq: 5, time: 5, event: GatewayEvent(type: "tool/call", name: "Read"))
        ]
        let adapter = KMPConversationStoreAdapter()
        try adapter.replace(sessionID: "s1", events: records)
        let items = adapter.items(for: "s1")
        // Expected titles resolve through the same localized constants the
        // projection uses, so this passes under any test locale.
        XCTAssertEqual(items.map(\.title), [
            L10n.contextInjectionTitle("plugin"),
            L10n.userMessageTitle,
            "Think",
            "DeepSeek",
            "Read",
        ])
    }

    @MainActor
    func testKMPConversationRunCodeUsesJSONToolRendering() throws {
        let payload: JSONValue = .string(#"{"language":"python","code":"print(1)"}"#)
        let record = SessionEvent(
            sessionId: "s1",
            seq: 1,
            time: 1,
            event: GatewayEvent(type: "tool/call", name: "run_code", arguments: payload)
        )
        let adapter = KMPConversationStoreAdapter()
        try adapter.replace(sessionID: "s1", events: [record])
        let item = adapter.items(for: "s1").first
        XCTAssertEqual(item?.title, "run_code")
        XCTAssertEqual(item?.kind, .jsonTool)
        XCTAssertTrue(item?.text.contains("\"language\"") == true)
        XCTAssertTrue(item?.text.contains("\"python\"") == true)
    }

    @MainActor
    func testKMPTrajectoryAggregatesChunksAndPairsToolResult() throws {
        let events = [
            SessionEvent(sessionId: "s1", seq: 0, time: 1, event: GatewayEvent(type: "permission/preset")),
            SessionEvent(sessionId: "s1", seq: 1, time: 2, event: GatewayEvent(type: "user/message", text: "查文件", source: "user")),
            SessionEvent(sessionId: "s1", seq: 2, time: 3, event: GatewayEvent(type: "assistant/chunk", turn: 1, step: 1, text: "先", chunkType: "reasoning-delta")),
            SessionEvent(sessionId: "s1", seq: 3, time: 4, event: GatewayEvent(type: "assistant/chunk", turn: 1, step: 1, text: "读取", chunkType: "reasoning-delta")),
            SessionEvent(sessionId: "s1", seq: 4, time: 5, event: GatewayEvent(type: "assistant/message", turn: 1, step: 1, reasoning: "先读取", toolCalls: [])),
            SessionEvent(sessionId: "s1", seq: 5, time: 6, event: GatewayEvent(type: "tool/call", turn: 1, step: 1, callId: "c1", name: "Read", arguments: .object(["path": .string("a.swift")]))),
            SessionEvent(sessionId: "s1", seq: 6, time: 7, event: GatewayEvent(type: "tool/result", turn: 1, step: 1, callId: "c1", isError: false, preview: "contents"))
        ]
        let adapter = KMPTrajectoryStoreAdapter()
        try adapter.replace(sessionID: "s1", events: events)
        let nodes = adapter.nodes(for: "s1")
        XCTAssertEqual(nodes.map(\.kind), [.input, .request, .assistant, .tool])
        XCTAssertEqual(nodes[1].request?.number, 1)
        XCTAssertEqual(nodes[2].subtitle, "先读取")
        XCTAssertTrue(nodes[3].subtitle.contains("contents"))
        XCTAssertEqual(nodes[3].records.count, 2)
    }

    @MainActor
    func testKMPTrajectoryProjectsRequestUsageAndSubtool() throws {
        let headerData: JSONValue = .object([
            "header": .object([
                "config": .object([
                    "provider": .string("deepseek-official"),
                    "model": .string("deepseek-v4-flash"),
                    "reasoningEffort": .string("high")
                ]),
                "tools": .array([
                    .object([
                        "name": .string("run_code"),
                        "description": .string("Run code"),
                        "parameters": .object(["type": .string("object")])
                    ])
                ])
            ])
        ])
        let usage: JSONValue = .object([
            "inputTokens": .number(327),
            "cacheReadTokens": .number(9216),
            "outputTokens": .number(208),
            "reasoningTokens": .number(93)
        ])
        let events = [
            SessionEvent(sessionId: "s1", seq: 1, time: 1, event: GatewayEvent(type: "request/header", raw: headerData)),
            SessionEvent(sessionId: "s1", seq: 2, time: 2, event: GatewayEvent(type: "assistant/chunk", turn: 4, step: 1, text: "thinking", chunkType: "reasoning-delta")),
            SessionEvent(sessionId: "s1", seq: 3, time: 3, event: GatewayEvent(type: "assistant/message", turn: 4, step: 1, text: "done", usage: usage, toolCalls: [ToolCall(id: "c1", name: "run_code")])),
            SessionEvent(sessionId: "s1", seq: 4, time: 4, event: GatewayEvent(type: "tool/call", turn: 4, step: 1, callId: "c1", name: "run_code", arguments: .object(["code": .string("return 1")]))),
            SessionEvent(sessionId: "s1", seq: 5, time: 5, event: GatewayEvent(type: "tool/code-dispatch-start", name: "bash", arguments: .object(["command": .string("pwd")]), rootCallId: "c1", parentCallId: "c1", subCallId: "c1:code:1")),
            SessionEvent(sessionId: "s1", seq: 6, time: 6, event: GatewayEvent(type: "tool/code-dispatch", name: "bash", arguments: .object(["command": .string("pwd")]), isError: false, preview: "/tmp", rootCallId: "c1", parentCallId: "c1", subCallId: "c1:code:1"))
        ]
        let adapter = KMPTrajectoryStoreAdapter()
        try adapter.replace(sessionID: "s1", events: events)
        let nodes = adapter.nodes(for: "s1")
        XCTAssertEqual(nodes.map(\.kind), [.request, .assistant, .tool, .subtool])
        XCTAssertEqual(nodes[0].request?.usage.totalInput, 9543)
        XCTAssertEqual(nodes[0].request?.usage.content, 115)
        XCTAssertEqual(nodes[0].request?.subtoolCalls, 1)
        XCTAssertEqual(nodes[2].tool?.schema?["name"]?.stringValue, "run_code")
        XCTAssertEqual(nodes[3].tool?.hierarchy, "run_code")
        XCTAssertEqual(nodes[3].records.count, 2)
    }

    func testDecodesSessionListItems() throws {
        let json = #"{"kind":"sessions","items":[{"sessionId":"s1","updatedAt":1786937352,"running":true,"blank":false,"cwd":"/tmp/project","agentPreset":"standard"}]}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        let item = try XCTUnwrap(frame.items?.first?.decode(GatewaySessionSummary.self))
        XCTAssertEqual(item.sessionId, "s1")
        XCTAssertTrue(item.running)
        XCTAssertEqual(item.cwd, "/tmp/project")
    }

    func testNormalizesRawHistoryMessage() throws {
        let json = #"{"kind":"history","events":[{"type":"user/message","seq":1,"time":1786937352,"data":{"content":[{"type":"text","text":"历史消息"}]}}],"hasMore":false}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        let event = try XCTUnwrap(frame.events?.first?.normalized(sessionId: "s1"))
        XCTAssertEqual(event.event.type, "user/message")
        XCTAssertEqual(event.event.text, "历史消息")
    }

    func testNormalizesTurnEndReasonFromGatewayAndRawHistoryShapes() throws {
        let stringReason = #"{"kind":"history","events":[{"type":"turn/end","seq":2,"time":1786937353,"data":{"turn":1,"step":3,"reason":"error"}}],"hasMore":false}"#
        let objectReason = #"{"kind":"history","events":[{"type":"turn/end","seq":3,"time":1786937354,"data":{"turn":1,"step":3,"reason":{"kind":"cancelled"}}}],"hasMore":false}"#

        let stringFrame = try JSONDecoder().decode(GatewayFrame.self, from: Data(stringReason.utf8))
        let objectFrame = try JSONDecoder().decode(GatewayFrame.self, from: Data(objectReason.utf8))

        XCTAssertEqual(stringFrame.events?.first?.normalized(sessionId: "s1").event.reason, "error")
        XCTAssertEqual(objectFrame.events?.first?.normalized(sessionId: "s1").event.reason, "cancelled")
    }

    @MainActor
    func testNormalizesRawHistoryImageReferenceAndProjectsWithKMP() throws {
        let json = GatewayProtocolParityFixtures.historyImage
        let frame = try GatewayWireDecoder.decode(Data(json.utf8))
        let event = try XCTUnwrap(frame.events?.first?.normalized(sessionId: "s1"))
        let adapter = KMPConversationStoreAdapter()
        try adapter.replace(sessionID: "s1", events: [event])
        let item = try XCTUnwrap(adapter.items(for: "s1").first)

        XCTAssertEqual(event.event.images?.first?.attachmentId, "att-history")
        XCTAssertEqual(item.kind, .user)
        XCTAssertEqual(item.text, "")
        XCTAssertEqual(item.images.first?.mediaType, "image/webp")
    }

    func testNormalizesRawSubtoolDispatch() throws {
        let json = #"{"kind":"history","events":[{"type":"tool/code-dispatch-start","seq":8,"time":1786937352,"data":{"rootCallId":"root","parentCallId":"root","subCallId":"root:code:1","name":"bash","arguments":{"command":"pwd"}}},{"type":"tool/code-dispatch","seq":9,"time":1786937353,"data":{"rootCallId":"root","parentCallId":"root","subCallId":"root:code:1","name":"bash","arguments":{"command":"pwd"},"isError":false,"content":[{"type":"text","text":"/tmp"}]}}],"hasMore":false}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        let events = try XCTUnwrap(frame.events).map { $0.normalized(sessionId: "s1") }
        XCTAssertEqual(events[0].event.subCallId, "root:code:1")
        XCTAssertEqual(events[0].event.arguments?["command"]?.stringValue, "pwd")
        XCTAssertEqual(events[1].event.preview, "/tmp")
        XCTAssertEqual(events[1].event.isError, false)
    }

    func testDecodesSessionControlResponsesAndHistoryProjections() throws {
        let modelsJSON = #"{"kind":"models","current":{"provider":"deepseek-official","model":"deepseek-v4-flash","reasoningEffort":"high"},"routable":true,"groups":[{"id":"deepseek-official","name":"DeepSeek","models":[{"id":"deepseek-v4-flash","name":"DeepSeek-V4-Flash","reasoning":{"efforts":[{"id":"off","name":"Off"},{"id":"high","name":"High"}],"defaultEffort":"high"}}]}],"failures":[]}"#
        let models = try GatewayWireDecoder.decode(Data(modelsJSON.utf8))
        XCTAssertEqual(models.current?.model, "deepseek-v4-flash")
        let firstModelGroup = try XCTUnwrap(models.groups?.first?.decode(GatewayModelGroup.self))
        XCTAssertEqual(firstModelGroup.models.first?.reasoning?.efforts.map(\.id), ["off", "high"])

        let permissionsJSON = #"{"kind":"permission-options","namespace":{"value":{"defaultPreset":"workspace-write"}},"sessionPermissions":{"options":[{"value":"read-only","name":"read-only"},{"value":"danger-full-access","name":"danger-full-access"}],"currentValue":"danger-full-access"}}"#
        let permissions = try GatewayWireDecoder.decode(Data(permissionsJSON.utf8))
        XCTAssertEqual(permissions.sessionPermissions?.currentValue, "danger-full-access")
        XCTAssertEqual(permissions.sessionPermissions?.options?.count, 2)

        let usageJSON = #"{"kind":"context-usage","sessionId":"s1","asOfSeq":260245,"tokenUsage":{"uncachedInputTokens":613950,"outputTokens":268657,"cacheReadTokens":72057728,"cacheWriteTokens":0},"contextPressure":{"pressureTokens":434856,"projectedTokens":435317,"contextWindow":1000000}}"#
        let usage = try GatewayWireDecoder.decode(Data(usageJSON.utf8))
        XCTAssertEqual(usage.contextPressure?.pressureTokens, 434856)
        XCTAssertEqual(usage.contextPressure?.contextWindow, 1_000_000)

        let historyJSON = #"{"kind":"history","sessionId":"s1","events":[],"hasMore":false,"projections":{"asOfSeq":260245,"values":{"contextBreakdown":{"systemTokens":4404,"toolsTokens":8247,"messageTokens":357987},"permissions":{"currentValue":"workspace-write"}}}}"#
        let history = try GatewayWireDecoder.decode(Data(historyJSON.utf8))
        let breakdown = history.projections?["values"]?["contextBreakdown"]?.decode(GatewayContextBreakdown.self)
        XCTAssertEqual(breakdown?.toolsTokens, 8247)
        XCTAssertEqual(history.projections?["values"]?["permissions"]?["currentValue"]?.stringValue, "workspace-write")
    }

    func testDecodesReplayedHumanQuestionRequest() throws {
        let json = GatewayProtocolParityFixtures.replayedQuestionRequest
        let frame = try GatewayWireDecoder.decode(Data(json.utf8))

        XCTAssertEqual(frame.rpcId, "rpc-1")
        XCTAssertEqual(frame.sessionId, "s1")
        XCTAssertEqual(frame.replay, true)
        XCTAssertEqual(frame.questions?.count, 2)
        XCTAssertEqual(frame.questions?.first?.options?.first?.label, "核心架构 (推荐)")
        XCTAssertEqual(frame.questions?.first?.allowsMultipleSelections, true)
    }

    func testDecodesQuestionResponseAndResolution() throws {
        let response = try GatewayWireDecoder.decode(Data(#"{"kind":"question-response","rpcId":"rpc-1","sessionId":"s1","action":"answer","accepted":false,"reason":"not-pending"}"#.utf8))
        XCTAssertEqual(response.action, "answer")
        XCTAssertEqual(response.accepted, false)
        XCTAssertEqual(response.reason, "not-pending")

        let resolved = try GatewayWireDecoder.decode(Data(#"{"kind":"question-resolved","rpcId":"rpc-1","sessionId":"s1","outcome":"answered"}"#.utf8))
        XCTAssertEqual(resolved.outcome, "answered")
    }

    func testPairingPayloadParserAcceptsValidTrimmedPayload() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let encoded = try pairingPayloadString(
            publicURL: "wss://gateway.example/ws/mobile",
            expiresAt: 1_001_000
        )

        let payload = try PairingPayloadParser.parse("  \n\(encoded)\t", now: now)

        XCTAssertEqual(payload.version, 2)
        XCTAssertEqual(payload.publicUrl, "wss://gateway.example/ws/mobile")
        XCTAssertEqual(payload.pairingCode, "one-time-code")
    }

    func testPairingPayloadParserRejectsInvalidBase64URLAndJSON() throws {
        XCTAssertThrowsError(try PairingPayloadParser.parse("bad=value")) {
            XCTAssertEqual($0 as? PairingPayloadError, .invalidBase64URL)
        }
        let nonJSON = base64URL(Data("not-json".utf8))
        XCTAssertThrowsError(try PairingPayloadParser.parse(nonJSON)) {
            XCTAssertEqual($0 as? PairingPayloadError, .invalidJSON)
        }
    }

    func testPairingPayloadParserRejectsUnsupportedVersion() throws {
        let encoded = try pairingPayloadString(version: 3)
        XCTAssertThrowsError(try PairingPayloadParser.parse(encoded, now: .distantPast)) {
            XCTAssertEqual($0 as? PairingPayloadError, .unsupportedVersion(3))
        }
    }

    func testPairingPayloadParserRejectsInvalidEndpoint() throws {
        for endpoint in ["https://gateway.example/ws/mobile", "ws:///missing-host", "not-a-url"] {
            let encoded = try pairingPayloadString(publicURL: endpoint)
            XCTAssertThrowsError(try PairingPayloadParser.parse(encoded, now: .distantPast)) {
                XCTAssertEqual($0 as? PairingPayloadError, .invalidEndpoint)
            }
        }
    }

    func testPairingPayloadParserRejectsInvalidPairingCode() throws {
        for code in ["", "contains,comma", "contains space", "contains\nnewline"] {
            let encoded = try pairingPayloadString(pairingCode: code)
            XCTAssertThrowsError(try PairingPayloadParser.parse(encoded, now: .distantPast)) {
                XCTAssertEqual($0 as? PairingPayloadError, .invalidCode)
            }
        }
    }

    func testPairingPayloadParserRejectsExpiredPayloadAtBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let encoded = try pairingPayloadString(expiresAt: 1_000_000)
        XCTAssertThrowsError(try PairingPayloadParser.parse(encoded, now: now)) {
            XCTAssertEqual($0 as? PairingPayloadError, .expired)
        }
    }

    @MainActor
    func testKMPSessionListAdapterPublishesChangedSnapshotThroughEventStream() throws {
        let adapter = KMPSessionListStoreAdapter(sessions: [])
        var snapshots: [KMPSessionListSnapshot] = []
        adapter.onSnapshot = { snapshot, error in
            XCTAssertNil(error)
            if let snapshot { snapshots.append(snapshot) }
        }

        _ = try adapter.reduce(
            .knownSessionAdded("session-event"),
            now: Date(timeIntervalSince1970: 100)
        )
        _ = try adapter.reduce(
            .knownSessionAdded("session-event"),
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNotNil(adapter.lastEventSequence)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.sessions.first?.id, "session-event")
    }

    @MainActor
    func testKMPSessionListAdapterMapsPersistenceAndOwnsSessionStateTransitions() throws {
        let persisted = SessionSummary(
            id: "existing",
            title: "旧标题",
            lastActivity: Date(timeIntervalSince1970: 10),
            isRunning: false,
            hasUnread: true,
            agentPreset: "keep"
        )
        let adapter = KMPSessionListStoreAdapter(
            sessions: [persisted],
            selectedSessionId: "selected"
        )
        XCTAssertNil(adapter.initializationError)
        XCTAssertNil(adapter.runtimeError)
        XCTAssertTrue(adapter.isOperational)
        XCTAssertEqual(adapter.snapshot.persistedSessions, [persisted])

        _ = try adapter.reduce(.setArchivedSessionIDs(["archived"]))
        let remote = [
            GatewaySessionSummary(
                sessionId: "existing",
                updatedAt: 2_000,
                running: true,
                blank: false,
                cwd: "/tmp/existing"
            ),
            GatewaySessionSummary(
                sessionId: "new",
                updatedAt: 3_000,
                running: false,
                blank: false,
                cwd: "/tmp/new",
                agentPreset: "standard"
            ),
            GatewaySessionSummary(
                sessionId: "archived",
                updatedAt: 4_000,
                running: false,
                blank: false,
                cwd: "/tmp/archived"
            )
        ]
        var snapshot = try adapter.reduce(.remoteSessionsReceived(remote))
        XCTAssertEqual(snapshot.persistedSessions.map(\.id), ["new", "existing"])
        XCTAssertEqual(snapshot.persistedSessions.last?.agentPreset, "keep")
        XCTAssertEqual(snapshot.persistedSessions.last?.isRunning, true)
        XCTAssertEqual(snapshot.persistedSessions.last?.hasUnread, true)

        snapshot = try adapter.reduce(.eventReceived(SessionEvent(
            sessionId: "new",
            seq: 1,
            time: 3_001,
            event: GatewayEvent(type: "turn/start")
        )), now: Date(timeIntervalSince1970: 9_999))
        XCTAssertEqual(snapshot.persistedSessions.first?.id, "new")
        XCTAssertEqual(snapshot.persistedSessions.first?.isRunning, true)
        XCTAssertEqual(snapshot.persistedSessions.first?.hasUnread, true)

        _ = try adapter.reduce(.select("new"))
        snapshot = try adapter.reduce(.markRead("new"))
        XCTAssertEqual(snapshot.selectedSessionId, "new")
        XCTAssertEqual(snapshot.persistedSessions.first?.hasUnread, false)

        snapshot = try adapter.reduce(
            .knownSessionAdded("known"),
            now: Date(timeIntervalSince1970: 8_000)
        )
        XCTAssertEqual(
            snapshot.persistedSessions.first { $0.id == "known" }?.lastActivity,
            Date(timeIntervalSince1970: 8_000)
        )
    }

    @MainActor
    func testKMPSessionListAdapterFailsClosedAfterRestoreFailure() throws {
        let persisted = SessionSummary(
            id: "persisted",
            title: "必须保留",
            lastActivity: Date(timeIntervalSince1970: 123),
            isRunning: true,
            hasUnread: true
        )
        let bridge = FailingRestoreSessionListBridge()
        let adapter = KMPSessionListStoreAdapter(sessions: [persisted], bridge: bridge)

        XCTAssertFalse(adapter.isInitialized)
        XCTAssertNotNil(adapter.initializationError)
        XCTAssertEqual(adapter.snapshot.persistedSessions, [persisted])

        XCTAssertThrowsError(
            try adapter.reduce(
                .knownSessionAdded("must-not-reduce"),
                now: Date(timeIntervalSince1970: 9_999)
            )
        ) { error in
            guard case KMPSessionListStoreError.initializationFailed = error else {
                return XCTFail("预期 initializationFailed，实际为 \(error)")
            }
        }
        XCTAssertEqual(bridge.nonRestoreCallCount, 0)
        XCTAssertEqual(adapter.snapshot.persistedSessions, [persisted])
    }

    @MainActor
    func testKMPSessionListAdapterFailsClosedAfterMalformedRuntimeSnapshot() throws {
        let persisted = SessionSummary(
            id: "persisted",
            title: "必须保留",
            lastActivity: Date(timeIntervalSince1970: 123),
            isRunning: true,
            hasUnread: true
        )
        let bridge = MalformedMutationSessionListBridge()
        let adapter = KMPSessionListStoreAdapter(sessions: [persisted], bridge: bridge)

        XCTAssertTrue(adapter.isOperational)
        XCTAssertThrowsError(
            try adapter.reduce(
                .knownSessionAdded("hidden-kmp-session"),
                now: Date(timeIntervalSince1970: 9_999)
            )
        ) { error in
            guard case KMPSessionListStoreError.invalidSnapshot = error else {
                return XCTFail("预期 invalidSnapshot，实际为 \(error)")
            }
        }
        XCTAssertEqual(bridge.mutationCallCount, 1)
        XCTAssertNotNil(adapter.runtimeError)
        XCTAssertFalse(adapter.isOperational)
        XCTAssertEqual(adapter.snapshot.persistedSessions, [persisted])

        XCTAssertThrowsError(
            try adapter.reduce(
                .knownSessionAdded("must-not-reach-bridge"),
                now: Date(timeIntervalSince1970: 10_000)
            )
        ) { error in
            guard case KMPSessionListStoreError.runtimeFailed = error else {
                return XCTFail("预期 runtimeFailed，实际为 \(error)")
            }
        }
        XCTAssertEqual(bridge.mutationCallCount, 1)
        XCTAssertEqual(adapter.snapshot.persistedSessions, [persisted])
    }

    @MainActor
    func testAppStoreDoesNotPersistAfterMalformedKMPRuntimeSnapshot() {
        let persisted = SessionSummary(
            id: "persisted",
            title: "必须保留",
            lastActivity: Date(timeIntervalSince1970: 123),
            isRunning: false,
            hasUnread: false
        )
        let preferences = AppPreferencesSpy(
            endpoint: "wss://injected.example/ws/mobile",
            selectedWorkspaceID: nil,
            sessions: [persisted]
        )
        let bridge = MalformedMutationSessionListBridge()
        let store = AppStore(preferences: preferences, sessionListBridge: bridge)

        store.addKnownSession("hidden-kmp-session")

        XCTAssertEqual(store.sessions, [persisted])
        XCTAssertEqual(preferences.savedSessionSnapshots, [])
        XCTAssertEqual(bridge.mutationCallCount, 1)
        XCTAssertNotNil(store.lastError)

        store.addKnownSession("must-not-reach-bridge")

        XCTAssertEqual(store.sessions, [persisted])
        XCTAssertEqual(preferences.savedSessionSnapshots, [])
        XCTAssertEqual(bridge.mutationCallCount, 1)
    }

    @MainActor
    func testKMPQuestionAdapterPublishesStateAndEffectThroughEventStream() {
        let request = questionRequest()
        let answers = [
            GatewayQuestionAnswer(id: "direction", selected: ["架构"]),
            GatewayQuestionAnswer(id: "notes", selected: [], custom: "保持原生 UI")
        ]
        let adapter = KMPQuestionStoreAdapter()
        var pushed: [KMPQuestionTransition] = []
        adapter.onTransition = { pushed.append($0) }

        _ = adapter.reduce(.requestReceived(request))
        let returned = adapter.reduce(.submitAnswer(
            rpcID: request.rpcId,
            answers: answers,
            isConnected: true
        ))
        _ = adapter.reduce(.submitAnswer(
            rpcID: request.rpcId,
            answers: answers,
            isConnected: true
        ))

        XCTAssertNotNil(adapter.lastEventSequence)
        XCTAssertEqual(pushed.count, 2)
        XCTAssertEqual(pushed.last?.snapshot, returned.snapshot)
        XCTAssertEqual(pushed.last?.effect?.action, "answer")
    }

    @MainActor
    func testKMPQuestionAdapterOwnsStateAndEmitsEffectOnce() {
        let request = questionRequest()
        let answers = [
            GatewayQuestionAnswer(id: "direction", selected: ["架构"]),
            GatewayQuestionAnswer(id: "notes", selected: [], custom: "保持原生 UI")
        ]
        let adapter = KMPQuestionStoreAdapter()
        var transition = adapter.reduce(.requestReceived(request))
        XCTAssertNil(transition.error)
        XCTAssertEqual(transition.snapshot.pendingRequests, [request])
        XCTAssertEqual(transition.snapshot.platformStatuses[request.rpcId], .idle)

        transition = adapter.reduce(.submitAnswer(
            rpcID: request.rpcId,
            answers: answers,
            isConnected: true
        ))
        XCTAssertEqual(transition.snapshot.platformStatuses[request.rpcId], .submitting(.answer))
        XCTAssertEqual(transition.effect?.action, "answer")
        XCTAssertEqual(transition.effect?.answers, answers)

        // 第二次相同 intent 不能再次产生网络 effect。
        transition = adapter.reduce(.submitAnswer(
            rpcID: request.rpcId,
            answers: answers,
            isConnected: true
        ))
        XCTAssertNil(transition.effect)

        transition = adapter.reduce(.responseReceived(
            rpcID: request.rpcId,
            action: .answer,
            accepted: true,
            reason: nil
        ))
        XCTAssertEqual(transition.snapshot.platformStatuses[request.rpcId], .accepted(.answer))

        var replay = request
        replay.replay = true
        transition = adapter.reduce(.requestReceived(replay))
        XCTAssertEqual(transition.snapshot.pendingRequests, [replay])
        XCTAssertEqual(transition.snapshot.platformStatuses[request.rpcId], .accepted(.answer))

        transition = adapter.reduce(.resolved(rpcID: request.rpcId))
        XCTAssertTrue(transition.snapshot.pendingRequests.isEmpty)
        XCTAssertNil(transition.snapshot.platformStatuses[request.rpcId])
    }

    @MainActor
    func testKMPQuestionAdapterFailsClosedBeforeMalformedEffectCanExecute() {
        let bridge = MalformedMutationQuestionBridge()
        let adapter = KMPQuestionStoreAdapter(bridge: bridge)
        XCTAssertTrue(adapter.isOperational)

        let transition = adapter.reduce(.requestReceived(questionRequest()))
        XCTAssertNotNil(transition.error)
        XCTAssertNil(transition.effect)
        XCTAssertFalse(adapter.isOperational)
        XCTAssertEqual(bridge.mutationCallCount, 1)

        let second = adapter.reduce(.reset)
        XCTAssertNotNil(second.error)
        XCTAssertNil(second.effect)
        XCTAssertEqual(bridge.mutationCallCount, 1)
    }

    @MainActor
    func testAppStoreNeverExecutesSemanticallyMismatchedQuestionEffects() async {
        let request = questionRequest()
        let answers = [
            GatewayQuestionAnswer(id: "direction", selected: ["架构"]),
            GatewayQuestionAnswer(id: "notes", selected: [], custom: "保持原生 UI")
        ]

        for mismatch in SemanticQuestionEffectMismatch.allCases {
            let bridge = SemanticMismatchQuestionBridge(request: request, mismatch: mismatch)
            let executor = GatewayQuestionEffectExecutorSpy()
            let backgroundApplication = BackgroundTaskApplicationSpy()
            let backgroundController = AgentBackgroundExecutionController(application: backgroundApplication)
            let store = AppStore(
                preferences: AppPreferencesSpy(
                    endpoint: "wss://injected.example/ws/mobile",
                    selectedWorkspaceID: nil,
                    sessions: []
                ),
                questionBridge: bridge,
                questionEffectExecutor: executor,
                backgroundExecutionController: backgroundController
            )

            store.answerQuestion(request, answers: answers)
            await flushDeferredKMPEvents(in: store)

            XCTAssertEqual(executor.answerCalls.count, 0, "\(mismatch)")
            XCTAssertEqual(executor.cancelCallCount, 0, "\(mismatch)")
            XCTAssertEqual(bridge.submitCallCount, 1, "\(mismatch)")
            XCTAssertNotNil(store.lastError, "\(mismatch)")
            XCTAssertFalse(backgroundController.isAgentWorkActive, "\(mismatch)")

            // 一次语义错配后永久 fail closed，后续 intent 不再进入 KMP bridge。
            store.answerQuestion(request, answers: answers)
            XCTAssertEqual(bridge.submitCallCount, 1, "\(mismatch)")
            XCTAssertEqual(executor.answerCalls.count, 0, "\(mismatch)")
        }
    }

    @MainActor
    func testAppStoreCoordinatesQuestionAllowanceAcrossTerminalRoutes() async throws {
        func makeStore() async -> (
            store: AppStore,
            controller: AgentBackgroundExecutionController,
            executor: GatewayQuestionEffectExecutorSpy,
            request: GatewayPendingQuestionRequest
        ) {
            let request = questionRequest()
            let controller = AgentBackgroundExecutionController(application: BackgroundTaskApplicationSpy())
            let executor = GatewayQuestionEffectExecutorSpy()
            let store = AppStore(
                preferences: AppPreferencesSpy(
                    endpoint: "wss://injected.example/ws/mobile",
                    selectedWorkspaceID: nil,
                    sessions: []
                ),
                questionBridge: QuestionLifecycleBridge(request: request),
                questionEffectExecutor: executor,
                backgroundExecutionController: controller
            )
            store.answerQuestion(request, answers: [
                GatewayQuestionAnswer(id: "direction", selected: ["架构"]),
                GatewayQuestionAnswer(id: "notes", selected: [], custom: "保持原生 UI")
            ])
            await flushDeferredKMPEvents(in: store)
            XCTAssertEqual(executor.answerCalls.count, 1)
            XCTAssertEqual(controller.questionAllowanceSessionIDs[request.rpcId], request.sessionId)
            XCTAssertEqual(controller.outstandingTurns, 0)
            return (store, controller, executor, request)
        }

        do {
            let fixture = await makeStore()
            fixture.store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
                #"{"kind":"question-response","rpcId":"rpc-question","action":"answer","accepted":false,"reason":"not-pending"}"#.utf8
            )))
            await flushDeferredKMPEvents(in: fixture.store)
            XCTAssertFalse(fixture.controller.isAgentWorkActive)
            XCTAssertEqual(fixture.controller.outstandingTurns, 0)
        }

        do {
            let fixture = await makeStore()
            fixture.store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
                #"{"kind":"question-response","rpcId":"rpc-question","action":"answer","accepted":false,"reason":"bad-response"}"#.utf8
            )))
            await flushDeferredKMPEvents(in: fixture.store)
            XCTAssertFalse(fixture.controller.isAgentWorkActive)
            XCTAssertEqual(fixture.controller.outstandingTurns, 0)
        }

        do {
            let fixture = await makeStore()
            fixture.store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
                #"{"kind":"error","requestType":"question-answer","rpcId":"rpc-question","sessionId":"session-question","code":"failed"}"#.utf8
            )))
            await flushDeferredKMPEvents(in: fixture.store)
            XCTAssertFalse(fixture.controller.isAgentWorkActive)
            XCTAssertEqual(fixture.controller.outstandingTurns, 0)
        }

        do {
            let fixture = await makeStore()
            fixture.store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
                #"{"kind":"hello","protocol":3,"capabilities":[],"authenticated":true,"clients":1}"#.utf8
            )))
            await flushDeferredKMPEvents(in: fixture.store)
            XCTAssertFalse(fixture.controller.isAgentWorkActive)
            XCTAssertEqual(fixture.controller.outstandingTurns, 0)
        }

        do {
            let fixture = await makeStore()
            fixture.store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
                #"{"kind":"question-response","rpcId":"rpc-question","action":"answer","accepted":true}"#.utf8
            )))
            await flushDeferredKMPEvents(in: fixture.store)
            XCTAssertTrue(fixture.controller.questionAllowanceSessionIDs.isEmpty)
            XCTAssertEqual(fixture.controller.outstandingTurns, 1)

            fixture.store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
                #"{"kind":"question-resolved","rpcId":"rpc-question","sessionId":"session-question","outcome":"answered"}"#.utf8
            )))
            await flushDeferredKMPEvents(in: fixture.store)
            XCTAssertEqual(fixture.controller.outstandingTurns, 1)
            fixture.controller.turnEnded(sessionID: fixture.request.sessionId)
            XCTAssertFalse(fixture.controller.isAgentWorkActive)
        }
    }

    @MainActor
    func testQuestionFailureWithoutRpcIDFailsAndReleasesAllRequestsInSession() async throws {
        let controller = AgentBackgroundExecutionController(application: BackgroundTaskApplicationSpy())
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            backgroundExecutionController: controller
        )
        for (rpcID, sessionID) in [("rpc-s1-a", "s1"), ("rpc-s1-b", "s1"), ("rpc-s2", "s2")] {
            store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
                #"{"kind":"question-requested","rpcId":"\#(rpcID)","sessionId":"\#(sessionID)","questions":[{"id":"q1","question":"继续？"}]}"#.utf8
            )))
            controller.beginQuestionAnswer(rpcID: rpcID, sessionID: sessionID)
        }

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"error","requestType":"question-answer","sessionId":"s1","code":"failed"}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)

        XCTAssertEqual(store.questionRequestStatuses["rpc-s1-a"], .rejected("failed"))
        XCTAssertEqual(store.questionRequestStatuses["rpc-s1-b"], .rejected("failed"))
        XCTAssertEqual(store.questionRequestStatuses["rpc-s2"], .idle)
        XCTAssertEqual(controller.questionAllowanceSessionIDs, ["rpc-s2": "s2"])
        XCTAssertEqual(store.pendingQuestionRequests.count, 3)
    }

    @MainActor
    func testAppStoreQuestionRoutePublishesKMPStateAndHelloResetsIt() async throws {
        let store = AppStore(preferences: AppPreferencesSpy(
            endpoint: "wss://injected.example/ws/mobile",
            selectedWorkspaceID: nil,
            sessions: []
        ))
        let requested = try GatewayWireDecoder.decode(Data(
            #"{"kind":"question-requested","rpcId":"rpc-app","sessionId":"s-app","questions":[{"id":"q1","question":"继续？","options":[{"label":"是"}]}]}"#.utf8
        ))
        store.gateway.onFrame?(requested)
        await flushDeferredKMPEvents(in: store)
        let request = try XCTUnwrap(store.pendingQuestionRequests.first)
        XCTAssertEqual(store.questionRequestStatuses[request.rpcId], .idle)

        store.answerQuestion(request, answers: [GatewayQuestionAnswer(id: "q1", selected: ["是"])])
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(
            store.questionRequestStatuses[request.rpcId],
            .rejected(String(localized: "q.rejected.ws.disconnected.answer", defaultValue: "WebSocket 已断开，重连后再提交答案。"))
        )

        let notPending = try GatewayWireDecoder.decode(Data(
            #"{"kind":"question-response","rpcId":"rpc-app","action":"answer","accepted":false,"reason":"not-pending"}"#.utf8
        ))
        store.gateway.onFrame?(notPending)
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(store.pendingQuestionRequests.isEmpty)
        XCTAssertNil(store.questionRequestStatuses[request.rpcId])

        store.gateway.onFrame?(requested)
        await flushDeferredKMPEvents(in: store)
        let hello = try GatewayWireDecoder.decode(Data(
            #"{"kind":"hello","protocol":3,"capabilities":[],"authenticated":true,"clients":1}"#.utf8
        ))
        store.gateway.onFrame?(hello)
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(store.pendingQuestionRequests.isEmpty)
        XCTAssertTrue(store.questionRequestStatuses.isEmpty)
    }

    @MainActor
    func testKMPSessionControlAdapterPublishesMutationThroughEventStream() {
        let adapter = KMPSessionControlStoreAdapter()
        var pushed: [KMPSessionControlTransition] = []
        adapter.onTransition = { pushed.append($0) }

        let returned = adapter.reduce(.requestModels(
            sessionID: "session-event",
            isConnected: true
        ))

        XCTAssertNotNil(adapter.lastEventSequence)
        XCTAssertEqual(adapter.lastEventSequence, 1)
        XCTAssertEqual(pushed.count, 1)
        XCTAssertEqual(pushed.first?.snapshot, returned.snapshot)
        XCTAssertEqual(pushed.first?.effects.first?.sessionId, "session-event")

        _ = adapter.reduce(.requestModels(sessionID: "session-event", isConnected: true))
        XCTAssertEqual(pushed.count, 1, "unchanged intent 不得重复推送 UI event")
    }

    @MainActor
    func testKMPPushAdaptersFailClosedBeforePublishingDuplicateSequence() {
        let sessionList = KMPSessionListStoreAdapter(sessions: [])
        let question = KMPQuestionStoreAdapter()
        let control = KMPSessionControlStoreAdapter()

        sessionList.receive(SharedMviEvent(
            schema: 2, sequence: sessionList.lastEventSequence ?? 0,
            transactionId: "duplicate-list", domain: "session-list", kind: "transition",
            statePayloadJson: nil, effectsJson: "[]", metadataJson: nil,
            errorCode: nil, errorMessage: nil
        ))
        question.receive(SharedMviEvent(
            schema: 2, sequence: question.lastEventSequence ?? 0,
            transactionId: "duplicate-question", domain: "question", kind: "transition",
            statePayloadJson: nil, effectsJson: "[]", metadataJson: nil,
            errorCode: nil, errorMessage: nil
        ))
        control.receive(SharedMviEvent(
            schema: 2, sequence: control.lastEventSequence ?? 0,
            transactionId: "duplicate-control", domain: "session-control", kind: "transition",
            statePayloadJson: nil, effectsJson: "[]", metadataJson: nil,
            errorCode: nil, errorMessage: nil
        ))

        XCTAssertFalse(sessionList.isOperational)
        XCTAssertFalse(question.isOperational)
        XCTAssertFalse(control.isOperational)
    }

    @MainActor
    func testKMPSessionControlAdapterOwnsStateAndEmitsRequestEffectOnce() {
        let adapter = KMPSessionControlStoreAdapter()

        var transition = adapter.reduce(.requestModels(sessionID: "session-1", isConnected: true))
        XCTAssertNil(transition.error)
        XCTAssertEqual(transition.effects.count, 1)
        XCTAssertEqual(transition.effects.first?.kind, "models")
        XCTAssertEqual(transition.effects.first?.sessionId, "session-1")
        XCTAssertEqual(
            transition.snapshot.requestTokens["models"],
            transition.effects.first?.requestToken
        )

        // 尚未完成的同 kind 请求不得再次生成网络 I/O。
        transition = adapter.reduce(.requestModels(sessionID: "session-2", isConnected: true))
        XCTAssertNil(transition.error)
        XCTAssertTrue(transition.effects.isEmpty)
        XCTAssertEqual(transition.snapshot.pendingModelsSessionId, "session-1")
        XCTAssertEqual(transition.snapshot.queuedRequestTargets["models"]?.sessionId, "session-2")

        let selected = GatewayModelSelection(provider: "openai", model: "gpt-5", reasoningEffort: "high")
        let modelsAction = KMPSessionControlAction.modelsReceived(
            sessionID: "session-1",
            current: selected,
            routable: true,
            groups: [],
            isGlobalRequest: false
        )
        transition = adapter.reduce(.action(modelsAction))
        XCTAssertEqual(transition.snapshot.modelCatalogs["session-1"]?.current, selected)
        XCTAssertEqual(transition.snapshot.modelCatalogs["session-1"]?.routable, true)
        XCTAssertEqual(transition.effects.first?.sessionId, "session-2")
        XCTAssertEqual(transition.snapshot.pendingModelsSessionId, "session-2")
        XCTAssertFalse(transition.snapshot.explicitSessionRequiredKinds.contains("models"))

        transition = adapter.reduce(.action(.modelsReceived(
            sessionID: "session-2",
            current: nil,
            routable: true,
            groups: [],
            isGlobalRequest: false
        )))
        XCTAssertTrue(transition.snapshot.loadingKinds.isEmpty)
        XCTAssertNil(transition.snapshot.requestTokens["models"])
        XCTAssertNil(transition.snapshot.pendingModelsSessionId)

        let permissions = GatewaySessionPermissions(
            options: [
                GatewayPermissionOption(value: "read-only", name: "Read"),
                GatewayPermissionOption(value: "future", name: "Future")
            ],
            currentValue: "read-only"
        )
        let permissionsAction = KMPSessionControlAction.permissionsReceived(
            sessionID: "session-1",
            permissions: permissions
        )
        _ = adapter.reduce(.requestPermissionOptions(sessionID: "session-1", isConnected: true))
        transition = adapter.reduce(.action(permissionsAction))
        XCTAssertEqual(transition.snapshot.sessionPermissions["session-1"]?.currentValue, "read-only")
        XCTAssertEqual(
            transition.snapshot.sessionPermissions["session-1"]?.options?.map(\.value),
            ["read-only", "future"]
        )
    }

    @MainActor
    func testKMPSessionControlAdapterMergesHistoryAndRealtimePartialSnapshots() {
        let adapter = KMPSessionControlStoreAdapter()
        _ = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-1",
            asOfSequence: 10,
            tokenUsage: GatewayTokenUsage(uncachedInputTokens: 12),
            pressure: nil,
            breakdown: GatewayContextBreakdown(systemTokens: 4)
        )))
        var transition = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-1",
            asOfSequence: nil,
            tokenUsage: nil,
            pressure: GatewayContextPressure(pressureTokens: 30, contextWindow: 100),
            breakdown: nil
        )))
        XCTAssertEqual(transition.snapshot.contextSnapshots["session-1"]?.asOfSeq, 10)
        XCTAssertEqual(
            transition.snapshot.contextSnapshots["session-1"]?.tokenUsage?.uncachedInputTokens,
            12
        )
        XCTAssertEqual(transition.snapshot.contextSnapshots["session-1"]?.pressure?.pressureTokens, 30)
        XCTAssertEqual(transition.snapshot.contextSnapshots["session-1"]?.breakdown?.systemTokens, 4)

        _ = adapter.reduce(.projection(.statsReceived(
            sessionID: "session-1",
            asOfSequence: 20,
            stats: GatewaySessionStats(turns: 2, steps: 5),
            tokenUsageTotals: GatewaySessionTokenUsageTotals(inputTokens: 100),
            contextPressure: nil
        )))
        transition = adapter.reduce(.projection(.statsReceived(
            sessionID: "session-1",
            asOfSequence: nil,
            stats: nil,
            tokenUsageTotals: nil,
            contextPressure: GatewayContextPressure(projectedTokens: 80, contextWindow: 1_000)
        )))
        XCTAssertEqual(transition.snapshot.sessionStatsSnapshots["session-1"]?.stats?.turns, 2)
        XCTAssertEqual(
            transition.snapshot.sessionStatsSnapshots["session-1"]?.tokenUsage?.totals?.inputTokens,
            100
        )
        XCTAssertEqual(
            transition.snapshot.sessionStatsSnapshots["session-1"]?.contextPressure?.projectedTokens,
            80
        )

        let largeSequence = Int(Int32.max) + 42
        transition = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-1",
            asOfSequence: largeSequence,
            tokenUsage: nil,
            pressure: nil,
            breakdown: nil
        )))
        XCTAssertEqual(transition.snapshot.contextSnapshots["session-1"]?.asOfSeq, largeSequence)
    }

    @MainActor
    func testKMPSessionControlPatchOnlyPublishesAffectedSessionAndSkipsUnchangedMutation() {
        let adapter = KMPSessionControlStoreAdapter()
        _ = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-a",
            asOfSequence: 1,
            tokenUsage: GatewayTokenUsage(uncachedInputTokens: 1),
            pressure: nil,
            breakdown: nil
        )))
        _ = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-b",
            asOfSequence: 2,
            tokenUsage: GatewayTokenUsage(uncachedInputTokens: 2),
            pressure: nil,
            breakdown: nil
        )))

        var transition = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-a",
            asOfSequence: 3,
            tokenUsage: nil,
            pressure: GatewayContextPressure(pressureTokens: 30, contextWindow: 100),
            breakdown: nil
        )))
        XCTAssertNil(transition.error)
        XCTAssertEqual(
            Set(transition.patch?.contextSnapshotsUpsert.keys.map { $0 } ?? []),
            ["session-a"]
        )
        XCTAssertTrue(transition.patch?.sessionStatsSnapshotsUpsert.isEmpty == true)
        XCTAssertEqual(transition.snapshot.contextSnapshots["session-b"]?.asOfSeq, 2)

        transition = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-a",
            asOfSequence: 3,
            tokenUsage: nil,
            pressure: GatewayContextPressure(pressureTokens: 30, contextWindow: 100),
            breakdown: nil
        )))
        XCTAssertNil(transition.error)
        XCTAssertTrue(transition.applied)
        XCTAssertFalse(transition.committed)
        XCTAssertNil(transition.patch)
    }

    @MainActor
    func testKMPSessionControlClearDrainsOldNilTerminalThenStartsQueuedTarget() {
        let adapter = KMPSessionControlStoreAdapter()
        let active = adapter.reduce(.requestModels(sessionID: "session-a", isConnected: true))
        _ = adapter.reduce(.requestModels(sessionID: "session-b", isConnected: true))

        let cleared = adapter.reduce(.clearSessionData(sessionID: "session-a"))
        XCTAssertNil(cleared.error)
        XCTAssertTrue(cleared.retiredRequestKinds.isEmpty)
        XCTAssertTrue(cleared.effects.isEmpty)
        XCTAssertEqual(active.effects.count, 1)
        XCTAssertEqual(cleared.snapshot.requestTokens["models"], active.effects.first?.requestToken)
        XCTAssertEqual(cleared.snapshot.activeRequestTargets["models"]?.sessionId, "session-a")
        XCTAssertEqual(cleared.snapshot.queuedRequestTargets["models"]?.sessionId, "session-b")
        XCTAssertTrue(cleared.snapshot.drainingRequestKinds.contains("models"))

        let drained = adapter.reduce(.action(.modelsReceived(
            sessionID: nil, current: nil, routable: true, groups: [], isGlobalRequest: false
        )))
        XCTAssertTrue(drained.applied)
        XCTAssertEqual(drained.effects.count, 1)
        XCTAssertEqual(drained.effects.first?.sessionId, "session-b")
        XCTAssertNil(drained.snapshot.modelCatalogs["session-a"])
        XCTAssertFalse(drained.snapshot.drainingRequestKinds.contains("models"))
        XCTAssertFalse(drained.snapshot.explicitSessionRequiredKinds.contains("models"))

        let completed = adapter.reduce(.action(.modelsReceived(
            sessionID: nil, current: nil, routable: true, groups: [], isGlobalRequest: false
        )))
        XCTAssertTrue(completed.applied)
        XCTAssertNil(completed.snapshot.activeRequestTargets["models"])
        XCTAssertNotNil(completed.snapshot.modelCatalogs["session-b"])
    }

    @MainActor
    func testKMPSessionControlPermissionOptionsNilTerminalUsesSameDrainBoundary() {
        let adapter = KMPSessionControlStoreAdapter()
        _ = adapter.reduce(.requestPermissionOptions(sessionID: "session-a", isConnected: true))
        _ = adapter.reduce(.requestPermissionOptions(sessionID: "session-b", isConnected: true))
        _ = adapter.reduce(.clearSessionData(sessionID: "session-a"))
        let permissions = GatewaySessionPermissions(
            options: [], currentValue: "read-only"
        )

        let drained = adapter.reduce(.action(.permissionsReceived(
            sessionID: nil, permissions: permissions
        )))
        XCTAssertEqual(drained.effects.first?.sessionId, "session-b")
        XCTAssertNil(drained.snapshot.sessionPermissions["session-a"])
        let completed = adapter.reduce(.action(.permissionsReceived(
            sessionID: nil, permissions: permissions
        )))
        XCTAssertTrue(completed.applied)
        XCTAssertEqual(completed.snapshot.sessionPermissions["session-b"]?.currentValue, "read-only")
    }

    @MainActor
    func testKMPSessionControlDrainingTimeoutQuarantinesWithoutQueuedIO() {
        let adapter = KMPSessionControlStoreAdapter()
        let active = adapter.reduce(.requestModels(sessionID: "session-a", isConnected: true))
        _ = adapter.reduce(.requestModels(sessionID: "session-b", isConnected: true))
        _ = adapter.reduce(.clearSessionData(sessionID: "session-a"))
        let token = active.effects.first!.requestToken

        let timedOut = adapter.reduce(.requestTimedOut(
            kind: "models", isDefault: false, requestToken: token
        ))
        XCTAssertNil(timedOut.error)
        XCTAssertTrue(timedOut.effects.isEmpty)
        XCTAssertNil(timedOut.snapshot.activeRequestTargets["models"])
        XCTAssertNil(timedOut.snapshot.queuedRequestTargets["models"])
        XCTAssertTrue(timedOut.snapshot.quarantinedRequestKinds.contains("models"))

        for sessionID in [nil, "session-a"] as [String?] {
            let late = adapter.reduce(.action(.modelsReceived(
                sessionID: sessionID, current: nil, routable: true, groups: [], isGlobalRequest: false
            )))
            XCTAssertFalse(late.applied)
            XCTAssertNil(late.snapshot.modelCatalogs["session-a"])
            XCTAssertTrue(late.effects.isEmpty)
        }
        let retry = adapter.reduce(.requestModels(sessionID: "session-b", isConnected: true))
        guard case .bridge(let code, _) = retry.error else {
            return XCTFail("quarantine 中不得发送 queued/retry 请求")
        }
        XCTAssertEqual(code, "request-quarantined")
        XCTAssertTrue(adapter.reduce(.requestsDisconnected).snapshot.quarantinedRequestKinds.isEmpty)
    }

    @MainActor
    func testKMPSessionControlBatchClearDropsAlsoClearedQueuedTargetWithoutEffect() {
        for sessionIDs in [Set(["session-a", "session-b"]), Set(["session-b", "session-a"])] {
            let adapter = KMPSessionControlStoreAdapter()
            _ = adapter.reduce(.requestModels(sessionID: "session-a", isConnected: true))
            _ = adapter.reduce(.requestModels(sessionID: "session-b", isConnected: true))

            let cleared = adapter.reduce(.clearSessionsData(sessionIDs: sessionIDs))
            XCTAssertNil(cleared.error)
            XCTAssertTrue(cleared.effects.isEmpty)
            XCTAssertEqual(cleared.snapshot.activeRequestTargets["models"]?.sessionId, "session-a")
            XCTAssertNil(cleared.snapshot.queuedRequestTargets["models"])
            XCTAssertTrue(cleared.snapshot.drainingRequestKinds.contains("models"))

            let drained = adapter.reduce(.action(.modelsReceived(
                sessionID: nil, current: nil, routable: true, groups: [], isGlobalRequest: false
            )))
            XCTAssertTrue(drained.effects.isEmpty)
            XCTAssertNil(drained.snapshot.activeRequestTargets["models"])
        }
    }

    @MainActor
    func testKMPSessionControlLegacyNoOpsDoNotRequestFullSnapshot() {
        let bridge = MalformedSessionControlBridge()
        let adapter = KMPSessionControlStoreAdapter(bridge: bridge)
        XCTAssertEqual(bridge.snapshotCallCount, 1)

        let resolved = adapter.reduce(.action(.modelSelectionResolved))
        let missingFinish = adapter.reduce(.action(.requestFinished("models")))
        XCTAssertNil(resolved.patch)
        XCTAssertNil(missingFinish.patch)
        XCTAssertFalse(resolved.committed)
        XCTAssertFalse(missingFinish.committed)
        XCTAssertEqual(bridge.snapshotCallCount, 1)
    }

    @MainActor
    func testKMPSessionControlPatchAppliesRemovalAndMalformedPatchFailsAtomically() {
        let adapter = KMPSessionControlStoreAdapter()
        _ = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-a", asOfSequence: 1,
            tokenUsage: nil, pressure: nil, breakdown: nil
        )))
        _ = adapter.reduce(.projection(.contextReceived(
            sessionID: "session-b", asOfSequence: 2,
            tokenUsage: nil, pressure: nil, breakdown: nil
        )))
        let removed = adapter.reduce(.clearSessionData(sessionID: "session-a"))
        XCTAssertNil(removed.error)
        XCTAssertNil(removed.snapshot.contextSnapshots["session-a"])
        XCTAssertEqual(removed.snapshot.contextSnapshots["session-b"]?.asOfSeq, 2)
        XCTAssertEqual(removed.patch?.contextSnapshotsRemove, ["session-a"])

        var malformed = KMPSessionControlPatch.empty
        malformed.contextSnapshotsUpsert = ["session-b": GatewayContextSnapshot(asOfSeq: 9)]
        let malformedAdapter = KMPSessionControlStoreAdapter(
            bridge: PatchQueueSessionControlBridge(patches: [malformed])
        )
        let original = malformedAdapter.snapshot
        let failed = malformedAdapter.reduce(.projection(.contextReceived(
            sessionID: "session-a", asOfSequence: nil,
            tokenUsage: nil, pressure: nil, breakdown: nil
        )))
        guard case .invalidPatch = failed.error else {
            return XCTFail("跨 session 注入必须以 invalidPatch fail-closed")
        }
        XCTAssertFalse(malformedAdapter.isOperational)
        XCTAssertEqual(failed.snapshot, original)
        XCTAssertTrue(failed.effects.isEmpty)
    }

    @MainActor
    func testKMPSessionControlClearRejectsPatchThatOmitsExistingRemoval() {
        let adapter = KMPSessionControlStoreAdapter(
            bridge: ClearOmissionSessionControlBridge()
        )
        let original = adapter.snapshot

        let transition = adapter.reduce(.clearSessionData(sessionID: "session-a"))

        guard case .invalidPatch = transition.error else {
            return XCTFail("clear patch 遗漏既有 session 数据 removal 必须 fail-closed")
        }
        XCTAssertEqual(transition.snapshot, original)
        XCTAssertNotNil(transition.snapshot.contextSnapshots["session-a"])
        XCTAssertTrue(transition.effects.isEmpty)
        XCTAssertFalse(adapter.isOperational)
    }

    @MainActor
    func testKMPSessionControlDrainRejectsBusinessProjectionFromTombstoneResponse() {
        let adapter = KMPSessionControlStoreAdapter(
            bridge: DrainBusinessInjectionSessionControlBridge()
        )
        let original = adapter.snapshot

        let transition = adapter.reduce(.action(.modelsReceived(
            sessionID: nil, current: nil, routable: true, groups: [], isGlobalRequest: false
        )))

        guard case .invalidPatch = transition.error else {
            return XCTFail("drain tombstone 终态携带业务 upsert 必须 fail-closed")
        }
        XCTAssertEqual(transition.snapshot, original)
        XCTAssertNil(transition.snapshot.modelCatalogs["session-a"])
        XCTAssertTrue(transition.effects.isEmpty)
        XCTAssertFalse(adapter.isOperational)
    }

    @MainActor
    func testKMPSessionControlPatchRejectsUnknownSchemaAndUnknownFields() throws {
        func encoded(_ patch: KMPSessionControlPatch, mutate: (inout [String: Any]) -> Void) throws -> String {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any]
            )
            mutate(&object)
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        var valid = KMPSessionControlPatch.empty
        valid.contextSnapshotsUpsert = ["session-a": GatewayContextSnapshot(asOfSeq: 1)]
        let payloads = [
            try encoded(valid) { $0["futureTopLevel"] = true },
            try encoded(valid) { object in
                var contexts = object["contextSnapshotsUpsert"] as! [String: Any]
                var context = contexts["session-a"] as! [String: Any]
                context["futureNested"] = 1
                contexts["session-a"] = context
                object["contextSnapshotsUpsert"] = contexts
            },
            try encoded({
                var patch = valid
                patch.schema = 3
                return patch
            }()) { _ in }
        ]

        for payload in payloads {
            let adapter = KMPSessionControlStoreAdapter(
                bridge: RawPatchSessionControlBridge(payload: payload)
            )
            let original = adapter.snapshot
            let transition = adapter.reduce(.projection(.contextReceived(
                sessionID: "session-a", asOfSequence: 1,
                tokenUsage: nil, pressure: nil, breakdown: nil
            )))
            guard case .invalidPatch = transition.error else {
                return XCTFail("未知 schema/字段必须以 invalidPatch fail-closed")
            }
            XCTAssertEqual(transition.snapshot, original)
            XCTAssertTrue(transition.effects.isEmpty)
            XCTAssertFalse(adapter.isOperational)
        }
    }

    @MainActor
    func testAppStoreArchiveClearsKMPControlStateAndRejectsLateResponse() async throws {
        let bridge = SharedSessionControlStore()
        _ = bridge.mergeContextProjection(
            sessionId: "session-a", asOfSequence: KotlinLong(longLong: 1),
            tokenUsageJson: nil, pressureJson: nil, breakdownJson: nil
        )
        _ = bridge.requestModels(sessionId: "session-a", isConnected: true)
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: [SessionSummary(
                    id: "session-a",
                    title: "A",
                    lastActivity: Date(timeIntervalSince1970: 1),
                    isRunning: false,
                    hasUnread: false
                )]
            ),
            sessionControlBridge: bridge
        )

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"workspaces","items":[],"archivedSessionIds":["session-a"]}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        var snapshot = try JSONDecoder().decode(
            KMPSessionControlSnapshot.self,
            from: Data(try XCTUnwrap(bridge.snapshot().snapshotJson).utf8)
        )
        XCTAssertNil(snapshot.contextSnapshots["session-a"])
        XCTAssertEqual(snapshot.activeRequestTargets["models"]?.sessionId, "session-a")
        XCTAssertNotNil(snapshot.requestTokens["models"])
        XCTAssertTrue(snapshot.drainingRequestKinds.contains("models"))

        _ = bridge.modelsReceived(
            sessionId: nil, currentJson: nil, routable: true,
            groupsJson: "[]", isGlobalRequest: false
        )
        snapshot = try JSONDecoder().decode(
            KMPSessionControlSnapshot.self,
            from: Data(try XCTUnwrap(bridge.snapshot().snapshotJson).utf8)
        )
        XCTAssertNil(snapshot.modelCatalogs["session-a"])
        XCTAssertNil(snapshot.activeRequestTargets["models"])
        XCTAssertFalse(snapshot.drainingRequestKinds.contains("models"))
    }

    @MainActor
    func testAppStoreBatchArchiveDrainsBeforeRoutingReplacementEffect() async throws {
        let bridge = SharedSessionControlStore()
        _ = bridge.requestModels(sessionId: "session-a", isConnected: true)
        _ = bridge.requestModels(sessionId: "session-b", isConnected: true)
        let executor = SessionControlEffectExecutorSpy()
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: [
                    SessionSummary(id: "session-a", title: "A", lastActivity: .now, isRunning: false, hasUnread: false),
                    SessionSummary(id: "session-b", title: "B", lastActivity: .now, isRunning: false, hasUnread: false)
                ]
            ),
            sessionControlBridge: bridge,
            sessionControlEffectExecutor: executor,
            chatHistoryCache: nil
        )

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"workspaces","items":[],"archivedSessionIds":["session-a"]}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(executor.modelsTargets.isEmpty)

        // A 的真实 nil-session 终态只解除 drain；随后才发送仍存活的 B。
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"models","groups":[],"routable":true}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertEqual(executor.modelsTargets, ["session-b"])
        XCTAssertNil(store.modelCatalogs["session-a"])

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"models","groups":[],"routable":true}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertNotNil(store.modelCatalogs["session-b"])
    }

    @MainActor
    func testAppStoreBatchArchiveDoesNotStartQueuedSessionAlsoInClearSet() async throws {
        let bridge = SharedSessionControlStore()
        _ = bridge.requestModels(sessionId: "session-a", isConnected: true)
        _ = bridge.requestModels(sessionId: "session-b", isConnected: true)
        let executor = SessionControlEffectExecutorSpy()
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: [
                    SessionSummary(id: "session-a", title: "A", lastActivity: .now, isRunning: false, hasUnread: false),
                    SessionSummary(id: "session-b", title: "B", lastActivity: .now, isRunning: false, hasUnread: false)
                ]
            ),
            sessionControlBridge: bridge,
            sessionControlEffectExecutor: executor
        )

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"workspaces","items":[],"archivedSessionIds":["session-b","session-a"]}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(executor.modelsTargets.isEmpty)
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"models","groups":[],"routable":true}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertTrue(executor.modelsTargets.isEmpty)
        XCTAssertNil(bridge.snapshot().snapshotJson.flatMap { Data($0.utf8) }.flatMap {
            try? JSONDecoder().decode(KMPSessionControlSnapshot.self, from: $0)
        }?.activeRequestTargets["models"])
    }

    @MainActor
    func testKMPSessionControlRepeatedLegacyResponsesRemainOperational() {
        let adapter = KMPSessionControlStoreAdapter()
        let permissions = GatewaySessionPermissions(
            options: [GatewayPermissionOption(value: "read-only", name: "Read")],
            currentValue: "read-only"
        )

        _ = adapter.reduce(.requestModels(sessionID: "session-1", isConnected: true))
        _ = adapter.reduce(.action(.modelsReceived(
            sessionID: nil,
            current: nil,
            routable: true,
            groups: [],
            isGlobalRequest: false
        )))
        var transition = adapter.reduce(.requestModels(sessionID: "session-1", isConnected: true))
        XCTAssertNil(transition.error)
        XCTAssertFalse(transition.snapshot.explicitSessionRequiredKinds.contains("models"))
        transition = adapter.reduce(.action(.modelsReceived(
            sessionID: nil,
            current: nil,
            routable: true,
            groups: [],
            isGlobalRequest: false
        )))
        XCTAssertNil(transition.error)

        _ = adapter.reduce(.requestPermissionOptions(sessionID: "session-1", isConnected: true))
        _ = adapter.reduce(.action(.permissionsReceived(sessionID: nil, permissions: permissions)))
        transition = adapter.reduce(.requestPermissionOptions(sessionID: "session-1", isConnected: true))
        XCTAssertNil(transition.error)
        XCTAssertFalse(transition.snapshot.explicitSessionRequiredKinds.contains("permission-options"))
        transition = adapter.reduce(.action(.permissionsReceived(sessionID: nil, permissions: permissions)))
        XCTAssertNil(transition.error)
        XCTAssertTrue(adapter.isOperational)
        XCTAssertFalse(transition.snapshot.loadingKinds.contains("permission-options"))
    }

    @MainActor
    func testKMPSessionControlTimeoutKeepsSnapshotInvariantValidAndAllowsRetry() {
        let adapter = KMPSessionControlStoreAdapter()
        _ = adapter.reduce(.requestModels(sessionID: "session-a", isConnected: true))
        _ = adapter.reduce(.action(.modelsReceived(
            sessionID: "session-a",
            current: nil,
            routable: true,
            groups: [],
            isGlobalRequest: false
        )))
        let started = adapter.reduce(.requestModels(sessionID: "session-b", isConnected: true))
        let token = try! XCTUnwrap(started.snapshot.requestTokens["models"])
        XCTAssertFalse(started.snapshot.explicitSessionRequiredKinds.contains("models"))

        let timedOut = adapter.reduce(.requestTimedOut(
            kind: "models",
            isDefault: false,
            requestToken: token
        ))
        XCTAssertNil(timedOut.error)
        XCTAssertTrue(adapter.isOperational)
        XCTAssertFalse(timedOut.snapshot.quarantinedRequestKinds.contains("models"))
        XCTAssertFalse(timedOut.snapshot.explicitSessionRequiredKinds.contains("models"))
        XCTAssertNil(timedOut.snapshot.activeRequestTargets["models"])

        let retried = adapter.reduce(.requestModels(sessionID: "session-b", isConnected: true))
        XCTAssertNil(retried.error)
        XCTAssertEqual(retried.effects.first?.sessionId, "session-b")

        let permissionStarted = adapter.reduce(
            .requestPermissionOptions(sessionID: "session-b", isConnected: true)
        )
        let permissionToken = try! XCTUnwrap(
            permissionStarted.snapshot.requestTokens["permission-options"]
        )
        let permissionTimedOut = adapter.reduce(.requestTimedOut(
            kind: "permission-options",
            isDefault: false,
            requestToken: permissionToken
        ))
        XCTAssertFalse(
            permissionTimedOut.snapshot.quarantinedRequestKinds.contains("permission-options")
        )
        XCTAssertEqual(
            adapter.reduce(.requestPermissionOptions(
                sessionID: "session-b",
                isConnected: true
            )).effects.first?.sessionId,
            "session-b"
        )
    }

    @MainActor
    func testKMPSessionControlAdapterPermanentlyFailsClosedAfterMalformedCommittedSnapshot() {
        let bridge = MalformedSessionControlBridge()
        let adapter = KMPSessionControlStoreAdapter(bridge: bridge)
        XCTAssertTrue(adapter.isOperational)

        var transition = adapter.reduce(.requestModels(sessionID: "session-1", isConnected: true))
        guard case .invalidPatch = transition.error else {
            return XCTFail("结构缺失的已提交 payload 必须报 invalidPatch")
        }
        XCTAssertTrue(transition.effects.isEmpty)
        XCTAssertFalse(adapter.isOperational)
        XCTAssertEqual(bridge.requestCallCount, 1)

        transition = adapter.reduce(.requestModels(sessionID: "session-2", isConnected: true))
        XCTAssertNotNil(transition.error)
        XCTAssertTrue(transition.effects.isEmpty)
        XCTAssertEqual(bridge.requestCallCount, 1)
    }

    @MainActor
    func testKMPSessionControlAdapterPermanentlyFailsClosedOnInconsistentResultSignals() {
        for defect in InvalidSessionControlResultBridge.Defect.allCases {
            let bridge = InvalidSessionControlResultBridge(defect: defect)
            let adapter = KMPSessionControlStoreAdapter(bridge: bridge)
            let original = adapter.snapshot

            var transition = adapter.reduce(.requestModels(sessionID: "session-1", isConnected: true))
            switch defect {
            case .uncommittedSnapshotMutation, .committedWithoutMutation:
                guard case .invalidPatch = transition.error else {
                    XCTFail("\(defect) 必须报 invalidPatch")
                    continue
                }
            case .effectWithoutApplied, .inconsistentCompletion:
                guard case .invalidSnapshot = transition.error else {
                    XCTFail("\(defect) 必须报 invalidSnapshot")
                    continue
                }
            }
            XCTAssertTrue(transition.effects.isEmpty, "\(defect)")
            XCTAssertEqual(transition.snapshot, original, "\(defect)")
            XCTAssertFalse(adapter.isOperational, "\(defect)")

            transition = adapter.reduce(.requestModels(sessionID: "session-2", isConnected: true))
            XCTAssertNotNil(transition.error, "\(defect)")
            XCTAssertTrue(transition.effects.isEmpty, "\(defect)")
            XCTAssertEqual(bridge.requestCallCount, 1, "\(defect)")
        }
    }

    @MainActor
    func testKMPSessionControlRejectsSemanticEffectBeforeAppStoreIO() {
        let executor = SessionControlEffectExecutorSpy()
        let appStore = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlEffectExecutor: executor
        )

        let normal = KMPSessionControlStoreAdapter().reduce(
            .requestModels(sessionID: "session-1", isConnected: true)
        )
        XCTAssertNil(normal.error)
        normal.effects.forEach(appStore.executeSessionControlEffect)
        XCTAssertEqual(executor.modelsTargets, ["session-1"])

        let invalidAdapter = KMPSessionControlStoreAdapter(bridge: SemanticInvalidSessionControlEffectBridge())
        let invalid = invalidAdapter.reduce(.requestModels(sessionID: "session-1", isConnected: true))
        guard case .invalidEffect = invalid.error else {
            return XCTFail("语义不匹配 effect 必须报 invalidEffect")
        }
        XCTAssertTrue(invalid.effects.isEmpty)
        invalid.effects.forEach(appStore.executeSessionControlEffect)
        XCTAssertEqual(executor.modelsTargets, ["session-1"])
    }

    @MainActor
    func testKMPSessionControlRejectsIntentSmugglingMissingPayloadAndProjectionEffect() {
        var transition = KMPSessionControlStoreAdapter(
            bridge: IntentSmugglingSessionControlBridge()
        ).reduce(.requestModels(sessionID: "session-1", isConnected: true))
        guard case .invalidEffect = transition.error else {
            return XCTFail("跨 session 请求 effect 必须以 invalidEffect fail-closed")
        }
        XCTAssertTrue(transition.effects.isEmpty)

        let selection = GatewayModelSelection(provider: "openai", model: "gpt-5")
        transition = KMPSessionControlStoreAdapter(
            bridge: MissingPayloadSessionControlBridge()
        ).reduce(.selectModel(sessionID: "session-1", selection: selection, isConnected: true))
        guard case .invalidEffect = transition.error else {
            return XCTFail("缺失 intent payload 的 effect 必须以 invalidEffect fail-closed")
        }
        XCTAssertTrue(transition.effects.isEmpty)

        transition = KMPSessionControlStoreAdapter(
            bridge: ProjectionSmugglingSessionControlBridge()
        ).reduce(.projection(.contextReceived(
            sessionID: "session-1",
            asOfSequence: 1,
            tokenUsage: nil,
            pressure: nil,
            breakdown: nil
        )))
        guard case .invalidEffect = transition.error else {
            return XCTFail("projection 携带平台 effect 必须以 invalidEffect fail-closed")
        }
        XCTAssertTrue(transition.effects.isEmpty)
    }

    @MainActor
    func testKMPSessionControlRejectsCrossKindControlInjectionBeforePublishAndIO() {
        let bridge = ControlCrossKindSmugglingSessionControlBridge()
        let adapter = KMPSessionControlStoreAdapter(bridge: bridge)
        let original = adapter.snapshot
        let executor = SessionControlEffectExecutorSpy()

        let transition = adapter.reduce(.requestModels(sessionID: "session-1", isConnected: true))
        guard case .invalidPatch = transition.error else {
            return XCTFail("当前 models intent 不得修改 permission-options control 字段")
        }
        XCTAssertEqual(transition.snapshot, original)
        XCTAssertEqual(adapter.snapshot, original)
        XCTAssertTrue(transition.effects.isEmpty)
        transition.effects.forEach { effect in
            if effect.kind == "models" { executor.requestModels(sessionId: effect.sessionId) }
        }
        XCTAssertTrue(executor.modelsTargets.isEmpty)
        XCTAssertFalse(adapter.isOperational)
    }

    @MainActor
    func testNegativeControlResponseImmediatelyCompletesCurrentGeneration() async throws {
        let bridge = SharedSessionControlStore()
        let selection = GatewayModelSelection(provider: "openai", model: "gpt-5")
        _ = bridge.selectModel(
            sessionId: "session-1",
            selectionJson: String(decoding: try JSONEncoder().encode(selection), as: UTF8.self),
            isConnected: true
        )
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: bridge
        )
        XCTAssertTrue(store.sessionControlLoadingKinds.contains("select-model"))

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"select-model","sessionId":"session-1"}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)

        XCTAssertFalse(store.sessionControlLoadingKinds.contains("select-model"))
        let snapshot = try JSONDecoder().decode(
            KMPSessionControlSnapshot.self,
            from: Data(bridge.snapshot().snapshotJson!.utf8)
        )
        XCTAssertNil(snapshot.requestTokens["select-model"])
    }

    @MainActor
    func testHelloResetsPreviousConnectionGenerationBeforeRefresh() throws {
        let bridge = SharedSessionControlStore()
        let old = bridge.requestModels(sessionId: "old-session", isConnected: true)
        let oldToken = try JSONDecoder().decode(
            [KMPSessionControlEffect].self,
            from: Data(old.effectsJson.utf8)
        ).first!.requestToken
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: bridge
        )

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"hello","protocol":3,"capabilities":[],"authenticated":true,"clients":1}"#.utf8
        )))

        let snapshot = try JSONDecoder().decode(
            KMPSessionControlSnapshot.self,
            from: Data(bridge.snapshot().snapshotJson!.utf8)
        )
        XCTAssertNotEqual(snapshot.requestTokens["models"], oldToken)
        XCTAssertNil(snapshot.activeRequestTargets["models"]?.sessionId)
        XCTAssertTrue(snapshot.previousCompletedRequestTargets.isEmpty)
    }

    @MainActor
    func testLegacyNilResponseFinishesOnlyTheCurrentNormalGeneration() throws {
        let bridge = SharedSessionControlStore()
        _ = bridge.requestModels(sessionId: "session-a", isConnected: true)
        _ = bridge.modelsReceived(
            sessionId: "session-a",
            currentJson: nil,
            routable: true,
            groupsJson: "[]",
            isGlobalRequest: false
        )
        let second = bridge.requestModels(sessionId: "session-b", isConnected: true)
        let secondToken = try JSONDecoder().decode(
            [KMPSessionControlEffect].self,
            from: Data(second.effectsJson.utf8)
        ).first!.requestToken
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: bridge
        )

        // 显式回显的旧 session 不能结束当前 generation。
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"models","sessionId":"session-a","groups":[]}"#.utf8
        )))
        var snapshot = try JSONDecoder().decode(
            KMPSessionControlSnapshot.self,
            from: Data(bridge.snapshot().snapshotJson!.utf8)
        )
        XCTAssertEqual(snapshot.requestTokens["models"], secondToken)

        // 真实 Gateway 的 models 帧不回显 sessionId，绑定当前唯一 active request。
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"models","groups":[]}"#.utf8
        )))
        snapshot = try JSONDecoder().decode(
            KMPSessionControlSnapshot.self,
            from: Data(bridge.snapshot().snapshotJson!.utf8)
        )
        XCTAssertNil(snapshot.requestTokens["models"])
    }

    @MainActor
    func testCorrelatedNegativeDefaultResponseFinishesWithoutWaitingForTimeout() async throws {
        let bridge = SharedSessionControlStore()
        _ = bridge.setDefault(target: "permission", value: "read-only", isConnected: true)
        _ = bridge.globalDefaultApplied(target: "permission", value: "read-only")
        _ = bridge.setDefault(target: "permission", value: "workspace-write", isConnected: true)
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: bridge
        )
        XCTAssertTrue(store.defaultConfigurationLoadingKinds.contains("set-default"))

        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"set-default","applied":false,"target":"permission","value":"workspace-write"}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)

        XCTAssertFalse(store.defaultConfigurationLoadingKinds.contains("set-default"))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.protocolNotices.last?.isError, true)
        let snapshot = try JSONDecoder().decode(
            KMPSessionControlSnapshot.self,
            from: Data(bridge.snapshot().snapshotJson!.utf8)
        )
        XCTAssertNil(snapshot.requestTokens["set-default"])
    }

    @MainActor
    func testTokenlessNegativeDefaultResponsesFinishTheOnlyActiveGeneration() async throws {
        let selection = GatewayModelSelection(provider: "openai", model: "gpt-5")
        let selectionJSON = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)

        let saveBridge = SharedSessionControlStore()
        _ = saveBridge.saveDefaultModel(selectionJson: selectionJSON, isConnected: true)
        _ = saveBridge.defaultModelSaved(selectionJson: selectionJSON)
        _ = saveBridge.saveDefaultModel(selectionJson: selectionJSON, isConnected: true)
        let saveStore = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: saveBridge
        )
        saveStore.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"save-default-model"}"#.utf8
        )))
        await flushDeferredKMPEvents(in: saveStore)
        XCTAssertFalse(saveStore.defaultConfigurationLoadingKinds.contains("save-default-model"))
        XCTAssertNotNil(saveStore.lastError)
        XCTAssertEqual(saveStore.protocolNotices.last?.isError, true)

        let defaultBridge = SharedSessionControlStore()
        _ = defaultBridge.setDefault(target: "permission", value: "read-only", isConnected: true)
        _ = defaultBridge.globalDefaultApplied(target: "permission", value: "read-only")
        _ = defaultBridge.setDefault(target: "permission", value: "read-only", isConnected: true)
        let defaultStore = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: defaultBridge
        )
        defaultStore.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"set-default","applied":false,"target":"permission","value":"read-only"}"#.utf8
        )))
        await flushDeferredKMPEvents(in: defaultStore)
        XCTAssertFalse(defaultStore.defaultConfigurationLoadingKinds.contains("set-default"))
        XCTAssertNotNil(defaultStore.lastError)
        XCTAssertEqual(defaultStore.protocolNotices.last?.isError, true)
    }

    @MainActor
    func testAgentPresetTimeoutAndDisconnectedRetryStayInline() async throws {
        let bridge = SharedSessionControlStore()
        let adapter = KMPSessionControlStoreAdapter(bridge: bridge)
        let request = adapter.reduce(.requestAgentPresets(isConnected: true))
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: bridge,
            sessionControlEffectExecutor: SessionControlEffectExecutorSpy()
        )
        request.effects.forEach(store.executeSessionControlEffect)
        try await Task.sleep(for: .seconds(13))
        XCTAssertNotNil(store.agentPresetsLoadError)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.defaultConfigurationLoadingKinds.contains("agent-presets"))

        store.retryAgentPresets()
        XCTAssertNotNil(store.agentPresetsLoadError)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testAgentPresetResponseCompletesWithoutAlert() async throws {
        let bridge = SharedSessionControlStore()
        _ = bridge.requestAgentPresets(isConnected: true)
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlBridge: bridge,
            sessionControlEffectExecutor: SessionControlEffectExecutorSpy()
        )
        store.retryAgentPresets()
        XCTAssertNotNil(store.agentPresetsLoadError)
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"agent-presets","presets":[{"id":"standard","isDefault":true}]}"#.utf8
        )))
        await flushDeferredKMPEvents(in: store)
        XCTAssertNil(store.agentPresetsLoadError)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.agentPresets.first?.id, "standard")
        XCTAssertFalse(store.defaultConfigurationLoadingKinds.contains("agent-presets"))
    }

    @MainActor
    func testAppStoreIgnoresUncorrelatedSessionControlResponses() throws {
        let executor = SessionControlEffectExecutorSpy()
        let store = AppStore(
            preferences: AppPreferencesSpy(
                endpoint: "wss://injected.example/ws/mobile",
                selectedWorkspaceID: nil,
                sessions: []
            ),
            sessionControlEffectExecutor: executor
        )
        let frames = [
            #"{"kind":"agent-presets","presets":[{"id":"standard","isDefault":true}],"authorable":true,"hasDocument":true}"#,
            #"{"kind":"defaults","agentPresetDefault":"standard","permissionDefault":"workspace-write"}"#,
            #"{"kind":"models","sessionId":"session-1","current":{"provider":"openai","model":"gpt-5"},"routable":true,"groups":[]}"#,
            #"{"kind":"permission-options","sessionId":"session-1","sessionPermissions":{"options":[{"value":"read-only","name":"Read"},{"value":"future","name":"Future"}],"currentValue":"read-only"}}"#,
            #"{"kind":"context-usage","sessionId":"session-1","asOfSeq":10,"tokenUsage":{"uncachedInputTokens":12}}"#,
            #"{"kind":"session-stats","sessionId":"session-1","asOfSeq":20,"sessionStats":{"turns":2},"tokenUsage":{"totals":{"inputTokens":100}}}"#,
            #"{"kind":"set-default","applied":true,"target":"permission","value":"workspace-write"}"#
        ]
        for json in frames {
            store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(json.utf8)))
        }

        XCTAssertTrue(store.agentPresets.isEmpty)
        XCTAssertNil(store.agentPresetDefault)
        XCTAssertNil(store.permissionDefault)
        XCTAssertTrue(store.modelCatalogs.isEmpty)
        XCTAssertTrue(store.sessionPermissions.isEmpty)
        XCTAssertTrue(store.contextSnapshots.isEmpty)
        XCTAssertTrue(store.sessionStatsSnapshots.isEmpty)
        XCTAssertEqual(executor.defaultsRequestCount, 0)
        XCTAssertTrue(store.protocolNotices.isEmpty)
    }

    @MainActor
    func testRequestTrackerFiresOnlyLatestGeneration() async throws {
        let tracker = RequestTracker()
        var timeouts: [String] = []
        tracker.begin("models", timeout: .milliseconds(10)) { timeouts.append("stale") }
        tracker.begin("models", timeout: .milliseconds(30)) { timeouts.append("latest") }

        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(timeouts, ["latest"])
        XCTAssertTrue(tracker.activeKeys.isEmpty)
    }

    @MainActor
    func testRequestTrackerFinishAndFinishAllCancelTimeouts() async throws {
        let tracker = RequestTracker()
        var timeoutCount = 0
        tracker.begin("models", timeout: .milliseconds(20)) { timeoutCount += 1 }
        tracker.begin("stats", timeout: .milliseconds(20)) { timeoutCount += 1 }
        tracker.finish("models")
        tracker.finishAll()

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(timeoutCount, 0)
        XCTAssertTrue(tracker.activeKeys.isEmpty)
    }

    @MainActor
    func testHistorySyncEngineInvalidatesLateGenerationsAndTimeouts() async throws {
        let engine = HistorySyncEngine()
        var timeoutCount = 0
        engine.beginRequest(sessionID: "session-1", timeout: .milliseconds(100)) {
            timeoutCount += 1
        }
        let processing = engine.beginProcessing(sessionID: "session-1")
        XCTAssertTrue(engine.isCurrent(processing, sessionID: "session-1"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(timeoutCount, 0)

        engine.beginRequest(sessionID: "session-1", timeout: .milliseconds(100)) {
            timeoutCount += 1
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(timeoutCount, 1)
        XCTAssertFalse(engine.isActive(sessionID: "session-1"))
    }

    func testQuestionAnswerTrimsCustomText() {
        let answer = GatewayQuestionAnswer(id: "custom", selected: [], custom: "  自定义回答  ")
        XCTAssertEqual(answer.custom, "自定义回答")
        XCTAssertNil(GatewayQuestionAnswer(id: "empty", selected: [], custom: "  \n ").custom)
    }

    private func questionRequest() -> GatewayPendingQuestionRequest {
        GatewayPendingQuestionRequest(
            rpcId: "rpc-question",
            sessionId: "session-question",
            questions: [
                GatewayQuestion(
                    id: "direction",
                    question: "研究方向",
                    options: [
                        GatewayQuestionOption(label: "架构"),
                        GatewayQuestionOption(label: "界面")
                    ],
                    multiSelect: true
                ),
                GatewayQuestion(
                    id: "notes",
                    question: "补充要求",
                    options: [GatewayQuestionOption(label: "简洁")],
                    multiSelect: false
                )
            ],
            replay: false
        )
    }

    private func pairingPayloadString(
        version: Int = 2,
        publicURL: String = "ws://gateway.example:3080/ws/mobile",
        pairingCode: String = "one-time-code",
        expiresAt: Double = 4_102_444_800_000
    ) throws -> String {
        let payload = GatewayPairingPayload(
            version: version,
            publicUrl: publicURL,
            pairingCode: pairingCode,
            expiresAt: expiresAt
        )
        return base64URL(try JSONEncoder().encode(payload))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class SessionControlEffectExecutorSpy: GatewaySessionControlEffectExecuting {
    private(set) var modelsTargets: [String?] = []
    private(set) var defaultsRequestCount = 0
    func requestModels(sessionId: String?) { modelsTargets.append(sessionId) }
    func requestPermissionOptions(sessionId: String?) {}
    func requestContextUsage(sessionId: String) {}
    func requestSessionStats(sessionId: String) {}
    func requestAgentPresets() {}
    func requestDefaults() { defaultsRequestCount += 1 }
    func requestDefaultModel() {}
    func selectModel(sessionId: String, provider: String, model: String, reasoningEffort: String?) {}
    func setPermission(sessionId: String, name: String) {}
    func saveDefaultModel(provider: String, model: String, reasoningEffort: String?) {}
    func setDefault(target: String, value: String) {}
}

private final class IntentSmugglingSessionControlBridge: MalformedSessionControlBridge {
    override func requestModels(sessionId: String?, isConnected: Bool) -> SharedSessionControlResult {
        forgedRequestResult(target: .init(kind: "models", isDefault: false, sessionId: "session-2"))
    }
}

private final class MissingPayloadSessionControlBridge: MalformedSessionControlBridge {
    override func selectModel(
        sessionId: String,
        selectionJson: String,
        isConnected: Bool
    ) -> SharedSessionControlResult {
        forgedRequestResult(
            target: .init(
                kind: "select-model",
                isDefault: false,
                sessionId: sessionId,
                provider: "openai",
                model: "gpt-5"
            ),
            effectTarget: .init(
                kind: "select-model",
                isDefault: false,
                sessionId: sessionId,
                provider: "openai",
                model: nil
            )
        )
    }
}

private final class ProjectionSmugglingSessionControlBridge: MalformedSessionControlBridge {
    override func mergeContextProjection(
        sessionId: String,
        asOfSequence: KotlinLong?,
        tokenUsageJson: String?,
        pressureJson: String?,
        breakdownJson: String?
    ) -> SharedSessionControlResult {
        forgedRequestResult(target: .init(kind: "context-usage", isDefault: false, sessionId: sessionId))
    }
}

private final class ControlCrossKindSmugglingSessionControlBridge: MalformedSessionControlBridge {
    override func requestModels(sessionId: String?, isConnected: Bool) -> SharedSessionControlResult {
        let models = KMPSessionControlRequestTarget(
            kind: "models", isDefault: false, sessionId: sessionId
        )
        let permissions = KMPSessionControlRequestTarget(
            kind: "permission-options", isDefault: false, sessionId: "session-2"
        )
        var snapshot = KMPSessionControlSnapshot.empty
        snapshot.loadingKinds = ["models", "permission-options"]
        snapshot.pendingModelsSessionId = sessionId
        snapshot.pendingPermissionOptionsSessionId = "session-2"
        snapshot.requestTokens = ["models": "models:1", "permission-options": "permission-options:1"]
        snapshot.activeRequestTargets = ["models": models, "permission-options": permissions]
        var patch = KMPSessionControlPatch.empty
        patch.control = snapshot.controlPatch
        let effect = KMPSessionControlEffect(
            kind: "models", requestKey: "models", requestToken: "models:1",
            sessionId: sessionId, provider: nil, model: nil, reasoningEffort: nil,
            target: nil, value: nil
        )
        return SharedSessionControlResult(
            snapshotJson: Self.encode(patch),
            effectsJson: Self.encode([effect]),
            errorCode: nil,
            errorMessage: nil,
            applied: true,
            committed: true,
            completedKind: nil,
            completedRequestToken: nil
        )
    }
}

private final class PatchQueueSessionControlBridge: MalformedSessionControlBridge {
    private var patches: [KMPSessionControlPatch]

    init(patches: [KMPSessionControlPatch]) {
        self.patches = patches
    }

    override func mergeContextProjection(
        sessionId: String,
        asOfSequence: KotlinLong?,
        tokenUsageJson: String?,
        pressureJson: String?,
        breakdownJson: String?
    ) -> SharedSessionControlResult {
        guard !patches.isEmpty else { return unimplemented() }
        return SharedSessionControlResult(
            snapshotJson: Self.encode(patches.removeFirst()),
            effectsJson: "[]",
            errorCode: nil,
            errorMessage: nil,
            applied: true,
            committed: true,
            completedKind: nil,
            completedRequestToken: nil
        )
    }
}

private final class ClearOmissionSessionControlBridge: MalformedSessionControlBridge {
    private let initial: KMPSessionControlSnapshot = {
        var snapshot = KMPSessionControlSnapshot.empty
        let target = KMPSessionControlRequestTarget(
            kind: "models", isDefault: false, sessionId: "session-a"
        )
        snapshot.contextSnapshots["session-a"] = GatewayContextSnapshot(asOfSeq: 1)
        snapshot.loadingKinds = ["models"]
        snapshot.pendingModelsSessionId = "session-a"
        snapshot.requestTokens = ["models": "models:1"]
        snapshot.activeRequestTargets = ["models": target]
        return snapshot
    }()

    override func snapshot() -> SharedSessionControlResult {
        SharedSessionControlResult(
            snapshotJson: MalformedSessionControlBridge.encode(initial),
            effectsJson: "[]", errorCode: nil, errorMessage: nil,
            applied: false, committed: false,
            completedKind: nil, completedRequestToken: nil
        )
    }

    override func clearSessionData(sessionId: String) -> SharedSessionControlResult {
        var next = initial
        next.drainingRequestKinds = ["models"]
        var patch = KMPSessionControlPatch.empty
        // 故意遗漏 contextSnapshotsRemove，模拟损坏/不兼容 KMP bridge。
        patch.control = next.controlPatch
        return SharedSessionControlResult(
            snapshotJson: MalformedSessionControlBridge.encode(patch),
            effectsJson: "[]", errorCode: nil, errorMessage: nil,
            applied: true, committed: true,
            completedKind: nil, completedRequestToken: nil
        )
    }
}

private final class DrainBusinessInjectionSessionControlBridge: MalformedSessionControlBridge {
    private let initial: KMPSessionControlSnapshot = {
        var snapshot = KMPSessionControlSnapshot.empty
        let active = KMPSessionControlRequestTarget(
            kind: "models", isDefault: false, sessionId: "session-a"
        )
        let queued = KMPSessionControlRequestTarget(
            kind: "models", isDefault: false, sessionId: "session-b"
        )
        snapshot.loadingKinds = ["models"]
        snapshot.pendingModelsSessionId = "session-a"
        snapshot.requestTokens = ["models": "models:1"]
        snapshot.activeRequestTargets = ["models": active]
        snapshot.queuedRequestTargets = ["models": queued]
        snapshot.drainingRequestKinds = ["models"]
        return snapshot
    }()

    override func snapshot() -> SharedSessionControlResult {
        SharedSessionControlResult(
            snapshotJson: MalformedSessionControlBridge.encode(initial),
            effectsJson: "[]", errorCode: nil, errorMessage: nil,
            applied: false, committed: false,
            completedKind: nil, completedRequestToken: nil
        )
    }

    override func modelsReceived(
        sessionId: String?, currentJson: String?, routable: Bool,
        groupsJson: String, isGlobalRequest: Bool
    ) -> SharedSessionControlResult {
        let replacement = KMPSessionControlRequestTarget(
            kind: "models", isDefault: false, sessionId: "session-b"
        )
        var next = KMPSessionControlSnapshot.empty
        next.loadingKinds = ["models"]
        next.pendingModelsSessionId = "session-b"
        next.requestTokens = ["models": "models:2"]
        next.activeRequestTargets = ["models": replacement]
        var patch = KMPSessionControlPatch.empty
        // 故意在 tombstone 终态重新注入已清理 A 的业务数据。
        patch.modelCatalogsUpsert["session-a"] = GatewayModelCatalog(
            current: nil, routable: true, groups: []
        )
        patch.control = next.controlPatch
        let effect = KMPSessionControlEffect(
            kind: "models", requestKey: "models", requestToken: "models:2",
            sessionId: "session-b", provider: nil, model: nil,
            reasoningEffort: nil, target: nil, value: nil
        )
        return SharedSessionControlResult(
            snapshotJson: MalformedSessionControlBridge.encode(patch),
            effectsJson: MalformedSessionControlBridge.encode([effect]),
            errorCode: nil, errorMessage: nil,
            applied: true, committed: true,
            completedKind: "models", completedRequestToken: "models:1"
        )
    }
}

private final class RawPatchSessionControlBridge: MalformedSessionControlBridge {
    private let payload: String

    init(payload: String) {
        self.payload = payload
    }

    override func mergeContextProjection(
        sessionId: String,
        asOfSequence: KotlinLong?,
        tokenUsageJson: String?,
        pressureJson: String?,
        breakdownJson: String?
    ) -> SharedSessionControlResult {
        SharedSessionControlResult(
            snapshotJson: payload,
            effectsJson: "[]",
            errorCode: nil,
            errorMessage: nil,
            applied: true,
            committed: true,
            completedKind: nil,
            completedRequestToken: nil
        )
    }
}

private final class SemanticInvalidSessionControlEffectBridge: MalformedSessionControlBridge {
    override func requestModels(sessionId: String?, isConnected: Bool) -> SharedSessionControlResult {
        requestCallCount += 1
        var snapshot = KMPSessionControlSnapshot.empty
        let target = KMPSessionControlRequestTarget(
            kind: "models",
            isDefault: false,
            sessionId: sessionId,
            provider: nil,
            model: nil,
            reasoningEffort: nil,
            target: nil,
            value: nil
        )
        snapshot.loadingKinds = ["models"]
        snapshot.pendingModelsSessionId = sessionId
        snapshot.requestTokens = ["models": "models:1"]
        snapshot.activeRequestTargets = ["models": target]
        var patch = KMPSessionControlPatch.empty
        patch.control = snapshot.controlPatch
        let effect = KMPSessionControlEffect(
            kind: "models",
            requestKey: "models",
            requestToken: "models:1",
            sessionId: "wrong-session",
            provider: nil,
            model: nil,
            reasoningEffort: nil,
            target: nil,
            value: nil
        )
        return SharedSessionControlResult(
            snapshotJson: Self.encode(patch),
            effectsJson: Self.encode([effect]),
            errorCode: nil,
            errorMessage: nil,
            applied: true,
            committed: true,
            completedKind: nil,
            completedRequestToken: nil
        )
    }
}

private final class InvalidSessionControlResultBridge: MalformedSessionControlBridge {
    enum Defect: CaseIterable {
        case uncommittedSnapshotMutation
        case effectWithoutApplied
        case committedWithoutMutation
        case inconsistentCompletion
    }

    private let defect: Defect

    init(defect: Defect) {
        self.defect = defect
    }

    override func requestModels(sessionId: String?, isConnected: Bool) -> SharedSessionControlResult {
        requestCallCount += 1
        let valid = forgedRequestResult(
            target: .init(kind: "models", isDefault: false, sessionId: sessionId)
        )
        switch defect {
        case .uncommittedSnapshotMutation:
            return SharedSessionControlResult(
                snapshotJson: valid.snapshotJson,
                effectsJson: "[]",
                errorCode: nil,
                errorMessage: nil,
                applied: true,
                committed: false,
                completedKind: nil,
                completedRequestToken: nil
            )
        case .effectWithoutApplied:
            return SharedSessionControlResult(
                snapshotJson: valid.snapshotJson,
                effectsJson: valid.effectsJson,
                errorCode: nil,
                errorMessage: nil,
                applied: false,
                committed: true,
                completedKind: nil,
                completedRequestToken: nil
            )
        case .committedWithoutMutation:
            return SharedSessionControlResult(
                snapshotJson: Self.encode(KMPSessionControlPatch.empty),
                effectsJson: "[]",
                errorCode: nil,
                errorMessage: nil,
                applied: true,
                committed: true,
                completedKind: nil,
                completedRequestToken: nil
            )
        case .inconsistentCompletion:
            return SharedSessionControlResult(
                snapshotJson: valid.snapshotJson,
                effectsJson: "[]",
                errorCode: nil,
                errorMessage: nil,
                applied: true,
                committed: true,
                completedKind: "models",
                completedRequestToken: "models:missing"
            )
        }
    }
}

private class MalformedSessionControlBridge: KMPSessionControlStoreBridging {
    fileprivate(set) var requestCallCount = 0
    fileprivate(set) var snapshotCallCount = 0

    fileprivate static func encode<T: Encodable>(_ value: T) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    func snapshot() -> SharedSessionControlResult {
        snapshotCallCount += 1
        let json = try! JSONEncoder().encode(KMPSessionControlSnapshot.empty)
        return SharedSessionControlResult(
            snapshotJson: String(decoding: json, as: UTF8.self),
            effectsJson: "[]",
            errorCode: nil,
            errorMessage: nil,
            applied: false,
            committed: false,
            completedKind: nil,
            completedRequestToken: nil
        )
    }

    func requestModels(sessionId: String?, isConnected: Bool) -> SharedSessionControlResult {
        requestCallCount += 1
        return SharedSessionControlResult(
            snapshotJson: "{}",
            effectsJson: "[]",
            errorCode: nil,
            errorMessage: nil,
            applied: true,
            committed: true,
            completedKind: nil,
            completedRequestToken: nil
        )
    }

    func selectModel(
        sessionId: String,
        selectionJson: String,
        isConnected: Bool
    ) -> SharedSessionControlResult { unimplemented() }

    func clearSessionData(sessionId: String) -> SharedSessionControlResult { unimplemented() }

    func modelsReceived(
        sessionId: String?, currentJson: String?, routable: Bool,
        groupsJson: String, isGlobalRequest: Bool
    ) -> SharedSessionControlResult { unimplemented() }

    func mergeContextProjection(
        sessionId: String,
        asOfSequence: KotlinLong?,
        tokenUsageJson: String?,
        pressureJson: String?,
        breakdownJson: String?
    ) -> SharedSessionControlResult { unimplemented() }

    fileprivate func forgedRequestResult(
        target: KMPSessionControlRequestTarget,
        effectTarget: KMPSessionControlRequestTarget? = nil
    ) -> SharedSessionControlResult {
        let token = "\(target.kind):forged"
        var snapshot = KMPSessionControlSnapshot.empty
        if target.isDefault {
            snapshot.defaultConfigurationLoadingKinds = [target.kind]
        } else {
            snapshot.loadingKinds = [target.kind]
        }
        snapshot.requestTokens = [target.kind: token]
        snapshot.activeRequestTargets = [target.kind: target]
        if target.kind == "models" {
            snapshot.pendingModelsSessionId = target.sessionId
            snapshot.isPendingGlobalModelsRequest = target.sessionId == nil
        }
        if target.kind == "select-model" { snapshot.pendingModelSelectionSessionId = target.sessionId }
        if target.kind == "permission-options" { snapshot.pendingPermissionOptionsSessionId = target.sessionId }
        var patch = KMPSessionControlPatch.empty
        patch.control = snapshot.controlPatch
        let effectTarget = effectTarget ?? target
        let effect = KMPSessionControlEffect(
            kind: effectTarget.kind,
            requestKey: effectTarget.kind,
            requestToken: token,
            sessionId: effectTarget.sessionId,
            provider: effectTarget.provider,
            model: effectTarget.model,
            reasoningEffort: effectTarget.reasoningEffort,
            target: effectTarget.target,
            value: effectTarget.value
        )
        return SharedSessionControlResult(
            snapshotJson: Self.encode(patch),
            effectsJson: Self.encode([effect]),
            errorCode: nil,
            errorMessage: nil,
            applied: true,
            committed: true,
            completedKind: nil,
            completedRequestToken: nil
        )
    }
}

private extension KMPSessionControlStoreBridging {
    func unimplemented() -> SharedSessionControlResult {
        SharedSessionControlResult(
            snapshotJson: nil,
            effectsJson: "[]",
            errorCode: "unexpected-test-call",
            errorMessage: nil,
            applied: false,
            committed: false,
            completedKind: nil,
            completedRequestToken: nil
        )
    }
    func requestPermissionOptions(sessionId: String, isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func requestContextUsage(sessionId: String, isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func requestSessionStats(sessionId: String, isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func requestAgentPresets(isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func requestDefaults(isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func requestDefaultModel(isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func setPermission(sessionId: String, value: String, isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func saveDefaultModel(selectionJson: String, isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func setDefault(target: String, value: String, isConnected: Bool) -> SharedSessionControlResult { unimplemented() }
    func clearSessionData(sessionId: String) -> SharedSessionControlResult { unimplemented() }
    func clearSessionsData(sessionIdsJson: String) -> SharedSessionControlResult { unimplemented() }
    func agentPresetsReceived(presetsJson: String, authorable: Bool, hasDocument: Bool) -> SharedSessionControlResult { unimplemented() }
    func defaultsReceived(
        agentPreset: String?,
        permission: String?,
        permissionOptionsJson: String?
    ) -> SharedSessionControlResult { unimplemented() }
    func defaultModelReceived(selectionJson: String?) -> SharedSessionControlResult { unimplemented() }
    func globalDefaultApplied(target: String, value: String) -> SharedSessionControlResult { unimplemented() }
    func modelsReceived(sessionId: String?, currentJson: String?, routable: Bool, groupsJson: String, isGlobalRequest: Bool) -> SharedSessionControlResult { unimplemented() }
    func defaultModelSaved(selectionJson: String?) -> SharedSessionControlResult { unimplemented() }
    func modelSelected(sessionId: String?, selectionJson: String) -> SharedSessionControlResult { unimplemented() }
    func permissionsReceived(sessionId: String?, permissionsJson: String) -> SharedSessionControlResult { unimplemented() }
    func permissionSelected(sessionId: String?, value: String) -> SharedSessionControlResult { unimplemented() }
    func contextReceived(sessionId: String?, asOfSequence: KotlinLong?, tokenUsageJson: String?, pressureJson: String?, breakdownJson: String?) -> SharedSessionControlResult { unimplemented() }
    func statsReceived(sessionId: String?, asOfSequence: KotlinLong?, statsJson: String?, tokenUsageTotalsJson: String?, contextPressureJson: String?) -> SharedSessionControlResult { unimplemented() }
    func mergeContextProjection(sessionId: String, asOfSequence: KotlinLong?, tokenUsageJson: String?, pressureJson: String?, breakdownJson: String?) -> SharedSessionControlResult { unimplemented() }
    func mergeStatsProjection(sessionId: String, asOfSequence: KotlinLong?, statsJson: String?, tokenUsageTotalsJson: String?, contextPressureJson: String?) -> SharedSessionControlResult { unimplemented() }
    func mergePermissionsProjection(sessionId: String, permissionsJson: String) -> SharedSessionControlResult { unimplemented() }
    func mergeModelProjection(sessionId: String, selectionJson: String) -> SharedSessionControlResult { unimplemented() }
    func mergePermissionProjection(sessionId: String, value: String) -> SharedSessionControlResult { unimplemented() }
    func requestFinished(kind: String, isDefault: Bool, requestToken: String?) -> SharedSessionControlResult { unimplemented() }
    func requestTimedOut(kind: String, isDefault: Bool, requestToken: String?) -> SharedSessionControlResult { unimplemented() }
    func requestFailed(kind: String, isDefault: Bool, requestToken: String?) -> SharedSessionControlResult { unimplemented() }
    func requestsDisconnected() -> SharedSessionControlResult { unimplemented() }
}

private final class FailingRestoreSessionListBridge: KMPSessionListStoreBridging {
    private(set) var nonRestoreCallCount = 0

    func snapshot() -> SharedSessionListResult { unexpectedCall() }
    func receiveHistory(sessionId: String, eventsJson: String) -> SharedSessionListResult { unexpectedCall() }

    func restore(snapshotJson: String) -> SharedSessionListResult {
        SharedSessionListResult(
            snapshotJson: nil,
            errorCode: "session-list-restore-failed",
            errorMessage: "injected restore failure"
        )
    }

    func selectSession(sessionId: String?) -> SharedSessionListResult { unexpectedCall() }

    func setArchivedSessionIds(sessionIdsJson: String) -> SharedSessionListResult { unexpectedCall() }

    func receiveRemoteSessions(sessionsJson: String) -> SharedSessionListResult { unexpectedCall() }

    func messageSent(
        sessionId: String,
        agentPreset: String?,
        insertedAtEpochSeconds: Double
    ) -> SharedSessionListResult {
        unexpectedCall()
    }

    func addKnownSession(
        sessionId: String,
        insertedAtEpochSeconds: Double
    ) -> SharedSessionListResult {
        unexpectedCall()
    }

    func receiveEvent(
        eventJson: String,
        insertedAtEpochSeconds: Double
    ) -> SharedSessionListResult {
        unexpectedCall()
    }

    func markRead(sessionId: String) -> SharedSessionListResult { unexpectedCall() }

    private func unexpectedCall() -> SharedSessionListResult {
        nonRestoreCallCount += 1
        return SharedSessionListResult(
            snapshotJson: "{\"sessions\":[],\"archivedSessionIds\":[]}",
            errorCode: nil,
            errorMessage: nil
        )
    }
}

private final class MalformedMutationSessionListBridge: KMPSessionListStoreBridging {
    private(set) var mutationCallCount = 0

    func snapshot() -> SharedSessionListResult { malformedMutation() }
    func receiveHistory(sessionId: String, eventsJson: String) -> SharedSessionListResult { malformedMutation() }

    func restore(snapshotJson: String) -> SharedSessionListResult {
        SharedSessionListResult(
            snapshotJson: snapshotJson,
            errorCode: nil,
            errorMessage: nil
        )
    }

    func selectSession(sessionId: String?) -> SharedSessionListResult { malformedMutation() }

    func setArchivedSessionIds(sessionIdsJson: String) -> SharedSessionListResult {
        malformedMutation()
    }

    func receiveRemoteSessions(sessionsJson: String) -> SharedSessionListResult {
        malformedMutation()
    }

    func messageSent(
        sessionId: String,
        agentPreset: String?,
        insertedAtEpochSeconds: Double
    ) -> SharedSessionListResult {
        malformedMutation()
    }

    func addKnownSession(
        sessionId: String,
        insertedAtEpochSeconds: Double
    ) -> SharedSessionListResult {
        malformedMutation()
    }

    func receiveEvent(
        eventJson: String,
        insertedAtEpochSeconds: Double
    ) -> SharedSessionListResult {
        malformedMutation()
    }

    func markRead(sessionId: String) -> SharedSessionListResult { malformedMutation() }

    private func malformedMutation() -> SharedSessionListResult {
        mutationCallCount += 1
        return SharedSessionListResult(
            snapshotJson: "not-json",
            errorCode: nil,
            errorMessage: nil
        )
    }
}

private final class MalformedMutationQuestionBridge: KMPQuestionStoreBridging {
    private(set) var mutationCallCount = 0

    func snapshot() -> SharedQuestionResult {
        SharedQuestionResult(
            snapshotJson: #"{"pendingRequests":[],"requestStatuses":{}}"#,
            effectJson: nil,
            errorCode: nil,
            errorMessage: nil
        )
    }

    func reset() -> SharedQuestionResult { malformedMutation() }
    func requestReceived(requestJson: String) -> SharedQuestionResult { malformedMutation() }
    func submitAnswer(rpcId: String, answersJson: String, isConnected: Bool) -> SharedQuestionResult {
        malformedMutation()
    }
    func submitCancel(rpcId: String, isConnected: Bool) -> SharedQuestionResult { malformedMutation() }
    func responseReceived(
        rpcId: String,
        action: String,
        accepted: Bool,
        reason: String?
    ) -> SharedQuestionResult {
        malformedMutation()
    }
    func resolved(rpcId: String) -> SharedQuestionResult { malformedMutation() }
    func requestFailed(rpcId: String, message: String?) -> SharedQuestionResult { malformedMutation() }
    func sessionRequestsFailed(sessionId: String, message: String?) -> SharedQuestionResult { malformedMutation() }

    private func malformedMutation() -> SharedQuestionResult {
        mutationCallCount += 1
        return SharedQuestionResult(
            snapshotJson: #"{"pendingRequests":[],"requestStatuses":{}}"#,
            effectJson: "not-json",
            errorCode: nil,
            errorMessage: nil
        )
    }
}

private enum SemanticQuestionEffectMismatch: CaseIterable {
    case rpcID
    case sessionID
    case snapshotStatus
    case emptyAnswers
    case answerOrder
}

private final class SemanticMismatchQuestionBridge: KMPQuestionStoreBridging {
    let request: GatewayPendingQuestionRequest
    let mismatch: SemanticQuestionEffectMismatch
    private(set) var submitCallCount = 0

    init(request: GatewayPendingQuestionRequest, mismatch: SemanticQuestionEffectMismatch) {
        self.request = request
        self.mismatch = mismatch
    }

    func snapshot() -> SharedQuestionResult {
        result(snapshot: KMPQuestionSnapshot(
            pendingRequests: [request],
            requestStatuses: [request.rpcId: KMPQuestionStatusSnapshot(kind: "idle")]
        ))
    }

    func reset() -> SharedQuestionResult { snapshot() }
    func requestReceived(requestJson: String) -> SharedQuestionResult { snapshot() }

    func submitAnswer(rpcId: String, answersJson: String, isConnected: Bool) -> SharedQuestionResult {
        submitCallCount += 1
        let submittedAnswers = (try? JSONDecoder().decode(
            [GatewayQuestionAnswer].self,
            from: Data(answersJson.utf8)
        )) ?? []
        let status = mismatch == .snapshotStatus
            ? KMPQuestionStatusSnapshot(kind: "accepted", action: "answer")
            : KMPQuestionStatusSnapshot(kind: "submitting", action: "answer")
        let effectAnswers: [GatewayQuestionAnswer]
        switch mismatch {
        case .emptyAnswers:
            effectAnswers = []
        case .answerOrder:
            effectAnswers = Array(submittedAnswers.reversed())
        default:
            effectAnswers = submittedAnswers
        }
        return result(
            snapshot: KMPQuestionSnapshot(
                pendingRequests: [request],
                requestStatuses: [request.rpcId: status]
            ),
            effect: KMPQuestionEffect(
                action: "answer",
                rpcId: mismatch == .rpcID ? "rpc-other" : request.rpcId,
                sessionId: mismatch == .sessionID ? "session-other" : request.sessionId,
                answers: effectAnswers
            )
        )
    }

    func submitCancel(rpcId: String, isConnected: Bool) -> SharedQuestionResult { snapshot() }
    func responseReceived(
        rpcId: String,
        action: String,
        accepted: Bool,
        reason: String?
    ) -> SharedQuestionResult { snapshot() }
    func resolved(rpcId: String) -> SharedQuestionResult { snapshot() }
    func requestFailed(rpcId: String, message: String?) -> SharedQuestionResult { snapshot() }
    func sessionRequestsFailed(sessionId: String, message: String?) -> SharedQuestionResult { snapshot() }

    private func result(
        snapshot: KMPQuestionSnapshot,
        effect: KMPQuestionEffect? = nil
    ) -> SharedQuestionResult {
        let encoder = JSONEncoder()
        return SharedQuestionResult(
            snapshotJson: String(decoding: try! encoder.encode(snapshot), as: UTF8.self),
            effectJson: effect.map { String(decoding: try! encoder.encode($0), as: UTF8.self) },
            errorCode: nil,
            errorMessage: nil
        )
    }
}

private final class QuestionLifecycleBridge: KMPQuestionStoreBridging {
    private let request: GatewayPendingQuestionRequest
    private var snapshotValue: KMPQuestionSnapshot

    init(request: GatewayPendingQuestionRequest) {
        self.request = request
        snapshotValue = KMPQuestionSnapshot(
            pendingRequests: [request],
            requestStatuses: [request.rpcId: KMPQuestionStatusSnapshot(kind: "idle")]
        )
    }

    func snapshot() -> SharedQuestionResult { result() }

    func reset() -> SharedQuestionResult {
        snapshotValue = .empty
        return result()
    }

    func requestReceived(requestJson: String) -> SharedQuestionResult { result() }

    func submitAnswer(rpcId: String, answersJson: String, isConnected: Bool) -> SharedQuestionResult {
        let answers = (try? JSONDecoder().decode(
            [GatewayQuestionAnswer].self,
            from: Data(answersJson.utf8)
        )) ?? []
        snapshotValue.requestStatuses[rpcId] = KMPQuestionStatusSnapshot(kind: "submitting", action: "answer")
        return result(effect: KMPQuestionEffect(
            action: "answer",
            rpcId: rpcId,
            sessionId: request.sessionId,
            answers: answers
        ))
    }

    func submitCancel(rpcId: String, isConnected: Bool) -> SharedQuestionResult { result() }

    func responseReceived(
        rpcId: String,
        action: String,
        accepted: Bool,
        reason: String?
    ) -> SharedQuestionResult {
        if accepted {
            snapshotValue.requestStatuses[rpcId] = KMPQuestionStatusSnapshot(kind: "accepted", action: action)
        } else if reason == "not-pending" {
            snapshotValue = .empty
        } else {
            snapshotValue.requestStatuses[rpcId] = KMPQuestionStatusSnapshot(
                kind: "rejected",
                failureCode: "SERVER_REJECTED",
                failureArgument: reason
            )
        }
        return result()
    }

    func resolved(rpcId: String) -> SharedQuestionResult {
        snapshotValue = .empty
        return result()
    }

    func requestFailed(rpcId: String, message: String?) -> SharedQuestionResult {
        snapshotValue.requestStatuses[rpcId] = KMPQuestionStatusSnapshot(
            kind: "rejected",
            failureCode: "REQUEST_FAILED",
            failureArgument: message
        )
        return result()
    }

    func sessionRequestsFailed(sessionId: String, message: String?) -> SharedQuestionResult {
        for request in snapshotValue.pendingRequests where request.sessionId == sessionId {
            snapshotValue.requestStatuses[request.rpcId] = KMPQuestionStatusSnapshot(
                kind: "rejected",
                failureCode: "REQUEST_FAILED",
                failureArgument: message
            )
        }
        return result()
    }

    private func result(effect: KMPQuestionEffect? = nil) -> SharedQuestionResult {
        let encoder = JSONEncoder()
        return SharedQuestionResult(
            snapshotJson: String(decoding: try! encoder.encode(snapshotValue), as: UTF8.self),
            effectJson: effect.map { String(decoding: try! encoder.encode($0), as: UTF8.self) },
            errorCode: nil,
            errorMessage: nil
        )
    }
}

@MainActor
private final class GatewayQuestionEffectExecutorSpy: GatewayQuestionEffectExecuting {
    private(set) var answerCalls: [(rpcID: String, sessionID: String, answers: [GatewayQuestionAnswer])] = []
    private(set) var cancelCallCount = 0

    func answerQuestion(rpcId: String, sessionId: String, answers: [GatewayQuestionAnswer]) {
        answerCalls.append((rpcId, sessionId, answers))
    }

    func cancelQuestion(rpcId: String, sessionId: String) {
        cancelCallCount += 1
    }
}

private final class AppPreferencesSpy: AppPreferences {
    var endpoint: String
    var automaticallyConnect = true
    var selectedWorkspaceID: String?
    private let sessions: [SessionSummary]
    private(set) var savedSessionSnapshots: [[SessionSummary]] = []
    private(set) var performMigrationsCallCount = 0

    init(endpoint: String, selectedWorkspaceID: String?, sessions: [SessionSummary]) {
        self.endpoint = endpoint
        self.selectedWorkspaceID = selectedWorkspaceID
        self.sessions = sessions
    }

    func loadSessions() -> [SessionSummary] { sessions }

    func saveSessions(_ sessions: [SessionSummary]) {
        savedSessionSnapshots.append(sessions)
    }

    func performMigrations() {
        performMigrationsCallCount += 1
    }
}

final class ManualGatewayDisconnectTests: XCTestCase {
    @MainActor
    func testManualDisconnectSuppressesColdLaunchConnection() {
        let preferences = AppPreferencesSpy(
            endpoint: "ws://127.0.0.1:3080/ws/mobile", selectedWorkspaceID: nil, sessions: []
        )
        let store = AppStore(preferences: preferences)
        defer { store.deactivateGateway() }

        store.disconnect()
        XCTAssertFalse(preferences.automaticallyConnect)
        let restarted = AppStore(preferences: preferences)
        defer { restarted.deactivateGateway() }
        restarted.connectOnColdLaunchIfPaired()
        restarted.handleScenePhase(.active)
        XCTAssertNil(restarted.lastError)
        XCTAssertFalse(restarted.gateway.state.isConnected)
    }

    func testDisconnectPreferencePersistsPerGateway() throws {
        let suite = "manual-disconnect-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UserDefaultsAppPreferences(userDefaults: defaults, gatewayID: "first")
        let second = UserDefaultsAppPreferences(userDefaults: defaults, gatewayID: "second")
        XCTAssertTrue(first.automaticallyConnect)
        first.automaticallyConnect = false

        XCTAssertFalse(UserDefaultsAppPreferences(userDefaults: defaults, gatewayID: "first").automaticallyConnect)
        XCTAssertTrue(second.automaticallyConnect)
    }
}

private final class MalformedConversationEventBridge:
    KMPConversationStoreBridging,
    KMPConversationEventBridging
{
    private var handler: ((SharedMviEvent) -> Void)?
    private(set) var receiveCallCount = 0

    func observeConversationEvents(
        _ handler: @escaping (SharedMviEvent) -> Void
    ) -> () -> Void {
        self.handler = handler
        handler(SharedMviEvent(
            schema: 2,
            sequence: 0,
            transactionId: "snapshot:conversation:0",
            domain: "conversation",
            kind: "snapshot",
            statePayloadJson: #"{"schema":1}"#,
            effectsJson: "[]",
            metadataJson: nil,
            errorCode: nil,
            errorMessage: nil
        ))
        return { [weak self] in self?.handler = nil }
    }

    func receiveEvent(eventJson: String) -> SharedMviDispatchResult {
        receiveCallCount += 1
        handler?(SharedMviEvent(
            schema: 2,
            sequence: 1,
            transactionId: "conversation-event:1",
            domain: "conversation",
            kind: "transition",
            statePayloadJson: #"{"schema":1,"sessionId":"s1","operations":[{"kind":"append-text","itemId":"missing","delta":"x","epochSeconds":1}],"replacesAll":false,"lastSequence":1}"#,
            effectsJson: "[]",
            metadataJson: nil,
            errorCode: nil,
            errorMessage: nil
        ))
        return SharedMviDispatchResult(
            accepted: true,
            transactionId: "conversation-event:1",
            eventSequence: KotlinLong(longLong: 1),
            errorCode: nil,
            errorMessage: nil
        )
    }

    func replaceSession(sessionId: String, eventsJson: String) -> SharedMviDispatchResult {
        SharedMviDispatchResult(
            accepted: false, transactionId: nil, eventSequence: nil,
            errorCode: "unsupported", errorMessage: nil
        )
    }

    /// Fault injection lives on the shared event path: this bridge is only here
    /// to prove a malformed patch fails the adapter closed, so the stream-delta
    /// and presence probes report "unsupported" rather than pretending to work.
    func receiveStreamDelta(eventJson: String) -> SharedMviDispatchResult {
        SharedMviDispatchResult(
            accepted: false, transactionId: nil, eventSequence: nil,
            errorCode: "unsupported", errorMessage: nil
        )
    }

    func hasProjection(sessionId: String) -> Bool { false }

    func clearSession(sessionId: String) -> SharedMviDispatchResult {
        SharedMviDispatchResult(
            accepted: false, transactionId: nil, eventSequence: nil,
            errorCode: "unsupported", errorMessage: nil
        )
    }
}

private final class CountingTrajectoryBridge: KMPTrajectoryStoreBridging, KMPTrajectoryEventBridging {
    private let store = SharedTrajectoryStore()
    private(set) var replaceCount = 0

    func observeTrajectoryEvents(_ handler: @escaping (SharedMviEvent) -> Void) -> () -> Void {
        store.observeTrajectoryEvents(handler)
    }

    func receiveEvent(eventJson: String) -> SharedMviDispatchResult {
        store.receiveEvent(eventJson: eventJson)
    }

    func receiveEvents(eventsJson: String) -> SharedMviDispatchResult {
        store.receiveEvents(eventsJson: eventsJson)
    }

    func replaceSession(sessionId: String, eventsJson: String) -> SharedMviDispatchResult {
        replaceCount += 1
        return store.replaceSession(sessionId: sessionId, eventsJson: eventsJson)
    }

    func clearSession(sessionId: String) -> SharedMviDispatchResult {
        store.clearSession(sessionId: sessionId)
    }
}

private final class MalformedTrajectoryEventBridge:
    KMPTrajectoryStoreBridging,
    KMPTrajectoryEventBridging
{
    private var handler: ((SharedMviEvent) -> Void)?

    func observeTrajectoryEvents(
        _ handler: @escaping (SharedMviEvent) -> Void
    ) -> () -> Void {
        self.handler = handler
        handler(SharedMviEvent(
            schema: 2, sequence: 0,
            transactionId: "snapshot:trajectory:0",
            domain: "trajectory", kind: "snapshot",
            statePayloadJson: #"{"schema":1}"#,
            effectsJson: "[]", metadataJson: nil,
            errorCode: nil, errorMessage: nil
        ))
        return { [weak self] in self?.handler = nil }
    }

    func receiveEvent(eventJson: String) -> SharedMviDispatchResult {
        handler?(SharedMviEvent(
            schema: 2, sequence: 1,
            transactionId: "trajectory-event:1",
            domain: "trajectory", kind: "transition",
            statePayloadJson: #"{"schema":1,"sessionId":"s1","operations":[{"kind":"update","itemId":"missing","subtitleDelta":"x","endSequence":1,"endEpochSeconds":1,"appendedRecords":[]}],"replacesAll":false,"lastSequence":1}"#,
            effectsJson: "[]", metadataJson: nil,
            errorCode: nil, errorMessage: nil
        ))
        return SharedMviDispatchResult(
            accepted: true, transactionId: "trajectory-event:1",
            eventSequence: KotlinLong(longLong: 1),
            errorCode: nil, errorMessage: nil
        )
    }

    func receiveEvents(eventsJson: String) -> SharedMviDispatchResult {
        receiveEvent(eventJson: eventsJson)
    }

    func replaceSession(sessionId: String, eventsJson: String) -> SharedMviDispatchResult {
        SharedMviDispatchResult(
            accepted: false, transactionId: nil, eventSequence: nil,
            errorCode: "unsupported", errorMessage: nil
        )
    }

    func clearSession(sessionId: String) -> SharedMviDispatchResult {
        SharedMviDispatchResult(
            accepted: false, transactionId: nil, eventSequence: nil,
            errorCode: "unsupported", errorMessage: nil
        )
    }
}

private actor ConversationHistoryPreparationGate {
    private let entered: XCTestExpectation
    private var opened = false
    private var announced = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(entered: XCTestExpectation) { self.entered = entered }
    func pause() async {
        guard !opened else { return }
        if !announced { announced = true; entered.fulfill() }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class MalformedHistoryEventBridge:
    KMPHistoryStoreBridging,
    KMPHistoryEventBridging
{
    private var handler: ((SharedMviEvent) -> Void)?
    private let payload: String

    init(payload: String = #"{"schema":1,"sessionId":"s1","session":null,"pendingSessionId":null,"pendingSessionChanged":false,"eventPatch":{"kind":"append","record":{"sessionId":"s1","seq":1,"time":1,"event":{"type":"assistant/message","text":"one"}},"index":9,"replacementEvents":null},"outcome":"none","failureCode":null,"completedEventCount":null,"completedByteCount":null,"completedHasMore":null}"#) {
        self.payload = payload
    }

    func observeHistoryEvents(_ handler: @escaping (SharedMviEvent) -> Void) -> () -> Void {
        self.handler = handler
        handler(SharedMviEvent(
            schema: 2, sequence: 0,
            transactionId: "snapshot:history:0",
            domain: "history", kind: "snapshot",
            statePayloadJson: #"{"schema":1,"state":{"sessions":{},"pendingSessionId":null},"eventsBySession":{}}"#,
            effectsJson: "[]", metadataJson: nil,
            errorCode: nil, errorMessage: nil
        ))
        return { [weak self] in self?.handler = nil }
    }

    func liveEventReceived(eventJson: String) -> SharedMviDispatchResult {
        handler?(SharedMviEvent(
            schema: 2, sequence: 1,
            transactionId: "history-live:1",
            domain: "history", kind: "transition",
            statePayloadJson: payload,
            effectsJson: "[]", metadataJson: nil,
            errorCode: nil, errorMessage: nil
        ))
        return accepted("history-live:1")
    }

    func start(sessionId: String, older: Bool, hasLocalEvents: Bool, earliestLocalSequence: KotlinInt?) -> SharedMviDispatchResult { unsupported() }
    func processingStarted(sessionId: String, rawEventCount: Int32, hasMore: Bool) -> SharedMviDispatchResult { unsupported() }
    func pageReceived(
        sessionId: String,
        eventsJson: String,
        byteCount: Int32,
        hasMore: Bool,
        nextBeforeSequence: KotlinInt?,
        remoteActivityTimestamp: KotlinDouble?
    ) -> SharedMviDispatchResult {
        handler?(SharedMviEvent(
            schema: 2, sequence: 1, transactionId: "history-page:1", domain: "history", kind: "transition",
            statePayloadJson: payload, effectsJson: "[]", metadataJson: nil, errorCode: nil, errorMessage: nil
        ))
        return accepted("history-page:1")
    }
    func timedOut(sessionId: String) -> SharedMviDispatchResult { unsupported() }
    func cancelled(sessionId: String) -> SharedMviDispatchResult { unsupported() }
    func clearSession(sessionId: String) -> SharedMviDispatchResult { unsupported() }

    private func accepted(_ transactionID: String) -> SharedMviDispatchResult {
        SharedMviDispatchResult(
            accepted: true, transactionId: transactionID,
            eventSequence: KotlinLong(longLong: 1), errorCode: nil, errorMessage: nil
        )
    }

    private func unsupported() -> SharedMviDispatchResult {
        SharedMviDispatchResult(
            accepted: false, transactionId: nil, eventSequence: nil,
            errorCode: "unsupported", errorMessage: nil
        )
    }
}

@MainActor
private final class BackgroundTaskApplicationSpy: BackgroundTaskApplication {
    private(set) var beginCallCount = 0
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
    private(set) var expirationHandler: (@Sendable () -> Void)?

    func beginBackgroundTask(
        withName taskName: String?,
        expirationHandler handler: (@Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        beginCallCount += 1
        expirationHandler = handler
        return UIBackgroundTaskIdentifier(rawValue: beginCallCount)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        endedIdentifiers.append(identifier)
    }
}

@MainActor
private final class AgentLongRunningKeepAliveSpy: AgentLongRunningKeepAlive {
    var isKeepingAlive = false
    var onPulse: (() -> Void)?
    private(set) var agentWorkIsActive = false

    func setAgentWorkActive(_ active: Bool) {
        agentWorkIsActive = active
        if !active { isKeepingAlive = false }
    }

    func applicationDidBecomeActive() {}
    func applicationDidEnterBackground() {}
    func prepareForTermination() {}
}

/// Regression coverage for a launch-time crash on a physical device.
///
/// A completed assistant message is premeasured by hosting the real view
/// (`ConversationViewportController.measureHostedHeight`). MarkdownUI built its
/// inline `Text` with a left-associative `result = result + next` chain, so a
/// single paragraph holding N inline nodes produced a concatenation tree of
/// depth N. SwiftUI resolves `ConcatenatedTextStorage` recursively, so once a
/// session contained a long message — one inline node per line — resolution
/// overflowed the main thread's stack:
///
///   EXC_BAD_ACCESS (SIGSEGV) — "Thread stack size exceeded due to excessive
///   recursion" — Text.resolve ⇄ ConcatenatedTextStorage.resolve
///
/// These tests fail by killing the test process before the fix, and must return
/// a finite measurement after it.
final class MarkdownRenderProductTests: XCTestCase {
    func testJSONKeyWhitespaceEscapesAndUnicodeKeepOriginalAttributes() throws {
        // JSONC highlighting accepts general regex whitespace, not just the
        // four whitespace characters allowed by the JSON parser.
        let source = "\"中文🙂\"\u{2003}\t:\n\"value\\\"with:colon\", \"tail\", true, false, null, -12.5e+2"
        let highlighted = JSONSyntaxHighlighter.highlight(source)
        XCTAssertEqual(String(highlighted.characters), source)
        func color(_ token: String) throws -> Color? {
            let range = try XCTUnwrap(highlighted.range(of: token))
            return highlighted[range].foregroundColor
        }
        XCTAssertEqual(try color("\"中文🙂\""), DSHColor.ocean)
        XCTAssertEqual(try color("\"value\\\"with:colon\""), Color(red: 0.10, green: 0.55, blue: 0.38))
        XCTAssertEqual(try color("\"tail\""), Color(red: 0.10, green: 0.55, blue: 0.38))
        XCTAssertEqual(try color("true"), DSHColor.purple)
        XCTAssertEqual(try color("false"), DSHColor.purple)
        XCTAssertEqual(try color("null"), .red.opacity(0.8))
        XCTAssertEqual(try color("-12.5e+2"), DSHColor.orange)
        XCTAssertEqual(JSONSyntaxHighlighter.highlight(source), highlighted)
        XCTAssertTrue(JSONSyntaxHighlighter.isJSON(#"{"a": []}"#))
        XCTAssertFalse(JSONSyntaxHighlighter.isJSON(#""scalar""#))
        XCTAssertFalse(JSONSyntaxHighlighter.isJSON("not JSON"))
    }

    func testPreparedDocumentUpdatesFileOrderAndRemovesObsoleteReferences() {
        let source = "`a.pdf` `b.pdf`"
        let first = PreparedMarkdownCache.document(for: source, filePaths: ["a.pdf", "b.pdf"]).renderHTML()
        let reordered = PreparedMarkdownCache.document(for: source, filePaths: ["b.pdf", "a.pdf"]).renderHTML()
        XCTAssertTrue(first.contains("href=\"dsh-file-reference:///0\"><code>a.pdf"))
        XCTAssertTrue(reordered.contains("href=\"dsh-file-reference:///1\"><code>a.pdf"))
        let removed = PreparedMarkdownCache.document(for: source, filePaths: ["b.pdf"]).renderHTML()
        XCTAssertFalse(removed.contains("href=\"dsh-file-reference:///1\""))
        XCTAssertTrue(removed.contains("href=\"dsh-file-reference:///0\"><code>b.pdf"))
        let plain = PreparedMarkdownCache.document(for: source, filePaths: []).renderHTML()
        XCTAssertFalse(plain.contains("dsh-file-reference"))
        XCTAssertTrue(plain.contains("\u{2009}a.pdf\u{2009}"))
        XCTAssertEqual(PreparedMarkdownCache.document(for: source, filePaths: ["a.pdf", "b.pdf"]).renderHTML(), first)
    }

    func testRenderingCacheHonorsRecencyCountCostAndOversizedAdmission() {
        let cache = MarkdownRenderProductCache<String, String>(countLimit: 2, costLimit: 5)
        var builds: [String: Int] = [:]
        func read(_ key: String, cost: Int = 2) -> String {
            cache.value(for: key) {
                builds[key, default: 0] += 1
                return (key, cost)
            }
        }
        XCTAssertEqual(read("a"), "a")
        _ = read("b")
        _ = read("a")
        _ = read("c")
        _ = read("a")
        XCTAssertEqual(builds["a"], 1)
        _ = read("b")
        XCTAssertEqual(builds["b"], 2)
        _ = read("large", cost: 6)
        _ = read("large", cost: 6)
        XCTAssertEqual(builds["large"], 2)
        _ = read("b")
        XCTAssertEqual(builds["b"], 2, "Oversized products must not evict admitted entries")
        _ = read("costly", cost: 5)
        _ = read("b")
        XCTAssertEqual(builds["b"], 3, "Cost must bound the cache even below the count limit")
    }

    func testMemoryWarningDropsCachedAndInFlightProducts() {
        let cache = MarkdownRenderProductCache<String, Int>(countLimit: 2, costLimit: 10)
        var builds = 0
        func read() -> Int {
            cache.value(for: "a") { builds += 1; return (builds, 1) }
        }
        XCTAssertEqual(read(), 1)
        XCTAssertEqual(read(), 1)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(read(), 2)
        _ = cache.value(for: "in-flight") {
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            return (3, 1)
        }
        XCTAssertEqual(cache.value(for: "in-flight") { (4, 1) }, 4)
    }
}

final class MarkdownLargeMessageTests: XCTestCase {
    private func longMessage(lineCount: Int) -> String {
        (1...lineCount).map(String.init).joined(separator: "\n")
    }

    @MainActor
    func testMeasuringVeryLongSingleParagraphMessageIsStable() {
        let host = UIHostingController(
            rootView: MarkdownContent(longMessage(lineCount: 20000))
        )

        let size = host.sizeThatFits(
            in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        )

        XCTAssertTrue(size.height.isFinite, "measurement produced a non-finite height")
        XCTAssertGreaterThan(size.height, 0)
    }

    @MainActor
    func testMeasuringAssistantRowWithVeryLongMessageIsStable() {
        let item = ConversationItem(
            id: "very-long-assistant",
            kind: .assistant,
            title: "Agent",
            text: longMessage(lineCount: 20000),
            isError: false,
            date: Date(timeIntervalSince1970: 1)
        )
        let host = UIHostingController(
            rootView: ConversationRow(item: item, showsCopyButton: true, imageData: { _ in nil })
        )

        let size = host.sizeThatFits(
            in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        )

        XCTAssertTrue(size.height.isFinite, "measurement produced a non-finite height")
        XCTAssertGreaterThan(size.height, 0)
    }
}

final class SessionAgentPresetProtocolTests: XCTestCase {
    func testCatalogDecodesBrokenReasonAndHostVisibilitySetting() throws {
        let frame = try GatewayWireDecoder.decode(Data(#"{"kind":"agent-presets","modeSelectionEnabled":false,"presets":[{"id":"standard","isDefault":true},{"id":"custom","name":"自定义模式","broken":"缺少插件"}]}"#.utf8))
        XCTAssertEqual(frame.modeSelectionEnabled, false)
        XCTAssertEqual(frame.presets?.last?.broken, true)
        XCTAssertEqual(frame.presets?.last?.brokenReason, "缺少插件")
        XCTAssertEqual(frame.presets?.last?.isDefault, false)
        let roundTrip = try JSONDecoder().decode(GatewayFrame.self, from: JSONEncoder().encode(frame))
        XCTAssertEqual(roundTrip.presets?.last?.brokenReason, "缺少插件")
    }

    func testLockNotificationDoesNotInventPresetOrRequestIdentity() throws {
        let frame = try GatewayWireDecoder.decode(Data(#"{"kind":"session-agent-preset-updated","sessionId":"s1","locked":true,"seq":15}"#.utf8))
        XCTAssertEqual(frame.locked, true)
        XCTAssertNil(frame.agentPreset)
        XCTAssertNil(frame.requestId)
        let response = try GatewayWireDecoder.decode(Data(#"{"kind":"select-agent-preset","sessionId":"s1","requestId":"select1","agentPreset":"minimal"}"#.utf8))
        XCTAssertEqual(response.agentPreset, "minimal")
        XCTAssertEqual(response.requestId, "select1")
        XCTAssertNil(response.locked)
    }
}

final class InterfaceStylePresentationTests: XCTestCase {
    @MainActor
    func testRootAppliesLiveAppearanceChangesAndReturnsToSystem() async throws {
        let suite = "appearance-presentation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosts = MultiGatewayStore(defaults: defaults)
        let store = hosts.activeStore
        // 本测试仅验证外观，避免根视图首次显示时弹出未配对提示。
        store.connectOnColdLaunchIfPaired()
        store.lastError = nil
        let controller = UIHostingController(rootView:
            RootView().environmentObject(store).environmentObject(hosts)
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalSystemStyle: UIUserInterfaceStyle? = scene.traitOverrides.contains(UITraitUserInterfaceStyle.self)
            ? scene.traitOverrides.userInterfaceStyle : nil
        // 从 Scene 注入系统外观，避免与 SwiftUI 管理的 Window override 相互覆盖。
        scene.traitOverrides.userInterfaceStyle = .light
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            store.deactivateGateway()
            if let originalSystemStyle {
                scene.traitOverrides.userInterfaceStyle = originalSystemStyle
            } else {
                scene.traitOverrides.remove(UITraitUserInterfaceStyle.self)
            }
        }

        await assertAppearance(.light, in: controller)
        store.interfaceStyle = .dark
        await assertAppearance(.dark, in: controller)
        store.interfaceStyle = .light
        await assertAppearance(.light, in: controller)
        // App 指定浅色时不受系统深色影响；恢复跟随系统后立即继承。
        scene.traitOverrides.userInterfaceStyle = .dark
        await assertAppearance(.light, in: controller)
        store.interfaceStyle = .system
        await assertAppearance(.dark, in: controller)
        scene.traitOverrides.userInterfaceStyle = .light
        await assertAppearance(.light, in: controller)
    }

    @MainActor
    private func assertAppearance(
        _ expected: UIUserInterfaceStyle,
        in controller: UIViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            controller.view.layoutIfNeeded()
            if controller.traitCollection.userInterfaceStyle == expected { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.traitCollection.userInterfaceStyle, expected, file: file, line: line)
    }
}

@MainActor
final class ScheduledTaskCardPresentationTests: XCTestCase {
    func testRepeatedExpansionKeepsSummaryAtTheSamePosition() async throws {
        let catalog = try GatewayWireDecoder.decode(Data(
            #"{"kind":"schedule-catalog","items":[{"id":"task-1","sessionId":"s1","status":"active","kind":"daily","title":"每日新闻汇总（科技/金融/民生/体育）","prompt":"每日新闻汇总任务。请完整执行以下步骤：","time":"08:00:00.000","timeZone":"Asia/Shanghai","scheduledAt":"2099-01-01T00:00:00.000Z"}]}"#.utf8
        ))
        let task = try XCTUnwrap(catalog.items?.first.flatMap(ScheduledTask.init))
        let state = ExpansionState()
        let controller = UIHostingController(rootView: Harness(task: task, state: state))
        controller.overrideUserInterfaceStyle = .light
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        let initialPosition = try visualPosition(in: window)
        let collapsedHeight = state.cardHeight
        XCTAssertGreaterThan(collapsedHeight, 100)
        var previousBottom = initialPosition.bottom

        for (cycle, expanded) in [true, false, true, false].enumerated() {
            state.expanded = expanded
            var bottoms: [CGFloat] = []
            // 检查行高更新和箭头动画期间的真实画面，而不只检查动画结束后的布局。
            for sample in 0..<8 {
                try await Task.sleep(for: .milliseconds(35))
                controller.view.layoutIfNeeded()
                if sample == 2 && cycle < 2 {
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    attachment.name = expanded ? "schedule-expanded" : "schedule-collapsed"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                let position = try visualPosition(in: window)
                bottoms.append(position.bottom)
                XCTAssertEqual(position.top, initialPosition.top, accuracy: 1,
                               "展开/收起只能改变详情区域，摘要不能随行高动画上下跳动")
            }
            let finalBottom = try XCTUnwrap(bottoms.last)
            let lower = min(previousBottom, finalBottom)
            let upper = max(previousBottom, finalBottom)
            XCTAssertTrue(bottoms.contains { $0 > lower + 3 && $0 < upper - 3 },
                          "展开和收起必须经过中间高度，不能直接跳到终点：\(bottoms)")
            previousBottom = finalBottom
            if expanded {
                XCTAssertGreaterThan(state.cardHeight, collapsedHeight + 100)
            } else {
                XCTAssertEqual(state.cardHeight, collapsedHeight, accuracy: 1)
            }
        }
    }

    private final class ExpansionState: ObservableObject {
        @Published var expanded = false
        var cardHeight: CGFloat = 0
    }

    private struct Harness: View {
        let task: ScheduledTask
        @ObservedObject var state: ExpansionState

        var body: some View {
            List {
                ScheduledTaskCard(task: task, sessionTitle: "新闻汇总", expanded: state.expanded,
                                  onOpen: {}, onExpand: { state.expanded.toggle() })
                    .overlay(alignment: .bottom) {
                        Color.red.frame(width: 40, height: 2).allowsHitTesting(false)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.cardHeight = $0 }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .adaptiveListWidth()
            .scrollContentBackground(.hidden)
            .background(Color.white)
        }
    }

    private func visualPosition(in window: UIWindow) throws -> (top: CGFloat, bottom: CGFloat) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let position: (Int?, Int?) = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                            CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, nil) }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            var top: Int?
            var bottom: Int?
            // 蓝色执行规则追踪摘要位置，测试覆盖层的红线追踪卡片底边的动画。
            for y in 0..<height {
                let center = (y * width + width / 2) * 4
                if rgba[center] > 220, rgba[center + 1] < 80, rgba[center + 2] < 80 { bottom = y }
                guard top == nil else { continue }
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    if rgba[offset] < 80, rgba[offset + 1] > 90,
                       rgba[offset + 1] < 200, rgba[offset + 2] > 220 {
                        top = y
                        break
                    }
                }
            }
            return (top, bottom)
        }
        return (CGFloat(try XCTUnwrap(position.0, "截图中应显示任务的蓝色执行规则")),
                CGFloat(try XCTUnwrap(position.1, "截图中应显示卡片底边的测试标记")))
    }
}

final class SessionHistoryVisibilityTests: XCTestCase {
    @MainActor
    func testBlankSessionRemainsAvailableForConfigurationButNotHistory() async throws {
        let store = AppStore(preferences: AppPreferencesSpy(endpoint: "", selectedWorkspaceID: nil, sessions: []))
        defer { store.deactivateGateway() }
        store.addKnownSession("draft")
        await store.awaitPendingKMPEventDeliveriesForTesting()
        XCTAssertEqual(store.sessions.map(\.id), ["draft"])
        XCTAssertTrue(store.historySessions.isEmpty)
        XCTAssertTrue(store.ungroupedSessions.isEmpty)
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(
            #"{"kind":"sent","sessionId":"draft"}"#.utf8
        )))
        await store.awaitPendingKMPEventDeliveriesForTesting()
        XCTAssertEqual(store.historySessions.map(\.id), ["draft"])
    }

    @MainActor
    func testHostListRemovesMissingCachedSessionsAndHidesBlankOnes() throws {
        let cached = SessionSummary(id: "gone", title: "本地旧会话", lastActivity: .now,
                                    isRunning: false, hasUnread: false)
        let adapter = KMPSessionListStoreAdapter(sessions: [cached])
        let snapshot = try adapter.reduce(.remoteSessionsReceived([
            GatewaySessionSummary(sessionId: "blank", updatedAt: 200, running: false, blank: true),
            GatewaySessionSummary(sessionId: "real", updatedAt: 100, running: false, blank: false)
        ]))
        XCTAssertEqual(snapshot.persistedSessions.filter(\.isVisibleInHistory).map(\.id), ["real"])
        XCTAssertFalse(snapshot.persistedSessions.contains { $0.id == "gone" })
        let restored = KMPSessionListStoreAdapter(sessions: snapshot.persistedSessions)
        XCTAssertEqual(restored.snapshot.persistedSessions.filter(\.isVisibleInHistory).map(\.id), ["real"])
        let empty = try restored.reduce(.remoteSessionsReceived([]))
        XCTAssertTrue(empty.persistedSessions.isEmpty)
    }

    func testLegacySessionCacheStillDecodesAndNewVisibilityRoundTrips() throws {
        let old = Data(#"{"id":"legacy","title":"已有会话","lastActivity":0,"isRunning":false,"hasUnread":false}"#.utf8)
        let cached = try JSONDecoder().decode(SessionSummary.self, from: old)
        XCTAssertNil(cached.hasConversation)
        XCTAssertTrue(cached.isVisibleInHistory)
        var blank = cached
        blank.hasConversation = false
        let restored = try JSONDecoder().decode(SessionSummary.self, from: JSONEncoder().encode(blank))
        XCTAssertFalse(restored.isVisibleInHistory)
    }
}

@MainActor
final class PluginIconRenderingTests: XCTestCase {
    static let svg = "data:image/svg+xml;base64," + Data(
        "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><circle cx='32' cy='32' r='28' fill='#2e6be6'/></svg>".utf8
    ).base64EncodedString()

    func testSVGCacheCoalescesRequestsAndPreservesArtwork() async throws {
        let cache = PluginIconImageCache()
        let request = PluginIconImageCache.Request(dataURL: Self.svg, isDark: false)
        async let first = cache.image(for: request)
        async let second = cache.image(for: request)
        let (a, b) = await (first, second)
        let image = try XCTUnwrap(a)
        XCTAssertTrue(image === b, "并发请求相同图标应复用同一次渲染")
        let cached = await cache.image(for: request)
        XCTAssertTrue(image === cached, "再次显示图标应直接命中缓存")
        let pixel = try centerPixel(image)
        XCTAssertGreaterThan(pixel[2], pixel[0] + 80, "SVG 中的蓝色圆形必须正确显示，不能缓存空白截图")
        XCTAssertGreaterThan(pixel[3], 240)
        XCTAssertEqual(try self.pixel(image, at: CGPoint(x: 0, y: 0))[3], 0, "图标背景应保持透明")
    }

    func testDifferentSVGRequestsAreSerializedWithoutMixingArtwork() async throws {
        let cache = PluginIconImageCache()
        let redSVG = "data:image/svg+xml;base64," + Data(
            "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><rect width='64' height='64' fill='#ff0000'/></svg>".utf8
        ).base64EncodedString()
        async let blue = cache.image(for: .init(dataURL: Self.svg, isDark: false))
        async let red = cache.image(for: .init(dataURL: redSVG, isDark: true))
        let (a, b) = await (blue, red)
        let bluePixel = try centerPixel(XCTUnwrap(a))
        let redPixel = try centerPixel(XCTUnwrap(b))
        XCTAssertGreaterThan(bluePixel[2], bluePixel[0] + 80)
        XCTAssertGreaterThan(redPixel[0], redPixel[2] + 80)
    }

    func testBitmapAndInvalidIconsDoNotNeedSVGRendering() async throws {
        let cache = PluginIconImageCache()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        }
        let source = "data:image/png;base64," + (try XCTUnwrap(png.pngData())).base64EncodedString()
        let result = await cache.image(for: .init(dataURL: source, isDark: false))
        let image = try XCTUnwrap(result)
        XCTAssertLessThanOrEqual(try XCTUnwrap(image.cgImage).width, 256)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.01)
        for invalid in ["invalid", "data:image/png;base64,???", "data:image/svg+xml;base64," + Data("invalid".utf8).base64EncodedString()] {
            let result = await cache.image(for: .init(dataURL: invalid, isDark: false))
            XCTAssertNil(result)
        }
    }

    func testSVGColorSchemeIsPartOfTheCacheKey() async throws {
        let cache = PluginIconImageCache()
        let svg = "data:image/svg+xml;base64," + Data("""
        <svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'>
        <style>rect{fill:#ff0000}@media(prefers-color-scheme:dark){rect{fill:#0000ff}}</style>
        <rect width='64' height='64'/></svg>
        """.utf8).base64EncodedString()
        let light = await cache.image(for: .init(dataURL: svg, isDark: false))
        let lightPixel = try centerPixel(XCTUnwrap(light))
        let dark = await cache.image(for: .init(dataURL: svg, isDark: true))
        let darkPixel = try centerPixel(XCTUnwrap(dark))
        XCTAssertGreaterThan(lightPixel[0], lightPixel[2] + 80)
        XCTAssertGreaterThan(darkPixel[2], darkPixel[0] + 80)
        XCTAssertEqual(try centerPixel(XCTUnwrap(light)), lightPixel, "复用渲染器不能改变已经缓存的图片")
    }

    private func centerPixel(_ image: UIImage) throws -> [Int] {
        try pixel(image, at: CGPoint(x: image.size.width / 2, y: image.size.height / 2))
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: -point.x, y: -point.y)
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: image.size))
        return bytes.map(Int.init)
    }

    func testScrollingIconsDoesNotEmbedWebViewsInRows() async throws {
        let host = UIHostingController(rootView: ScrollView {
            VStack(spacing: 16) {
                ForEach(0..<24) { _ in PluginIcon(dataURL: Self.svg, fallback: "shell").frame(width: 48, height: 48) }
            }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let start = CFAbsoluteTimeGetCurrent()
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let layoutTime = CFAbsoluteTimeGetCurrent() - start
        try await Task.sleep(for: .seconds(1))
        func webViewCount(_ view: UIView) -> Int {
            (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + webViewCount($1) }
        }
        let count = webViewCount(host.view)
        print("Plugin icon first layout: \(layoutTime)s; embedded WKWebViews: \(count)")
        XCTAssertEqual(count, 0, "图标应使用缓存图片，不能在每一行嵌入网页视图")
        if let scroll = firstDescendant(of: UIScrollView.self, in: host.view) {
            for offset in [300.0, 600.0, 0.0] {
                scroll.contentOffset.y = offset
                host.view.layoutIfNeeded()
            }
        }
        XCTAssertEqual(webViewCount(host.view), 0)
    }
}

final class MobilePluginBundleTests: XCTestCase {
    func testExperimentalBadgeUsesGatewayFlagOnly() {
        let flagged = MobilePluginBundle(raw: .object([
            "name": .string("flagged"), "experimental": .bool(true)
        ]))
        let unflagged = MobilePluginBundle(raw: .object([
            "name": .string("@deepseek-ai/dsh-experimental-unflagged"),
            "experimental": .bool(false)
        ]))
        let legacy = MobilePluginBundle(raw: .object(["name": .string("legacy")]))

        XCTAssertTrue(flagged.experimental)
        XCTAssertFalse(unflagged.experimental)
        XCTAssertFalse(legacy.experimental)
    }
}

final class ErrorDetailsGatewayTests: XCTestCase {
    func testLiveDiagnosticsSurviveSwiftRoundTrip() throws {
        let source = #"{"kind":"event","sessionId":"s","seq":1,"time":1,"event":{"type":"assistant/attempt","turn":1,"step":0,"finish":{"kind":"error","failure":{"message":"Rate limited","code":"RATE_LIMIT","status":429}}}}"#
        let frame = try GatewayWireDecoder.decode(Data(source.utf8))
        XCTAssertEqual(frame.event?.finish?.failure?["status"]?.doubleValue, 429)
        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(GatewayFrame.self, from: encoded)
        XCTAssertEqual(decoded.event?.finish?.failure?["message"]?.stringValue, "Rate limited")
    }

    func testHistoricalToolResultRetainsTextOutputAndFailure() throws {
        let source = #"{"kind":"history","events":[{"type":"tool/result","seq":1,"time":1,"data":{"message":{"toolCallId":"c","isError":true,"content":[{"type":"text","text":"raw stderr"}]},"output":"[stderr]\nOperation not permitted\n[exit code: 1]","outputTruncated":true,"error":{"message":"Permission denied","code":"DENIED"}}}]}"#
        let frame = try GatewayWireDecoder.decode(Data(source.utf8))
        let record = try XCTUnwrap(frame.events?.first).normalized(sessionId: "s")
        XCTAssertEqual(record.event.callId, "c")
        XCTAssertEqual(record.event.preview, "raw stderr")
        XCTAssertEqual(record.event.isError, true)
        XCTAssertEqual(record.event.outputTruncated, true)
        XCTAssertTrue(record.event.output?.contains("[exit code: 1]") == true)
        XCTAssertEqual(record.event.error, "Permission denied")
    }

    func testHistoricalRetryAndTurnErrorRetainStructuredDetails() throws {
        let source = #"{"kind":"history","events":[{"type":"llm/retry","seq":1,"time":1,"data":{"turn":1,"step":0,"retryId":"r","retry":2,"maxRetries":5,"delayMs":1000,"failure":{"message":"Rate limited","code":"RATE_LIMIT","status":429}}},{"type":"turn/end","seq":2,"time":2,"data":{"turn":1,"reason":{"kind":"error","error":{"message":"Service unavailable","code":"TRANSPORT","status":503}}}}]}"#
        let frame = try GatewayWireDecoder.decode(Data(source.utf8))
        let records = try XCTUnwrap(frame.events).map { $0.normalized(sessionId: "s") }
        XCTAssertEqual(records[0].event.retryId, "r")
        XCTAssertEqual(records[0].event.retry, 2)
        XCTAssertEqual(records[0].event.maxRetries, 5)
        XCTAssertEqual(records[0].event.failure?["status"]?.doubleValue, 429)
        XCTAssertEqual(records[1].event.reason, "error")
        XCTAssertEqual(records[1].event.reasonDetails?["error"]?["message"]?.stringValue, "Service unavailable")
        let bridged = try JSONEncoder().encode(records)
        XCTAssertTrue(String(decoding: bridged, as: UTF8.self).contains("Service unavailable"))
    }
}

@MainActor
final class ConversationFileReferencesTests: XCTestCase {
    func testFilesSurviveNativeGatewayAndKMPBridge() throws {
        let json = #"{"kind":"event","sessionId":"s1","seq":2,"time":1,"event":{"type":"deliverables/presented","turn":1,"callId":"p1","files":[{"path":"build/报告.pdf","description":"8 页"}]}}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        let adapter = KMPConversationStoreAdapter()
        try adapter.receive(SessionEvent(sessionId: "s1", seq: 1, time: 1,
            event: GatewayEvent(type: "assistant/message", turn: 1, step: 1, text: "报告")))
        try adapter.receive(SessionEvent(sessionId: "s1", seq: 2, time: 1, event: try XCTUnwrap(frame.event)))
        let file = try XCTUnwrap(adapter.items(for: "s1").first?.files.first)
        XCTAssertEqual(file.path, "build/报告.pdf")
        XCTAssertEqual(file.description, "8 页")
        XCTAssertEqual(adapter.items(for: "s1").first?.knownFiles, [file])
    }

    func testInlineReferenceTransformationOnlyChangesInlineCodeOutsideLinks() {
        let document = MarkdownUI.MarkdownContent("`report.pdf` [existing `report.pdf`](https://example.com)\n\n```\nreport.pdf\n```")
        let html = document.linkingInlineCode(["report.pdf": "dsh-file-reference:///0"]).renderHTML()
        XCTAssertEqual(html.components(separatedBy: "href=\"dsh-file-reference:///0\"").count - 1, 1)
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
        XCTAssertTrue(html.contains("<pre><code>report.pdf"))
    }
}


@MainActor
final class WorkspaceFilePreviewPresentationTests: XCTestCase {
    private let digest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    private let item = GatewayDirectoryItem(name: "a.txt", path: "a.txt", kind: "file", bytes: 5)

    func testRequestPresentsImmediatelyAndKeepsIdentityThroughDownload() async throws {
        let store = await makeStore()
        defer { store.cancelWorkspaceFileDownload() }
        store.openWorkspaceFile(item, purpose: "preview")
        let request = try XCTUnwrap(store.workspaceFilePreviewRequest)
        XCTAssertTrue(store.conversationFileIsOpening)
        XCTAssertEqual(store.workspaceFilePreviewProgress, 0)
        XCTAssertNil(store.completedWorkspaceFile)
        try opened(store, requestID: request.id.uuidString)
        try deliver(store, #"{"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"aGVs","eof":false}"#)
        XCTAssertEqual(store.workspaceFileDownloadProgress, 0.6)
        XCTAssertEqual(store.workspaceFilePreviewProgress, 0.6)
        XCTAssertEqual(store.workspaceFilePreviewRequest?.id, request.id)
        XCTAssertNil(store.completedWorkspaceFile)
        try deliver(store, """
            {"kind":"file-download-chunk","transferId":"t1","offset":3,"data":"bG8=","eof":true,"sha256":"\(digest)"}
            """)
        try await waitForCompletion(store)
        XCTAssertEqual(store.workspaceFilePreviewRequest?.id, request.id)
        XCTAssertFalse(store.conversationFileIsOpening)
        XCTAssertEqual(store.workspaceFilePreviewProgress, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(store.completedWorkspaceFile).url, encoding: .utf8), "hello")
    }

    func testCompletedTemporaryPreviewLivesUntilQuickLookReleasesIt() async throws {
        let store = await makeStore()
        defer { store.deactivateGateway() }
        store.openWorkspaceFile(item, purpose: "preview")
        let request = try XCTUnwrap(store.workspaceFilePreviewRequest)
        try opened(store, requestID: request.id.uuidString)
        try deliver(store, """
            {"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"aGVsbG8=","eof":true,"sha256":"\(digest)"}
            """)
        try await waitForCompletion(store)
        let file = try XCTUnwrap(store.completedWorkspaceFile).url
        XCTAssertTrue(file.path.hasPrefix(WorkspacePreviewCache.temporaryRoot.path))
        var reader: WorkspaceQuickLookPreview.Coordinator? = .init(url: file)
        XCTAssertNotNil(reader)
        store.cancelWorkspaceFileDownload()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "关闭动画中 QuickLook 仍持有读租约")
        reader = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testClosingMidDownloadIgnoresLateChunkAndAllowsReopening() async throws {
        let store = await makeStore()
        defer { store.cancelWorkspaceFileDownload() }
        store.openWorkspaceFile(item, purpose: "preview")
        let request = try XCTUnwrap(store.workspaceFilePreviewRequest)
        try opened(store, requestID: request.id.uuidString)
        try deliver(store, #"{"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"aGVs","eof":false}"#)
        store.cancelWorkspaceFileDownload()
        XCTAssertNil(store.workspaceFilePreviewRequest)
        XCTAssertEqual(store.workspaceFilePreviewProgress, 0)
        XCTAssertNil(store.workspaceFileDownloadProgress)
        XCTAssertFalse(store.conversationFileIsOpening)
        try deliver(store, """
            {"kind":"file-download-chunk","transferId":"t1","offset":3,"data":"bG8=","eof":true,"sha256":"\(digest)"}
            """)
        XCTAssertNil(store.completedWorkspaceFile)
        store.openWorkspaceFile(item, purpose: "preview")
        let reopened = try XCTUnwrap(store.workspaceFilePreviewRequest)
        XCTAssertNotEqual(request.id, reopened.id)
        try opened(store, requestID: reopened.id.uuidString)
        try deliver(store, """
            {"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"aGVsbG8=","eof":true,"sha256":"\(digest)"}
            """)
        try await waitForCompletion(store)
        store.cancelWorkspaceFileDownload()
        XCTAssertNil(store.workspaceFilePreviewRequest)
        XCTAssertNil(store.completedWorkspaceFile)
    }

    func testClosingDuringCacheLookupDoesNotReopenAndNextTapUsesCache() async throws {
        let store = await makeStore()
        defer { store.cancelWorkspaceFileDownload() }
        try deliver(store, #"{"kind":"hello","protocol":3,"capabilities":["file-downloads","file-references-v1"]}"#)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let cache = WorkspacePreviewCache(gatewayID: store.gatewayLocalID)
        let entry = WorkspacePreviewCacheEntry(sessionID: "preview-session", path: "a.txt", name: "a.txt",
                                              size: 5, modifiedAt: 10.5, sha256: digest)
        let cachedURL = try XCTUnwrap(cache.store(source, entry: entry))
        defer { try? FileManager.default.removeItem(at: cachedURL.deletingLastPathComponent()) }
        store.openWorkspaceFile(item, purpose: "preview")
        let first = try XCTUnwrap(store.workspaceFilePreviewRequest)
        try resolved(store, requestID: first.id.uuidString)
        store.cancelWorkspaceFileDownload()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(store.workspaceFilePreviewRequest)
        XCTAssertNil(store.completedWorkspaceFile)
        store.openWorkspaceFile(item, purpose: "preview")
        let second = try XCTUnwrap(store.workspaceFilePreviewRequest)
        try resolved(store, requestID: second.id.uuidString)
        try await waitForCompletion(store)
        XCTAssertEqual(store.completedWorkspaceFile?.url, cachedURL)
        XCTAssertEqual(store.workspaceFilePreviewRequest?.id, second.id)
    }

    func testLoadingSheetStaysPresentedWhenContentBecomesReady() async throws {
        let store = await makeStore()
        let host = UIHostingController(rootView: WorkspacePreviewPresentationHarness(store: store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            store.cancelWorkspaceFileDownload()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.layoutIfNeeded()
        store.openWorkspaceFile(item, purpose: "preview")
        let request = try XCTUnwrap(store.workspaceFilePreviewRequest)
        for _ in 0..<100 {
            if host.presentedViewController != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try XCTUnwrap(host.presentedViewController)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(store.conversationFileIsOpening, "弹窗展示不能触发父页面消失后误取消")
        XCTAssertNil(store.completedWorkspaceFile)
        for _ in 0..<100 {
            if logoPlayer(in: sheet.view) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let player = try XCTUnwrap(logoPlayer(in: sheet.view))
        XCTAssertEqual(player.animationImages?.count, 48)
        XCTAssertEqual(player.animationDuration, 2.4, accuracy: 0.001)
        XCTAssertTrue(player.isAnimating)
        let loading = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        loading.name = "文件预览：先显示加载面板"
        loading.lifetime = .keepAlways
        add(loading)
        try opened(store, requestID: request.id.uuidString)
        try deliver(store, """
            {"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"aGVsbG8=","eof":true,"sha256":"\(digest)"}
            """)
        try await waitForCompletion(store)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(host.presentedViewController === sheet, "加载完成应更新内容，不能重新弹出面板")
        XCTAssertFalse(player.isAnimating, "预览就绪后应停止 Logo 动画")
        XCTAssertEqual(store.workspaceFilePreviewRequest?.id, request.id)
        store.cancelWorkspaceFileDownload()
        XCTAssertNil(store.workspaceFilePreviewRequest)
        for _ in 0..<100 {
            if host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(host.presentedViewController)
    }

    func testFailedDownloadEndsLoadingAndSheetRemainsClosable() async throws {
        let store = await makeStore()
        defer { store.cancelWorkspaceFileDownload() }
        store.openWorkspaceFile(item, purpose: "preview")
        let request = try XCTUnwrap(store.workspaceFilePreviewRequest)
        try deliver(store, """
            {"kind":"error","requestType":"file-download-open","requestId":"\(request.id.uuidString)","message":"missing-file"}
            """)
        XCTAssertFalse(store.conversationFileIsOpening)
        XCTAssertNotNil(store.lastError)
        XCTAssertNotNil(store.workspaceFilePreviewRequest)
        XCTAssertNil(store.completedWorkspaceFile)
    }

    func testLogoApngKeepsAlphaTimingAndStopsWhenPlaybackDisabled() async throws {
        let animation = try XCTUnwrap(WorkspaceLoadingLogoAnimation.shared)
        XCTAssertEqual(animation.frames.count, 48)
        XCTAssertEqual(animation.duration, 2.4, accuracy: 0.001)
        XCTAssertEqual(animation.frames.first?.cgImage?.width, 192)
        XCTAssertEqual(animation.frames.first?.cgImage?.height, 192)
        XCTAssertNotEqual(animation.frames[0].pngData(), animation.frames[12].pngData())
        let host = UIHostingController(rootView: WorkspaceLoadingLogoPlayer(animation: animation, plays: false))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        for _ in 0..<100 {
            if logoPlayer(in: host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let player = try XCTUnwrap(logoPlayer(in: host.view))
        XCTAssertFalse(player.isAnimating)
    }

    private func logoPlayer(in view: UIView) -> UIImageView? {
        if let image = view as? UIImageView, image.accessibilityIdentifier == "workspace-loading-logo-player" {
            return image
        }
        return view.subviews.lazy.compactMap { self.logoPlayer(in: $0) }.first
    }

    private func makeStore() async -> AppStore {
        let session = SessionSummary(id: "preview-session", title: "Preview", lastActivity: Date(),
                                     isRunning: false, hasUnread: false)
        let store = AppStore(preferences: AppPreferencesSpy(endpoint: "", selectedWorkspaceID: nil, sessions: [session]),
                             gatewayLocalID: "preview-test-\(UUID().uuidString)")
        _ = await store.prepareConversation(for: session)
        return store
    }

    private func deliver(_ store: AppStore, _ json: String) throws {
        store.gateway.onFrame?(try GatewayWireDecoder.decode(Data(json.utf8)))
    }

    private func opened(_ store: AppStore, requestID: String) throws {
        try deliver(store, """
            {"kind":"file-download-opened","requestId":"\(requestID)","transferId":"t1","sessionId":"preview-session","path":"a.txt","name":"a.txt","mediaType":"text/plain","size":5,"chunkBytes":100}
            """)
    }

    private func resolved(_ store: AppStore, requestID: String) throws {
        try deliver(store, """
            {"kind":"file-resolved","requestId":"\(requestID)","sessionId":"preview-session","path":"a.txt","name":"a.txt","mediaType":"text/plain","size":5,"modifiedAt":10.5}
            """)
    }

    private func waitForCompletion(_ store: AppStore) async throws {
        for _ in 0..<100 {
            if store.completedWorkspaceFile != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("文件应在原有弹窗中完成预览：\(store.lastError ?? "无错误")")
    }
}

private struct WorkspacePreviewPresentationHarness: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Color.white.sheet(item: Binding(
            get: { store.workspaceFilePreviewRequest },
            set: { if $0 == nil { store.cancelWorkspaceFileDownload() } }
        )) { request in
            WorkspaceFilePreviewLoadingSheet(store: store, request: request)
                .environment(\.scenePhase, .active)
        }
    }
}

#if DEBUG
@MainActor
final class DebugHistoryRowMeasurementTests: XCTestCase {
    func testDisabledRowRecorderCreatesNoScopeOrRecords() {
        let recorder = DebugHistoryRowMeasurements(enabled: false)
        XCTAssertNil(recorder.begin(rowID: "private-session-message", kind: "hosted", widthPoints: 320,
                                    source: "history_preparation", reportStartedAt: 0, loadOrdinal: 1))
        XCTAssertNil(DebugHistoryRowMeasurements.activeScope)
        XCTAssertTrue(recorder.seal().isEmpty)
        XCTAssertFalse(recorder.limitReached)
    }

    func testNestedScopesRestoreParentAndSerializeOnlyAnonymousRowMetadata() throws {
        let recorder = DebugHistoryRowMeasurements(enabled: true)
        let originalID = "private-session-message"
        let outer = try XCTUnwrap(recorder.begin(rowID: originalID, kind: "hosted", widthPoints: 324.25,
                                                source: "history_preparation", reportStartedAt: 0, loadOrdinal: 2))
        defer { outer.finish() }
        let create = outer.startStage()
        outer.finishStage("host_create", startedAt: create)
        let inner = try XCTUnwrap(recorder.begin(rowID: "nested-row", kind: "user_message", widthPoints: 324.25,
                                                source: "viewport_prewarm", reportStartedAt: 0, loadOrdinal: nil))
        inner.finish()
        XCTAssertTrue(DebugHistoryRowMeasurements.activeScope === outer)
        outer.finish()
        XCTAssertNil(DebugHistoryRowMeasurements.activeScope)
        let records = recorder.seal()
        XCTAssertEqual(records.map(\.stage), ["host_create", "total", "total"])
        XCTAssertEqual(records[0].rowHash, records[2].rowHash)
        XCTAssertNotEqual(records[0].rowHash, records[1].rowHash)
        XCTAssertEqual(records[2].widthPoints, 324.25)
        XCTAssertEqual(records[2].loadOrdinal, 2)
        XCTAssertTrue(records.allSatisfy { $0.durationMs.isFinite && $0.durationMs >= 0 })
        let data = try JSONEncoder().encode(records)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(originalID))
        XCTAssertFalse(text.contains("nested-row"))
        let decoded = try JSONDecoder().decode([DebugHistoryRowMeasurements.Measurement].self, from: data)
        XCTAssertEqual(decoded.map(\.rowHash), records.map(\.rowHash))
        XCTAssertEqual(decoded[2].source, "history_preparation")
    }

    func testRowBufferHasIndependentLimitAndRejectsWritesAfterSeal() throws {
        let recorder = DebugHistoryRowMeasurements(enabled: true, countLimit: 2)
        for id in ["first", "second"] {
            let scope = try XCTUnwrap(recorder.begin(rowID: id, kind: "hosted", widthPoints: 320,
                                                    source: "history_preparation", reportStartedAt: 0, loadOrdinal: 1))
            scope.finish()
            scope.finish()
        }
        XCTAssertNil(recorder.begin(rowID: "overflow", kind: "hosted", widthPoints: 320,
                                    source: "history_preparation", reportStartedAt: 0, loadOrdinal: 1))
        XCTAssertTrue(recorder.limitReached)
        XCTAssertEqual(recorder.seal().count, 2)
        XCTAssertNil(recorder.begin(rowID: "after-seal", kind: "hosted", widthPoints: 320,
                                    source: "history_preparation", reportStartedAt: 0, loadOrdinal: 1))
        XCTAssertEqual(recorder.measurements.count, 2)
        XCTAssertNil(DebugHistoryRowMeasurements.activeScope)
    }
}
#endif

@MainActor
final class HistoryPresentationAdmissionTests: XCTestCase {
    private func begin(_ owner: HistoryPresentationAdmission, consumerID: UUID, minimumSequence: Int64 = 0) throws -> UUID {
        try XCTUnwrap(owner.begin(sessionID: "s", consumerID: consumerID, domainLoading: false,
            hasMore: true, producerBusy: false, minimumHistoryEventSequence: minimumSequence))
    }

    func testTwoPageBatchWaitsForTerminalAndFinalActualPresentation() throws {
        let owner = HistoryPresentationAdmission()
        let consumerID = UUID()
        var outcomes: [HistoryPresentationOutcome] = []
        owner.attach(sessionID: "s", consumer: .init(id: consumerID) { if case .finished(_, let outcome) = $0 { outcomes.append(outcome) } })
        _ = try begin(owner, consumerID: consumerID)
        owner.requireProjection(sessionID: "s", epoch: 1, historyEventSequence: 1)
        let first = try XCTUnwrap(owner.stamp(sessionID: "s", committedEpoch: 1))
        owner.acknowledge(sessionID: "s", consumerID: consumerID, stamp: first, domainLoading: true)
        XCTAssertTrue(owner.isPending(sessionID: "s"))
        XCTAssertNil(owner.begin(sessionID: "s", consumerID: consumerID, domainLoading: false, hasMore: true, producerBusy: false))
        owner.requireProjection(sessionID: "s", epoch: 2, historyEventSequence: 2)
        owner.terminal(sessionID: "s", domainLoading: false, historyEventSequence: 2)
        owner.acknowledge(sessionID: "s", consumerID: consumerID, stamp: first, domainLoading: false)
        XCTAssertTrue(owner.isPending(sessionID: "s"), "第一内部页已呈现，不能解锁第二页尚未呈现的 batch")
        XCTAssertNil(owner.stamp(sessionID: "s", committedEpoch: 1), "旧 baseline 上的 live token 不能证明新历史已提交")
        let final = try XCTUnwrap(owner.stamp(sessionID: "s", committedEpoch: 2))
        owner.acknowledge(sessionID: "s", consumerID: consumerID, stamp: final, domainLoading: false)
        XCTAssertFalse(owner.isPending(sessionID: "s"))
        XCTAssertEqual(outcomes, [.presented])
    }

    func testStaleQueuedTerminalOldConsumerAndUnissuedFutureCannotReleaseOperation() throws {
        let owner = HistoryPresentationAdmission()
        let consumerID = UUID()
        owner.attach(sessionID: "s", consumer: .init(id: consumerID, onEvent: { _ in }))
        let old = try begin(owner, consumerID: consumerID)
        owner.cancel(sessionID: "s")
        let current = try begin(owner, consumerID: consumerID, minimumSequence: 10)
        owner.requireProjection(sessionID: "s", epoch: 1, historyEventSequence: 9)
        owner.terminal(sessionID: "s", domainLoading: false, historyEventSequence: 9)
        XCTAssertTrue(owner.isPending(sessionID: "s"))
        owner.requireProjection(sessionID: "s", epoch: 2, historyEventSequence: 10)
        owner.terminal(sessionID: "s", domainLoading: false, historyEventSequence: 11)
        owner.acknowledge(sessionID: "s", consumerID: consumerID,
            stamp: .init(operationID: current, projectionEpoch: 999), domainLoading: false)
        owner.cancel(sessionID: "s", operationID: old)
        let valid = try XCTUnwrap(owner.stamp(sessionID: "s", committedEpoch: 2))
        owner.acknowledge(sessionID: "s", consumerID: UUID(), stamp: valid, domainLoading: false)
        owner.acknowledge(sessionID: "s", consumerID: consumerID,
            stamp: .init(operationID: old, projectionEpoch: 2), domainLoading: false)
        XCTAssertTrue(owner.matches(sessionID: "s", operationID: current))
        owner.acknowledge(sessionID: "s", consumerID: consumerID, stamp: valid, domainLoading: false)
        XCTAssertFalse(owner.isPending(sessionID: "s"))
    }

    func testAckBeforeTerminalThenEmptyFailureDetachAndReattachDoNotStick() throws {
        let owner = HistoryPresentationAdmission()
        let consumerID = UUID()
        var outcomes: [HistoryPresentationOutcome] = []
        owner.attach(sessionID: "s", consumer: .init(id: consumerID) { if case .finished(_, let outcome) = $0 { outcomes.append(outcome) } })
        _ = try begin(owner, consumerID: consumerID)
        owner.requireProjection(sessionID: "s", epoch: 1, historyEventSequence: 1)
        owner.acknowledge(sessionID: "s", consumerID: consumerID,
            stamp: try XCTUnwrap(owner.stamp(sessionID: "s", committedEpoch: 1)), domainLoading: false)
        XCTAssertTrue(owner.isPending(sessionID: "s"))
        owner.terminal(sessionID: "s", domainLoading: false)
        _ = try begin(owner, consumerID: consumerID)
        owner.terminal(sessionID: "s", domainLoading: false)
        _ = try begin(owner, consumerID: consumerID)
        owner.terminal(sessionID: "s", domainLoading: false, failure: .failed)
        _ = try begin(owner, consumerID: consumerID)
        owner.detach(sessionID: "s", consumerID: UUID())
        XCTAssertTrue(owner.isPending(sessionID: "s"))
        owner.attach(sessionID: "s", consumer: .init(id: UUID(), onEvent: { _ in }))
        XCTAssertFalse(owner.isPending(sessionID: "s"))
        XCTAssertEqual(outcomes, [.presented, .empty, .failed, .detached])
    }

    func testReservedOperationDoesNotCountStartNoopAndCacheNetworkActivationIsOnce() throws {
        let owner = HistoryPresentationAdmission()
        let consumer = UUID()
        var accepted = 0
        var rejected = 0
        owner.attach(sessionID: "s", consumer: .init(id: consumer) {
            if case .began = $0 { accepted += 1 }
            if case .rejected = $0 { rejected += 1 }
        })
        let noop = try XCTUnwrap(owner.begin(sessionID: "s", consumerID: consumer, domainLoading: false,
            hasMore: true, producerBusy: false, activate: false))
        XCTAssertEqual(accepted, 0)
        owner.terminal(sessionID: "s", domainLoading: false, operationID: noop)
        XCTAssertEqual(rejected, 1)
        XCTAssertFalse(owner.isPending(sessionID: "s"))
        let cache = try XCTUnwrap(owner.begin(sessionID: "s", consumerID: consumer, domainLoading: false,
            hasMore: true, producerBusy: false, activate: false))
        owner.accept(sessionID: "s", operationID: cache)
        owner.accept(sessionID: "s", operationID: cache)
        XCTAssertEqual(accepted, 1)
        XCTAssertTrue(owner.isPending(sessionID: "s"))
        owner.cancel(sessionID: "s")
    }

    func testDomainAndProducerGuardsRejectBeforeCreatingOperation() {
        let owner = HistoryPresentationAdmission()
        let id = UUID()
        var reasons: [String] = []
        owner.attach(sessionID: "s", consumer: .init(id: id) { if case .rejected(let reason) = $0 { reasons.append(reason) } })
        XCTAssertNil(owner.begin(sessionID: "s", consumerID: id, domainLoading: true, hasMore: true, producerBusy: false))
        XCTAssertNil(owner.begin(sessionID: "s", consumerID: id, domainLoading: false, hasMore: false, producerBusy: false))
        XCTAssertNil(owner.begin(sessionID: "s", consumerID: id, domainLoading: false, hasMore: true, producerBusy: true))
        XCTAssertFalse(owner.isPending(sessionID: "s"))
        XCTAssertEqual(reasons, ["domain_loading", "no_more_history", "projection_pending"])
    }

    func testTimelineKeepsHistoricalStampAcrossLiveAndImagePublishUntilMatchingFinish() {
        let timeline = ConversationTimeline()
        let stamp = HistoryPresentationStamp(operationID: UUID(), projectionEpoch: 3)
        timeline.publish([], historyPresentationStamp: stamp)
        timeline.publish([])
        XCTAssertEqual(timeline.currentSnapshot.historyPresentationStamp, stamp)
        timeline.clearHistoryPresentationStamp(operationID: UUID())
        XCTAssertEqual(timeline.currentSnapshot.historyPresentationStamp, stamp)
        timeline.clearHistoryPresentationStamp(operationID: stamp.operationID)
        XCTAssertNil(timeline.currentSnapshot.historyPresentationStamp)
    }

    func testViewportDoesNotAcknowledgeDeferredSnapshotUntilActualCommit() async throws {
        let controller = ConversationViewportController(onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in }, onBottomAlignmentCompleted: {}, onApproachingTop: {})
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            controller.onHistoryPresented = { _, _, _ in }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let timeline = ConversationTimeline()
        func item(_ index: Int) -> ConversationItem {
            .init(id: "row-\(index)", kind: .user, title: "", text: "\(index)", isError: false, date: Date(timeIntervalSince1970: Double(index)))
        }
        timeline.publish((10..<30).map(item))
        controller.configure(sessionID: "s", timeline: timeline, supplementalEntries: [], makeEntries: { items in
            items.map { .init(id: $0.id, revision: 0, content: AnyView(Text($0.text).frame(height: 60))) }
        }, bottomInset: 0)
        func findList(_ view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            return view.subviews.lazy.compactMap { findList($0) }.first
        }
        let list = try XCTUnwrap(findList(controller.view))
        for _ in 0..<200 {
            controller.view.layoutIfNeeded()
            if list.numberOfSections > 0, list.numberOfItems(inSection: 0) == 20 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(list.numberOfSections, 1)
        guard list.numberOfSections == 1 else { return }
        XCTAssertEqual(list.numberOfItems(inSection: 0), 20)
        list.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        controller.scrollViewWillBeginDragging(list)
        let stamp = HistoryPresentationStamp(operationID: UUID(), projectionEpoch: 1)
        var acknowledgments = 0
        controller.onHistoryPresented = { session, consumer, actual in
            XCTAssertEqual(session, "s")
            XCTAssertEqual(consumer, controller.historyPresentationConsumerID)
            XCTAssertEqual(actual, stamp)
            XCTAssertEqual(list.numberOfItems(inSection: 0), 30, "必须等真实 diffable 提交后才 ack")
            acknowledgments += 1
        }
        timeline.publish((0..<30).map(item), historyPresentationStamp: stamp)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(acknowledgments, 0)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 20)
        controller.scrollViewDidEndDragging(list, willDecelerate: false)
        for _ in 0..<200 where acknowledgments == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(acknowledgments, 0)
        controller.onHistoryPresented = { _, _, _ in }
    }
}

#if DEBUG
@MainActor
final class DebugHistoryCommitDiagnosticsTests: XCTestCase {
    func testDefaultOffDoesNotReadClockOrEmit() {
        var clocks = 0, lines: [String] = []
        for environment in [[:], ["DSH_HISTORY_COMMIT_DIAGNOSTICS": "0"]] {
            let diagnostics = DebugHistoryCommitDiagnostics(environment: environment, clock: { clocks += 1; return 0 }, sink: { lines.append($0) })
            for _ in 0..<100 { XCTAssertNil(diagnostics.begin(ordinal: 1, rowCount: 4, insertedRows: 2)) }
        }
        XCTAssertEqual(clocks, 0)
        XCTAssertTrue(lines.isEmpty)
    }
    func testExplicitOptInCountsWithoutIdentifiersAndHonorsBudgets() throws {
        var now = 10.0
        var lines: [String] = []
        let diagnostics = DebugHistoryCommitDiagnostics(environment: ["DSH_HISTORY_COMMIT_DIAGNOSTICS": "1"],
            recordLimit: 1, clock: { now }, sink: { lines.append($0) })
        let record = try XCTUnwrap(diagnostics.begin(ordinal: 3, rowCount: 20, insertedRows: 5))
        let cell = NSObject()
        record.observeHost(cell, created: true)
        record.observeHost(cell, created: false)
        record.observeHost(cell, created: false)
        record.observeCorrection(previous: 10, height: 12)
        now = 10.025
        record.emit(.completionFlush, since: 10)
        let line = try XCTUnwrap(lines.last)
        XCTAssertTrue(line.contains("ordinal=3"))
        XCTAssertTrue(line.contains("duration_ms=25.000"))
        XCTAssertTrue(line.contains("host_create=1 host_reconfigure=2"))
        XCTAssertTrue(line.contains("height_changes=1"))
        XCTAssertTrue(line.contains("max_delta_pt=2.000"))
        XCTAssertFalse(line.contains(String(describing: ObjectIdentifier(cell))))
        for _ in 0..<100 { record.emit(.anchorLayout, since: 10) }
        XCTAssertEqual(lines.count, 13, "单commit最多12条+一条明确log_limit")
        for _ in 0..<100 { XCTAssertNil(diagnostics.begin(ordinal: 4, rowCount: 20, insertedRows: 1)) }
        XCTAssertEqual(lines.count, 14, "总record超预算仅一条record_limit")
    }
}
#endif

#if DEBUG
/// 独立空窗口调度参考；不使用产品指标 helper，不是聊天性能验收。
@MainActor
private final class IdleDisplayLinkCalibrationProbe: NSObject {
    struct Sample: Codable {
        let arrival: Double
        let displayTimestamp: Double
        let targetTimestamp: Double
        let duration: Double
        let arrivalIntervalMs: Double?
        let displayIntervalMs: Double?
    }
    private var link: CADisplayLink?
    private let settleUntil: Double
    private let completed: () -> Void
    private var collectionStarted: Double?
    private(set) var samples: [Sample] = []
    private(set) var stopReason = "not_started"
    init(completed: @escaping () -> Void) {
        self.completed = completed
        settleUntil = CACurrentMediaTime() + 2
        super.init()
        samples.reserveCapacity(4_000)
    }
    func start() {
        stopReason = "collecting"
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        // 与产品一致，保留系统默认刷新率策略，不设置 preferredFrameRateRange。
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now >= settleUntil else { return }
        if collectionStarted == nil { collectionStarted = now }
        let previous = samples.last
        samples.append(Sample(arrival: now, displayTimestamp: link.timestamp,
            targetTimestamp: link.targetTimestamp, duration: link.duration,
            arrivalIntervalMs: previous.map { (now - $0.arrival) * 1_000 },
            displayIntervalMs: previous.map { (link.timestamp - $0.displayTimestamp) * 1_000 }))
        if now - (collectionStarted ?? now) >= 25 {
            stopReason = "duration"
            stop()
            completed()
        } else if samples.count >= 6_000 {
            stopReason = "sample_limit"
            stop()
            completed()
        }
    }
    func stop() { link?.invalidate(); link = nil }
}

@MainActor
final class DisplayLinkIdleCalibrationTests: XCTestCase {
    func testIdleMainRunLoopCalibration() async throws {
        guard ProcessInfo.processInfo.environment["DSH_DISPLAYLINK_IDLE_CALIBRATION"] == "1" else {
            throw XCTSkip("仅显式独立运行的25秒空窗口调度校准")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let done = expectation(description: "25秒真实display callback原始采样")
        let probe = IdleDisplayLinkCalibrationProbe { done.fulfill() }
        defer {
            probe.stop()
            window.isHidden = true
            previousWindow?.makeKey()
        }
        let beganUTC = ISO8601DateFormatter().string(from: Date())
        probe.start()
        await fulfillment(of: [done], timeout: 40)
        probe.stop()
        let samples = probe.samples
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func attach(_ data: Data, name: String, type: String) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attach(try encoder.encode(samples), name: "idle-displaylink-raw.json", type: "public.json")
        var csv = "arrival,display_timestamp,target_timestamp,duration,arrival_interval_ms,display_interval_ms\n"
        for sample in samples {
            csv += "\(sample.arrival),\(sample.displayTimestamp),\(sample.targetTimestamp),\(sample.duration),\(sample.arrivalIntervalMs.map { String($0) } ?? ""),\(sample.displayIntervalMs.map { String($0) } ?? "")\n"
        }
        attach(Data(csv.utf8), name: "idle-displaylink-raw.csv", type: "public.comma-separated-values-text")
        func statistics(_ values: [Double]) -> [String: Any] {
            guard !values.isEmpty else { return ["count": 0] }
            let sorted = values.sorted()
            return ["count": values.count, "minimum_ms": sorted[0], "maximum_ms": sorted[sorted.count - 1],
                    "mean_ms": values.reduce(0, +) / Double(values.count),
                    "nearest_rank_p95_ms": sorted[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)],
                    "over_16_7_count": values.filter { $0 > 16.7 }.count,
                    "over_33_3_count": values.filter { $0 > 33.3 }.count,
                    "at_least_100_count": values.filter { $0 >= 100 }.count]
        }
        let duration = (samples.last?.arrival ?? 0) - (samples.first?.arrival ?? 0)
        let summary: [String: Any] = [
            "measurement": "idle XCTest host CADisplayLink callback pacing; not GPU/rendered FPS or chat acceptance",
            "environment": "signed Debug simulator host; original app background work remains possible",
            "began_utc": beganUTC, "process_id": ProcessInfo.processInfo.processIdentifier,
            "system_version": UIDevice.current.systemVersion,
            "screen_maximum_frames_per_second": window.screen.maximumFramesPerSecond,
            "preferred_frame_rate_policy": "system_default_unmodified", "run_loop_mode": "common",
            "fixed_settle_seconds": 2, "requested_collection_seconds": 25,
            "actual_collection_seconds": duration, "stop_reason": probe.stopReason,
            "arrival": statistics(samples.compactMap(\.arrivalIntervalMs)),
            "display_timestamp": statistics(samples.compactMap(\.displayIntervalMs))
        ]
        attach(try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
               name: "idle-displaylink-summary.json", type: "public.json")
        // 仅验证采样完整性，不为调度间隔设置通过门槛或输出性能 pass。
        XCTAssertEqual(probe.stopReason, "duration")
        XCTAssertGreaterThanOrEqual(duration, 25)
        XCTAssertGreaterThan(samples.count, 2)
    }
}
#endif

#if DEBUG
@MainActor
final class ConversationWarmHostTransferTests: XCTestCase {
    private var measurementLists: [ObjectIdentifier: UICollectionView] = [:]
    private func measurementList(_ parent: UIViewController) -> UICollectionView {
        parent.loadViewIfNeeded()
        let key = ObjectIdentifier(parent)
        if let list = measurementLists[key] { return list }
        let list = UICollectionView(frame: parent.view.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        parent.view.addSubview(list)
        measurementLists[key] = list
        return list
    }
    private func context(_ parent: UIViewController, collection: UICollectionView? = nil,
                         session: String = "s", width: CGFloat = 320) -> DebugConversationWarmHostContext {
        parent.loadViewIfNeeded()
        let collection = collection ?? measurementList(parent)
        return .init(owner: ObjectIdentifier(parent), sessionID: session, cacheScope: "g", sessionGeneration: 1,
            width: width, fontSize: UIFont.appPreferredFont(forTextStyle: .body).pointSize,
            ownerTraits: parent.traitCollection, collection: ObjectIdentifier(collection),
            window: collection.window.map(ObjectIdentifier.init), locale: Locale.current.identifier)
    }
    private func entry() -> ConversationViewportEntry {
        .init(id: "same-id", revision: 1, content: AnyView(Text("**completed**")))
    }
    private func prepared(_ parent: UIViewController, source: ConversationViewportEntry? = nil,
                          token: DebugConversationWarmHostToken? = nil, collection: UICollectionView? = nil) -> DebugPreparedConversationHost {
        let entry = source ?? self.entry()
        let token = token ?? entry.warmHostToken ?? DebugConversationWarmHostToken()
        let list = collection ?? measurementList(parent)
        let prepared = DebugPreparedConversationHost(entry: entry, token: token,
            context: context(parent, collection: list), parent: parent, collection: list)
        _ = prepared.measureHeight()
        return prepared
    }
    func testEntryCopyPreservesOpaqueTokenAndNewEntryDoesNotReuseIdentity() throws {
        let original = entry(), copied = original, rebuilt = entry()
        if DebugConversationWarmHostExperiment.enabled {
            XCTAssertNotNil(original.warmHostToken)
            XCTAssertTrue(original.warmHostToken === copied.warmHostToken)
            XCTAssertFalse(original.warmHostToken === rebuilt.warmHostToken)
        } else {
            XCTAssertNil(original.warmHostToken)
            XCTAssertNil(rebuilt.warmHostToken)
        }
    }
    func testPoolConsumesOnceAndRejectsRebuiltTokenAndContextChange() throws {
        let parent = UIViewController(), pool = DebugConversationWarmHostPool(sink: { _ in })
        let value = prepared(parent)
        XCTAssertEqual(value.host.traitCollection, value.renderTraits, "实际预热渲染环境必须等价")
        pool.store(value)
        XCTAssertNil(pool.take(token: .init(), context: value.context))
        let result = try XCTUnwrap(pool.take(token: value.token, context: value.context))
        XCTAssertTrue(result === value)
        XCTAssertNil(pool.take(token: value.token, context: value.context))
        pool.store(value)
        XCTAssertEqual(pool.count, 0, "已消费host不能重新装回池形成双owner")
        let another = prepared(parent)
        pool.store(another)
        XCTAssertNil(pool.take(token: another.token, context: context(parent, session: "new")))
        XCTAssertEqual(pool.count, 0)
        result.discardPreparation()
        let renderOnly = prepared(parent)
        pool.store(renderOnly)
        let measuredRender = try XCTUnwrap(renderOnly.renderTraits)
        renderOnly.host.traitOverrides.userInterfaceStyle = measuredRender.userInterfaceStyle == .dark ? .light : .dark
        renderOnly.host.updateTraitsIfNeeded()
        XCTAssertEqual(parent.traitCollection, renderOnly.context.ownerTraits)
        XCTAssertNotEqual(renderOnly.host.traitCollection, measuredRender)
        XCTAssertNil(pool.take(token: renderOnly.token, context: renderOnly.context), "owner不变也必须拒绝render变化")
        let ownerOnly = prepared(parent)
        pool.store(ownerOnly)
        let retainedRender = try XCTUnwrap(ownerOnly.renderTraits)
        let base = ownerOnly.context
        let nextOwnerTraits = UITraitCollection(traitsFrom: [base.ownerTraits,
            UITraitCollection(userInterfaceStyle: base.ownerTraits.userInterfaceStyle == .dark ? .light : .dark)])
        let nextContext = DebugConversationWarmHostContext(owner: base.owner, sessionID: base.sessionID,
            cacheScope: base.cacheScope, sessionGeneration: base.sessionGeneration, width: base.width,
            fontSize: base.fontSize, ownerTraits: nextOwnerTraits, collection: base.collection,
            window: base.window, locale: base.locale)
        // 逻辑 owner namespace 隔离；不假装物理 owner 改变时 render 不会跟随。
        XCTAssertNotEqual(nextContext.ownerTraits, base.ownerTraits)
        XCTAssertEqual(ownerOnly.host.traitCollection, retainedRender)
        XCTAssertNil(pool.take(token: ownerOnly.token, context: nextContext), "render不变也必须拒绝owner namespace变化")
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertEqual(measurementList(parent).subviews.filter { $0 is HostedConversationCell }.count, 0)
    }
    func testFourHostBudgetClearAndEvictionInvalidateRelays() {
        let parent = UIViewController(), pool = DebugConversationWarmHostPool(sink: { _ in })
        parent.loadViewIfNeeded()
        let baselineChildren = parent.children.count
        let list = measurementList(parent)
        let baselineCarriers = list.subviews.filter { $0 is HostedConversationCell }.count
        let baselineSections = list.numberOfSections
        let baselineSize = list.contentSize
        let baselineVisible = list.visibleCells.count
        var calls = 0
        let first = prepared(parent)
        first.relay.sink = { _ in calls += 1 }
        pool.store(first)
        for _ in 0..<4 { pool.store(prepared(parent)) }
        XCTAssertEqual(pool.count, 4); XCTAssertEqual(pool.peak, 4)
        XCTAssertEqual(pool.evictions, 1)
        XCTAssertEqual(parent.children.count, baselineChildren + 4)
        XCTAssertEqual(list.subviews.filter { $0 is HostedConversationCell }.count, baselineCarriers + 4)
        list.layoutIfNeeded()
        XCTAssertEqual(list.visibleCells.count, baselineVisible)
        XCTAssertEqual(list.numberOfSections, baselineSections)
        XCTAssertEqual(list.contentSize, baselineSize)
        first.relay.report(10)
        XCTAssertEqual(calls, 0)
        let last = prepared(parent)
        last.relay.sink = { _ in calls += 1 }
        pool.store(last)
        pool.clear(); last.relay.report(10)
        XCTAssertEqual(pool.count, 0); XCTAssertEqual(calls, 0)
        XCTAssertEqual(parent.children.count, baselineChildren)
        XCTAssertEqual(list.subviews.filter { $0 is HostedConversationCell }.count, baselineCarriers)
    }
    func testTransferKeepsSameHostAndRootAndReuseRejectsLateHeight() throws {
        let parent = UIViewController(), pool = DebugConversationWarmHostPool(sink: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        parent.view.layoutIfNeeded()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        let source = entry()
        guard source.warmHostToken != nil else { throw XCTSkip("本项移交验证需显式开启warm实验") }
        let value = prepared(parent, source: source)
        let rootView = value.host.view
        pool.store(value)
        let transferred = try XCTUnwrap(pool.take(token: value.token, context: value.context))
        let cell = HostedConversationCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        cell.contentView.frame = cell.bounds
        var reports: [CGFloat] = []
        let list = measurementList(parent)
        list.addSubview(cell)
        XCTAssertTrue(cell.installPreparedHost(transferred, entry: source, parent: parent, collection: list) { _, height in reports.append(height) })
        XCTAssertTrue(value.host.view === rootView)
        XCTAssertEqual(cell.warmHostIdentityForTesting, ObjectIdentifier(value.host))
        XCTAssertTrue(value.host.parent === parent)
        pool.clear()
        XCTAssertTrue(value.host.parent === parent, "pool不能清理已移交的可见host")
        XCTAssertTrue(value.host.view.superview === cell.contentView)
        value.relay.report(44)
        XCTAssertEqual(reports, [44])
        cell.prepareForReuse(); value.relay.report(99)
        XCTAssertEqual(reports, [44])
    }
    func testActualDarkTraitsAreUsedAndWidthMismatchFallsBack() throws {
        let parent = UIViewController(), pool = DebugConversationWarmHostPool(sink: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        parent.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        parent.view.layoutIfNeeded()
        parent.updateTraitsIfNeeded()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        let source = entry()
        guard source.warmHostToken != nil else { throw XCTSkip("本项移交验证需显式开启warm实验") }
        let coldCell = HostedConversationCell(frame: CGRect(x: 0, y: 100, width: 320, height: 60))
        coldCell.contentView.frame = coldCell.bounds
        let list = measurementList(parent)
        list.addSubview(coldCell)
        coldCell.apply(source, parent: parent) { _, _ in }
        parent.children.forEach { $0.updateTraitsIfNeeded() }
        XCTAssertEqual(coldCell.hostedTraitsForTesting?.userInterfaceStyle, .dark,
                       "冷host控制组必须实际继承真实window的dark环境")
        let value = prepared(parent, source: source)
        XCTAssertEqual(value.host.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(value.host.traitCollection, coldCell.hostedTraitsForTesting)
        pool.store(value)
        let transferred = try XCTUnwrap(pool.take(token: source.warmHostToken, context: value.context))
        let cell = HostedConversationCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        cell.contentView.frame = cell.bounds
        list.addSubview(cell)
        XCTAssertTrue(cell.installPreparedHost(transferred, entry: source, parent: parent, collection: list) { _, _ in })
        XCTAssertFalse(value.host.traitOverrides.contains(UITraitUserInterfaceStyle.self))
        XCTAssertFalse(value.host.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        parent.overrideUserInterfaceStyle = .light
        parent.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        parent.updateTraitsIfNeeded()
        parent.children.forEach { $0.updateTraitsIfNeeded() }
        XCTAssertEqual(value.host.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(value.host.traitCollection.preferredContentSizeCategory, .accessibilityExtraLarge)
        XCTAssertEqual(value.host.traitCollection, coldCell.hostedTraitsForTesting,
                       "转移后的环境更新必须与原冷host路径一致")
        let next = prepared(parent)
        pool.store(next)
        XCTAssertNil(pool.take(token: next.token, context: context(parent, width: 300)))
        XCTAssertEqual(pool.count, 0)
    }
    func testRealCellProviderObservesUnattachedInstallationAndPreservesFinalEnvironment() async throws {
        let parent = UIViewController(), pool = DebugConversationWarmHostPool(sink: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        parent.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        parent.view.layoutIfNeeded()
        defer { pool.clear(); window.isHidden = true; previousWindow?.makeKey() }
        let source = entry()
        guard source.warmHostToken != nil else { throw XCTSkip("本项provider顺序验证需显式开启warm实验") }
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 320, height: 60)
        let list = UICollectionView(frame: parent.view.bounds, collectionViewLayout: layout)
        list.register(HostedConversationCell.self, forCellWithReuseIdentifier: "provider-host")
        parent.view.addSubview(list)
        let candidate = prepared(parent, source: source, collection: list)
        pool.store(candidate)
        var warmCell: HostedConversationCell?, coldCell: HostedConversationCell?
        var providerDiagnostic: [String: Any] = [:]
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: list) { collection, path, id in
            let cell = collection.dequeueReusableCell(withReuseIdentifier: "provider-host", for: path) as! HostedConversationCell
            let wasAttached = cell.window != nil
            if id == "warm" {
                warmCell = cell
                let prepared = pool.take(token: source.warmHostToken, context: candidate.context)
                XCTAssertNotNil(prepared)
                if let prepared {
                    let installed = cell.installPreparedHost(prepared, entry: source, parent: parent, collection: collection) { _, _ in }
                    XCTAssertEqual(cell.lastWarmTargetWasAttached, wasAttached)
                    if !installed { XCTAssertNotNil(cell.lastWarmTransferFailure) }
                    providerDiagnostic = ["installed": installed, "target_attached": cell.lastWarmTargetWasAttached,
                        "failure": cell.lastWarmTransferFailure?.rawValue ?? "none", "trait_changes": cell.lastWarmTraitDifferences]
                }
            } else {
                coldCell = cell
                cell.apply(source, parent: parent) { _, _ in }
            }
            return cell
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0]); snapshot.appendItems(["warm", "cold"])
        let applied = expectation(description: "真实collection provider完成")
        dataSource.apply(snapshot, animatingDifferences: false) { applied.fulfill() }
        await fulfillment(of: [applied], timeout: 3)
        list.layoutIfNeeded()
        parent.children.forEach { $0.updateTraitsIfNeeded() }
        let warm = try XCTUnwrap(warmCell), cold = try XCTUnwrap(coldCell)
        XCTAssertNotNil(warm.window); XCTAssertNotNil(cold.window)
        XCTAssertEqual(warm.hostedTraitsForTesting, cold.hostedTraitsForTesting)
        XCTAssertEqual(warm.hostedTraitsForTesting?.userInterfaceStyle, .dark)
        XCTAssertEqual(pool.count, 0)
        XCTAssertEqual(parent.children.count, 2, "prepared必须移交或移除，不能泄漏第三个host")
        providerDiagnostic["owner_traits_description"] = candidate.context.ownerTraits.description
        providerDiagnostic["measured_render_traits_description"] = candidate.renderTraits?.description ?? "missing"
        providerDiagnostic["attached_warm_traits_description"] = warm.hostedTraitsForTesting?.description ?? "missing"
        providerDiagnostic["attached_cold_traits_description"] = cold.hostedTraitsForTesting?.description ?? "missing"
        // 单独控制未挂窗顺序；真实 provider 的 attached 时机由 UIKit 决定，不预设。
        let detachedSource = entry()
        let detachedPrepared = prepared(parent, source: detachedSource, collection: list)
        pool.store(detachedPrepared)
        let consumed = try XCTUnwrap(pool.take(token: detachedSource.warmHostToken, context: detachedPrepared.context))
        let detachedWarm = HostedConversationCell(frame: CGRect(x: 0, y: 140, width: 320, height: 60))
        let detachedCold = HostedConversationCell(frame: CGRect(x: 0, y: 210, width: 320, height: 60))
        detachedWarm.contentView.frame = detachedWarm.bounds; detachedCold.contentView.frame = detachedCold.bounds
        XCTAssertNil(detachedWarm.window)
        let installed = detachedWarm.installPreparedHost(consumed, entry: detachedSource, parent: parent, collection: list) { _, _ in }
        XCTAssertFalse(detachedWarm.lastWarmTargetWasAttached)
        if !installed { XCTAssertNotNil(detachedWarm.lastWarmTransferFailure) }
        detachedCold.apply(detachedSource, parent: parent) { _, _ in }
        list.addSubview(detachedWarm); list.addSubview(detachedCold)
        parent.children.forEach { $0.updateTraitsIfNeeded() }
        XCTAssertEqual(detachedWarm.hostedTraitsForTesting, detachedCold.hostedTraitsForTesting)
        XCTAssertEqual(parent.children.count, 4)
        providerDiagnostic["controlled_unattached_installed"] = installed
        providerDiagnostic["controlled_unattached_failure"] = detachedWarm.lastWarmTransferFailure?.rawValue ?? "none"
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: providerDiagnostic, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "actual-provider-render-owner-observation.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        withExtendedLifetime(dataSource) {}
    }
}
#endif

#if DEBUG
/// 旧版本始终装 renderer 的实际 Text 控制组；与候选使用相同内联渲染输入。
private struct InlineCodeRendererControl: View {
    let inlines: [MarkdownUI.InlineNode]
    let legacyRenderer: Bool
    @Environment(\.theme) private var theme
    @Environment(\.baseURL) private var baseURL
    @Environment(\.softBreakMode) private var softBreakMode
    var body: some View {
        if legacyRenderer {
            MarkdownUI.TextStyleAttributesReader { attributes in
                let text = inlines.renderText(baseURL: baseURL,
                    textStyles: .init(code: theme.code, emphasis: theme.emphasis,
                        strong: theme.strong, strikethrough: theme.strikethrough, link: theme.link),
                    images: [:], softBreakMode: softBreakMode, attributes: attributes)
                if #available(iOS 18.0, *) { text.textRenderer(MarkdownUI.MarkdownInlineCodeBackgroundRenderer()) }
                else { text }
            }
        } else {
            MarkdownUI.InlineText(inlines)
        }
    }
}

@MainActor
final class InlineCodeRendererFastPathTests: XCTestCase {
    private func compare(_ nodes: [MarkdownUI.InlineNode], width: CGFloat = 320,
                         fontSize: CGFloat = 17, direction: LayoutDirection = .leftToRight,
                         style: UIUserInterfaceStyle = .light,
                         snapshots: String? = nil) async throws -> (UIImage, UIImage) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let parent = UIViewController(), window = UIWindow(windowScene: scene)
        parent.overrideUserInterfaceStyle = style
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func host(_ legacy: Bool) -> UIHostingController<AnyView> {
            let content = InlineCodeRendererControl(inlines: nodes, legacyRenderer: legacy)
                .markdownTheme(.gitHub.text { FontSize(fontSize) })
                .environment(\.layoutDirection, direction)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
            let host = UIHostingController(rootView: AnyView(content))
            host.safeAreaRegions = []
            host.view.backgroundColor = .systemBackground
            parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
            return host
        }
        let old = host(true), new = host(false)
        let proposal = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let initialOld = old.sizeThatFits(in: proposal), initialNew = new.sizeThatFits(in: proposal)
        old.view.frame = CGRect(x: 0, y: 0, width: width, height: ceil(initialOld.height))
        new.view.frame = CGRect(x: 0, y: ceil(initialOld.height) + 12, width: width, height: ceil(initialNew.height))
        await Task.yield()
        parent.view.layoutIfNeeded()
        let oldSize = old.sizeThatFits(in: proposal), newSize = new.sizeThatFits(in: proposal)
        XCTAssertTrue(newSize.height.isFinite)
        XCTAssertGreaterThan(newSize.height, 0)
        XCTAssertEqual(newSize.width, oldSize.width, accuracy: 0.5)
        XCTAssertEqual(newSize.height, oldSize.height, accuracy: 0.5, "同宽/主题/字体/方向下测高应保持")
        XCTAssertEqual(old.traitCollection, new.traitCollection)
        func image(_ view: UIView) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true; format.preferredRange = .standard
            return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
                UIColor.white.setFill(); context.fill(view.bounds)
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
        }
        let oldImage = image(old.view), newImage = image(new.view)
        if let snapshots {
            for (name, image) in [("old", oldImage), ("new", newImage)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "inline-renderer-\(snapshots)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        return (oldImage, newImage)
    }
    private func nonWhitePixelCount(_ image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(source.bitsPerPixel, 32)
        XCTAssertEqual(source.bitsPerComponent, 8)
        let data = try XCTUnwrap(source.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        var count = 0
        for row in 0..<source.height {
            for column in 0..<source.width {
                let index = row * source.bytesPerRow + column * 4
                if bytes[index] < 245 || bytes[index + 1] < 245 || bytes[index + 2] < 245 { count += 1 }
            }
        }
        return count
    }
    private func grayBackgroundPixels(_ image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: pixels.count, by: 4).filter { index in
                let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
                return (205...240).contains(r) && abs(r - g) <= 3 && abs(g - b) <= 3
            }.count
        }
    }
    func testRecursiveCodeDetectionAndFencedCodeUseDistinctASTPaths() {
        let nested: [MarkdownUI.InlineNode] = [.strong(children: [.emphasis(children: [
            .link(destination: "https://example.com", children: [.code("nested")])
        ])])]
        XCTAssertTrue(MarkdownUI.InlineText(nested).hasInlineCode)
        XCTAssertFalse(MarkdownUI.InlineText([.text("中文 **not AST code** 😀"),
            .strikethrough(children: [.text("plain")])]).hasInlineCode)
        let document = MarkdownUI.MarkdownContent("```swift\nlet value = `literal`\n```")
        guard case .codeBlock? = document.blocks.first else { return XCTFail("fence必须仍走CodeBlockView块级路径") }
        XCTAssertEqual(document.renderPlainText(), "let value = `literal`")
    }
    func testNoCodeDefaultRendererPreservesHostedGeometryAndLinkPayloads() async throws {
        let fixtures: [([MarkdownUI.InlineNode], LayoutDirection)] = [
            ([.text("中文 English 👨‍👩‍👧‍👦 café e\u{301}，混合排版与换行。"), .softBreak, .text("第二行内容")], .leftToRight),
            ([.strong(children: [.text("强调 plain strong")]), .text(" 与 "), .strikethrough(children: [.text("删除线")]), .lineBreak, .text("后续行")], .leftToRight),
            ([.text("مرحبا بالعالم שלום "), .link(destination: "https://example.com/path", children: [.text("链接 link")])], .rightToLeft)
        ]
        for (index, fixture) in fixtures.enumerated() {
            for width: CGFloat in [230, 320] {
                for size: CGFloat in [17, 23.8] {
                    let images = try await compare(fixture.0, width: width, fontSize: size, direction: fixture.1,
                        snapshots: width == 320 && size == 17 ? "no-code-\(index)" : nil)
                    XCTAssertGreaterThan(try nonWhitePixelCount(images.0), 20, "控制组必须实际绘出文字")
                    XCTAssertGreaterThan(try nonWhitePixelCount(images.1), 20, "默认路径必须实际绘出文字，不能两个空截图假通过")
                }
            }
        }
        let theme = MarkdownUI.Theme.gitHub
        let styles = MarkdownUI.InlineTextStyles(code: theme.code, emphasis: theme.emphasis,
            strong: theme.strong, strikethrough: theme.strikethrough, link: theme.link)
        let linked = try XCTUnwrap(fixtures[2].0.last).renderAttributedString(baseURL: nil, textStyles: styles,
            softBreakMode: .space, attributes: .init())
        XCTAssertTrue(linked.runs.contains { $0.link?.absoluteString == "https://example.com/path" },
                      "默认绘制路径必须保留原链接目的地；实窗fixture两路均启用textSelection")
        _ = try await compare(fixtures[2].0, direction: .rightToLeft, style: .dark, snapshots: "no-code-dark")
    }
    func testInlineCodeKeepsRoundedBackgroundAndHostedGeometry() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("TextRenderer仅iOS18及以上") }
        let nodes: [MarkdownUI.InlineNode] = [.text("代码 "), .code("alpha_beta_gamma"), .text("，以及 "),
            .strong(children: [.emphasis(children: [.code("nested_code")])]), .text("。")]
        let images = try await compare(nodes, width: 320, snapshots: "code-background")
        let oldGray = try grayBackgroundPixels(images.0), newGray = try grayBackgroundPixels(images.1)
        XCTAssertGreaterThan(oldGray, 100, "控制组截图必须实际绘出浅灰代码背景")
        XCTAssertGreaterThan(newGray, 100, "含代码分支必须保留浅灰代码背景")
        XCTAssertGreaterThanOrEqual(Double(newGray), Double(oldGray) * 0.9)
        XCTAssertLessThanOrEqual(Double(newGray), Double(oldGray) * 1.1)
        _ = try await compare(nodes, width: 230, fontSize: 23.8, direction: .rightToLeft)
        _ = try await compare(nodes, style: .dark, snapshots: "code-background-dark")
    }
}
#endif

#if DEBUG
/// 受控 provider 故意不响应任务取消，用于证明迟到结果不会污染新输入。
private actor InlineImageTaskProviderProbe: MarkdownUI.InlineImageProvider {
    struct Request {
        let url: URL
        let label: String
    }
    private let entered: [String: XCTestExpectation]
    private var requests: [Request] = []
    private var pending: [String: CheckedContinuation<Image, Error>] = [:]
    private var closed = false
    init(entered: [String: XCTestExpectation] = [:]) { self.entered = entered }
    func image(with url: URL, label: String) async throws -> Image {
        guard !closed else { throw CancellationError() }
        requests.append(Request(url: url, label: label))
        return try await withCheckedThrowingContinuation { continuation in
            pending[label] = continuation
            entered[label]?.fulfill()
        }
    }
    func recorded() -> [Request] { requests }
    func complete(_ label: String, result: Result<Image, Error>) {
        pending.removeValue(forKey: label)?.resume(with: result)
    }
    func shutdown() {
        closed = true
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class InlineImageTaskModel: ObservableObject {
    @Published var inlines: [MarkdownUI.InlineNode]
    @Published var imageBaseURL = URL(string: "https://example.com/base/doc/")!
    @Published var provider: InlineImageTaskProviderProbe
    init(_ inlines: [MarkdownUI.InlineNode], provider: InlineImageTaskProviderProbe) {
        self.inlines = inlines; self.provider = provider
    }
}
/// 改前原 InlineText 的控制组：同一 task、loader 与 Text 构造，不修 linked-image 原有绘制能力。
private struct InlineImageOriginalControl: View {
  @Environment(\.inlineImageProvider) private var inlineImageProvider
  @Environment(\.baseURL) private var baseURL
  @Environment(\.imageBaseURL) private var imageBaseURL
  @Environment(\.softBreakMode) private var softBreakMode
  @Environment(\.theme) private var theme

  @State private var inlineImages: [String: Image] = [:]

  private let inlines: [InlineNode]
  private let hasInlineCode: Bool

  init(_ inlines: [InlineNode]) {
    self.inlines = inlines
    func containsCode(_ node: InlineNode) -> Bool {
      if case .code = node { return true }
      return node.children.contains(where: containsCode)
    }
    self.hasInlineCode = inlines.contains(where: containsCode)
  }

  var body: some View {
    TextStyleAttributesReader { attributes in
      let text = self.inlines.renderText(
        baseURL: self.baseURL,
        textStyles: .init(
          code: self.theme.code,
          emphasis: self.theme.emphasis,
          strong: self.theme.strong,
          strikethrough: self.theme.strikethrough,
          link: self.theme.link
        ),
        images: self.inlineImages,
        softBreakMode: self.softBreakMode,
        attributes: attributes
      )
      if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, *), self.hasInlineCode {
        text.textRenderer(MarkdownInlineCodeBackgroundRenderer())
      } else {
        text
      }
    }
    .task(id: self.inlines) {
      self.inlineImages = (try? await self.loadInlineImages()) ?? [:]
    }
  }

  private func loadInlineImages() async throws -> [String: Image] {
    let images = Set(self.inlines.compactMap(\.imageData))
    guard !images.isEmpty else { return [:] }

    return try await withThrowingTaskGroup(of: (String, Image).self) { taskGroup in
      for image in images {
        guard let url = URL(string: image.source, relativeTo: self.imageBaseURL) else {
          continue
        }

        taskGroup.addTask {
          (image.source, try await self.inlineImageProvider.image(with: url, label: image.alt))
        }
      }

      var inlineImages: [String: Image] = [:]

      for try await result in taskGroup {
        inlineImages[result.0] = result.1
      }

      return inlineImages
    }
  }
}

private struct InlineImageTaskContent: View {
    @ObservedObject var model: InlineImageTaskModel
    let original: Bool
    var body: some View {
        Group {
            if original { InlineImageOriginalControl(model.inlines) }
            else { MarkdownUI.InlineText(model.inlines) }
        }
            .markdownTheme(.gitHub.text { FontSize(17) })
            .markdownInlineImageProvider(model.provider)
            .environment(\.imageBaseURL, model.imageBaseURL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
    }
}
@MainActor
private final class InlineImageActualTick: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?
    func next() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick() {
        link?.invalidate(); link = nil
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
final class InlineImageTaskIsolationTests: XCTestCase {
    private struct Fixture {
        let model: InlineImageTaskModel
        let host: UIHostingController<InlineImageTaskContent>
        let window: UIWindow
        let previous: UIWindow?
        func close() {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        func height() -> CGFloat {
            host.view.layoutIfNeeded()
            return host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
        }
        func pixels(red: Bool) -> Int {
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true; format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { context in
                UIColor.white.setFill(); context.fill(host.view.bounds)
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            guard let source = image.cgImage else { return 0 }
            var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
            return bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: source.width, height: source.height,
                    bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
                context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
                let rgba = buffer.bindMemory(to: UInt8.self)
                return stride(from: 0, to: rgba.count, by: 4).filter { index in
                    if red { return rgba[index] > 180 && rgba[index + 1] < 80 && rgba[index + 2] < 80 }
                    return rgba[index + 1] > 180 && rgba[index] < 80 && rgba[index + 2] < 80
                }.count
            }
        }
    }
    private func fixture(_ nodes: [MarkdownUI.InlineNode], provider: InlineImageTaskProviderProbe,
                         original: Bool = false) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = InlineImageTaskModel(nodes, provider: provider)
        let host = UIHostingController(rootView: InlineImageTaskContent(model: model, original: original))
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = .light
        host.view.backgroundColor = .white
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        host.view.layoutIfNeeded()
        return Fixture(model: model, host: host, window: window, previous: previous)
    }
    private func image(_ color: UIColor) -> Image {
        let uiImage = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return Image(uiImage: uiImage).renderingMode(.original)
    }
    private func nodes(_ label: String, source: String = "image.png") -> [MarkdownUI.InlineNode] {
        [.text("内容 "), .image(source: source, children: [.text(label)])]
    }
    private func ticks(_ count: Int = 2) async {
        let tick = InlineImageActualTick()
        for _ in 0..<count { await tick.next() }
    }
    private func assertGreen(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = CACurrentMediaTime() + 3
        while fixture.pixels(red: false) < 50 && CACurrentMediaTime() < deadline { await ticks(1) }
        XCTAssertGreaterThan(fixture.pixels(red: false), 50, "当前输入的绿色图片必须实际显示", file: file, line: line)
        XCTAssertEqual(fixture.pixels(red: true), 0, "不能显示旧输入的红色图片", file: file, line: line)
    }
    func testPlainAndCodeLiteralHaveNoImageRequestsOrDelayedHeightChange() async throws {
        let probe = InlineImageTaskProviderProbe()
        let fixture = try fixture([.text("中文 English ![literal](ignored.png)"), .softBreak,
            .code("![code](ignored.png)")], provider: probe)
        defer { fixture.close(); Task { await probe.shutdown() } }
        let first = fixture.height()
        await Task.yield(); await Task.yield()
        let afterYields = fixture.height()
        await ticks()
        let afterTicks = fixture.height()
        let calls = await probe.recorded()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(first, afterYields, accuracy: 0.5)
        XCTAssertEqual(afterYields, afterTicks, accuracy: 0.5)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "first_height": first, "after_two_yields_height": afterYields,
            "after_two_actual_ticks_height": afterTicks, "provider_requests": calls.count
        ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-no-image-height-settling.json"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testRelativeURLAltAndSameInputKeepOriginalTaskIdentity() async throws {
        let entered = expectation(description: "root direct image entered")
        entered.assertForOverFulfill = true
        let probe = InlineImageTaskProviderProbe(entered: ["linked-alt": entered])
        let source: [MarkdownUI.InlineNode] = [.image(source: "../relative.png", children: [.text("linked-alt")])]
        let fixture = try fixture(source, provider: probe)
        let replacement = InlineImageTaskProviderProbe()
        defer { fixture.close(); Task { await probe.shutdown(); await replacement.shutdown() } }
        await fulfillment(of: [entered], timeout: 3)
        let calls = await probe.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url.absoluteString, "https://example.com/base/relative.png")
        XCTAssertEqual(calls.first?.label, "linked-alt")
        await probe.complete("linked-alt", result: .success(image(.green)))
        await assertGreen(fixture)
        fixture.model.inlines = source
        fixture.model.imageBaseURL = URL(string: "https://another.example/new/")!
        fixture.model.provider = replacement
        await ticks()
        let originalCalls = await probe.recorded(), replacementCalls = await replacement.recorded()
        XCTAssertEqual(originalCalls.count, 1)
        XCTAssertTrue(replacementCalls.isEmpty, "same inlines环境变化仍沿原task(id:)合同，不顺带重启")
        await assertGreen(fixture)
    }
    func testLinkedImageKeepsOriginalLoaderAndRendererCapability() async throws {
        let source: [MarkdownUI.InlineNode] = [.text("linked "),
            .link(destination: "https://example.com/tap", children: [
                .image(source: "../relative.png", children: [.text("linked-alt")])])]
        for original in [true, false] {
            let entered = expectation(description: original ? "original linked request" : "candidate linked request")
            let probe = InlineImageTaskProviderProbe(entered: ["linked-alt": entered])
            let fixture = try fixture(source, provider: probe, original: original)
            defer { fixture.close(); Task { await probe.shutdown() } }
            await fulfillment(of: [entered], timeout: 3)
            let calls = await probe.recorded()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.url.absoluteString, "https://example.com/base/relative.png")
            XCTAssertEqual(calls.first?.label, "linked-alt")
            await probe.complete("linked-alt", result: .success(image(.green)))
            await ticks(3)
            // 原 renderText 对 .link 使用 attributed-string 路径，不消费其 child image 的 images 字典。
            // loader 可请求 linked-image，不等于直接 InlineText 会绘制它；上层 ImageFlow 的行为不在此更改。
            XCTAssertEqual(fixture.pixels(red: false), 0, "保持旧能力；不为新fixture顺带修改linked-image渲染")
            XCTAssertEqual(fixture.pixels(red: true), 0)
        }
    }
    func testLateImageAAfterNoImageThenBDoesNotReviveA() async throws {
        let a = expectation(description: "A entered"), b = expectation(description: "B entered")
        let probe = InlineImageTaskProviderProbe(entered: ["A": a, "B": b])
        let fixture = try fixture(nodes("A"), provider: probe)
        defer { fixture.close(); Task { await probe.shutdown() } }
        await fulfillment(of: [a], timeout: 3)
        fixture.model.inlines = [.text("没有图片的中间状态")]
        await ticks()
        XCTAssertEqual(fixture.pixels(red: true), 0)
        XCTAssertEqual(fixture.pixels(red: false), 0)
        fixture.model.inlines = nodes("B", source: "b.png")
        await fulfillment(of: [b], timeout: 3)
        await probe.complete("B", result: .success(image(.green)))
        await assertGreen(fixture)
        await probe.complete("A", result: .success(image(.red)))
        await ticks()
        await assertGreen(fixture)
        let calls = await probe.recorded()
        XCTAssertEqual(calls.map(\.label), ["A", "B"])
    }
    func testDirectSameSourceDifferentAltRejectsLateAAfterB() async throws {
        let a = expectation(description: "same-source A"), b = expectation(description: "same-source B")
        let probe = InlineImageTaskProviderProbe(entered: ["A": a, "B": b])
        let fixture = try fixture(nodes("A"), provider: probe)
        defer { fixture.close(); Task { await probe.shutdown() } }
        await fulfillment(of: [a], timeout: 3)
        fixture.model.inlines = nodes("B")
        await fulfillment(of: [b], timeout: 3)
        await probe.complete("B", result: .success(image(.green)))
        await assertGreen(fixture)
        await probe.complete("A", result: .success(image(.red)))
        await ticks()
        await assertGreen(fixture)
        let calls = await probe.recorded()
        XCTAssertEqual(calls.map(\.label), ["A", "B"])
        XCTAssertEqual(calls.first?.url, calls.last?.url)
    }
    func testCancellationAndFailureFallBackThenNextInputCanLoad() async throws {
        let a = expectation(description: "cancel response"), b = expectation(description: "failure response")
        let c = expectation(description: "next success")
        let probe = InlineImageTaskProviderProbe(entered: ["A": a, "B": b, "C": c])
        let fixture = try fixture(nodes("A"), provider: probe)
        defer { fixture.close(); Task { await probe.shutdown() } }
        await fulfillment(of: [a], timeout: 3)
        await probe.complete("A", result: .failure(CancellationError()))
        await ticks()
        XCTAssertEqual(fixture.pixels(red: false), 0)
        fixture.model.inlines = nodes("B")
        await fulfillment(of: [b], timeout: 3)
        await probe.complete("B", result: .failure(NSError(domain: "InlineImageFixture", code: 1)))
        await ticks()
        XCTAssertEqual(fixture.pixels(red: false), 0)
        fixture.model.inlines = nodes("C")
        await fulfillment(of: [c], timeout: 3)
        await probe.complete("C", result: .success(image(.green)))
        await assertGreen(fixture)
    }
}
#endif

@MainActor
final class HistoryViewportPresentationScheduleTests: XCTestCase {
    typealias Row = HistoryViewportPresentationSchedule.Row
    private func row(_ id: String, revision: Int = 0, kind: Int = 0, supplemental: Bool = false) -> Row {
        Row(id: id, revision: revision, kind: kind, supplemental: supplemental)
    }
    func testContinuousIdleDeadlineRestartsOnlyForInteraction() {
        var schedule = HistoryViewportPresentationSchedule()
        XCTAssertTrue(schedule.permitsWork(at: 0))
        schedule.noteInteraction(at: 10)
        XCTAssertFalse(schedule.permitsWork(at: 10.119))
        XCTAssertTrue(schedule.permitsWork(at: 10.121))
        // 普通查询/批次规划不会将 deadline 往后移动。
        _ = HistoryViewportPresentationSchedule.plan(current: [row("old")], target: [row("new"), row("old")], maximumInsertedEntries: 2)
        XCTAssertTrue(schedule.permitsWork(at: 10.121))
        schedule.noteInteraction(at: 10.10)
        XCTAssertFalse(schedule.permitsWork(at: 10.219))
        XCTAssertTrue(schedule.permitsWork(at: 10.221))
    }
    func testNearestPrependBatchesPreserveOldRowsAndCountAtMostTwoInsertedEntries() {
        var current = [row("header", supplemental: true), row("old-a"), row("old-b")]
        let target = [row("header", revision: 1, supplemental: true)] + (0..<7).map { row("new-\($0)") } + [row("old-a"), row("old-b")]
        var insertedCounts: [Int] = []
        repeat {
            let plan = HistoryViewportPresentationSchedule.plan(current: current, target: target, maximumInsertedEntries: 2)
            XCTAssertEqual(plan.route, .prepend)
            let next = plan.indices.map { target[$0] }
            let old = Set(current.map(\.id))
            insertedCounts.append(next.filter { !old.contains($0.id) }.count)
            XCTAssertEqual(next.first?.id, "header")
            XCTAssertEqual(next.suffix(2).map(\.id), ["old-a", "old-b"])
            current = next
        } while current.map(\.id) != target.map(\.id)
        XCTAssertEqual(insertedCounts, [2, 2, 2, 1])
        XCTAssertEqual(current, target)
    }
    func testChromeAdditionDisappearanceAndChangedOldKindsStillUseBoundedPrepend() {
        let old = [row("older-button", supplemental: true), row("a"), row("b")]
        let target = [row("loading", supplemental: true), row("new-1"), row("new-2"),
                      row("a", revision: 2), row("b", kind: 1)]
        let plan = HistoryViewportPresentationSchedule.plan(current: old, target: target, maximumInsertedEntries: 2)
        XCTAssertEqual(plan.route, .prepend)
        XCTAssertEqual(plan.remaining, 1)
        XCTAssertEqual(plan.changedExisting, 2)
        XCTAssertEqual(plan.indices.map { target[$0].id }, ["loading", "new-2", "a", "b"])
        let withoutHeader = Array(target.dropFirst())
        let final = HistoryViewportPresentationSchedule.plan(current: plan.indices.map { target[$0] }, target: withoutHeader, maximumInsertedEntries: 2)
        XCTAssertEqual(final.route, .prepend)
        XCTAssertEqual(final.remaining, 0)
        XCTAssertEqual(final.indices.map { withoutHeader[$0].id }, withoutHeader.map(\.id))
    }
    func testDeletionReorderAndTailInsertionAreExplicitReplacement() {
        let old = [row("a"), row("b"), row("c")]
        for target in [[row("a"), row("c")], [row("b"), row("a"), row("c")], old + [row("tail")]] {
            let plan = HistoryViewportPresentationSchedule.plan(current: old, target: target, maximumInsertedEntries: 2)
            XCTAssertEqual(plan.route, .replacement)
            XCTAssertEqual(plan.indices, Array(target.indices))
            XCTAssertEqual(plan.remaining, 0)
        }
    }
}

#if DEBUG
@MainActor
final class HistoryViewportControlledPresentationTests: XCTestCase {
    private final class Counter { var builds = 0; var pinnedChanges: [Bool] = [] }
    private struct Fixture {
        let controller: ConversationViewportController
        let timeline: ConversationTimeline
        let list: UICollectionView
        let window: UIWindow
        let previous: UIWindow?
        let counter: Counter
        func close() {
            controller.onHistoryPresented = { _, _, _ in }
            controller.detachHistoryPresentationConsumer()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
    }
    private func items(_ range: Range<Int>, tail: String? = nil) -> [ConversationItem] {
        range.map { index in
            .init(id: "controlled-\(index)", kind: .assistant, title: "", text: index == range.upperBound - 1 ? tail ?? "row" : "row",
                  isError: false, date: Date(timeIntervalSince1970: Double(index)))
        }
    }
    private func entries(_ items: [ConversationItem]) -> [ConversationViewportEntry] {
        items.map { .init(id: $0.id, revision: $0.text.count, content: AnyView(Text($0.text).frame(height: 60))) }
    }
    private func list(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        return view.subviews.lazy.compactMap { self.list(in: $0) }.first
    }
    private func wait(_ condition: () -> Bool, timeout: Double = 5,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = CACurrentMediaTime() + timeout
        let tick = InlineImageActualTick()
        while !condition(), CACurrentMediaTime() < deadline { await tick.next() }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func fixture(admission: HistoryPresentationAdmission? = nil) async throws -> Fixture {
        let counter = Counter()
        let controller = ConversationViewportController(onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { counter.pinnedChanges.append($0) }, onBottomAlignmentCompleted: {}, onApproachingTop: {})
        if let admission {
            controller.onHistoryPresentationConsumerAttached = { admission.attach(sessionID: $0, consumer: $1) }
            controller.onHistoryPresentationConsumerDetached = { admission.detach(sessionID: $0, consumerID: $1) }
            controller.onHistoryPresented = { admission.acknowledge(sessionID: $0, consumerID: $1, stamp: $2, domainLoading: false) }
        }
        controller.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let timeline = ConversationTimeline()
        timeline.publish(items(40..<60))
        controller.configure(sessionID: "controlled", timeline: timeline, supplementalEntries: [], makeEntries: { items in
            counter.builds += 1
            return items.map { .init(id: $0.id, revision: $0.text.count, content: AnyView(Text($0.text).frame(height: 60))) }
        }, bottomInset: 0)
        let list = try XCTUnwrap(list(in: controller.view))
        await wait { list.numberOfSections > 0 && list.numberOfItems(inSection: 0) == 20
            && !controller.isHistorySnapshotCommitInFlightForTesting
            && !controller.isInitialContentRevealPendingForTesting }
        return Fixture(controller: controller, timeline: timeline, list: list, window: window, previous: previous, counter: counter)
    }
    func testInitialContentFadesOnlyAfterCommitAndPositionAreStable() async throws {
        let fixture = try await fixture()
        defer { fixture.controller.historyDiffableCompletionGateForTesting = nil; fixture.close() }
        fixture.controller.reduceContentMotionForTesting = false
        let entered = expectation(description: "new session snapshot committed but not finalized")
        var release: (() -> Void)?
        fixture.controller.historyDiffableCompletionGateForTesting = { completion in
            fixture.controller.historyDiffableCompletionGateForTesting = nil
            release = completion; entered.fulfill()
        }
        let timeline = ConversationTimeline(); timeline.publish(items(70..<90))
        fixture.controller.configure(sessionID: "reveal-session", timeline: timeline, supplementalEntries: [],
            makeEntries: { self.entries($0) }, bottomInset: 0)
        await fulfillment(of: [entered], timeout: 4)
        XCTAssertTrue(fixture.list.isHidden, "不能展示diffable提交中的临时布局")
        XCTAssertNil(fixture.list.layer.animation(forKey: "conversation-content-reveal"))
        var reported = false
        fixture.controller.onContentAvailabilityChanged = { _, content in
            if content {
                XCTAssertFalse(fixture.list.isHidden)
                XCTAssertGreaterThanOrEqual(fixture.list.contentOffset.y,
                    fixture.list.contentSize.height - fixture.list.bounds.height - 1)
                reported = true
            }
        }
        try XCTUnwrap(release)()
        XCTAssertEqual(fixture.list.layer.opacity, 0, "定位之后仍等待几何稳定")
        await wait { reported }
        let animation = try XCTUnwrap(fixture.list.layer.animation(forKey: "conversation-content-reveal") as? CABasicAnimation)
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration, 0.18, accuracy: 0.001)
        XCTAssertEqual(fixture.list.layer.opacity, 1)
        let offset = fixture.list.contentOffset
        await wait { fixture.list.layer.animation(forKey: "conversation-content-reveal") == nil }
        XCTAssertEqual(fixture.list.contentOffset.y, offset.y, accuracy: 1)
    }

    func testHistoryRevealsOnlyInsertedBodyAfterOperationAndStableLayout() async throws {
        let admission = HistoryPresentationAdmission()
        let fixture = try await fixture(admission: admission)
        defer { fixture.close() }
        fixture.controller.reduceContentMotionForTesting = false
        await wait { fixture.list.layer.animation(forKey: "conversation-content-reveal") == nil }
        fixture.timeline.publish(items(40..<42))
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting }
        let source = try XCTUnwrap(fixture.list.dataSource as? UICollectionViewDiffableDataSource<Int, String>)
        let oldPath = try XCTUnwrap(source.indexPath(for: "controlled-40"))
        let oldCell = try XCTUnwrap(fixture.list.cellForItem(at: oldPath))
        let operation = try XCTUnwrap(admission.begin(sessionID: "controlled",
            consumerID: fixture.controller.historyPresentationConsumerID, domainLoading: false, hasMore: true, producerBusy: false))
        admission.requireProjection(sessionID: "controlled", epoch: 1, historyEventSequence: 1)
        let stamp = try XCTUnwrap(admission.stamp(sessionID: "controlled", committedEpoch: 1))
        fixture.timeline.publish(items(39..<42), historyPresentationStamp: stamp)
        await wait { source.indexPath(for: "controlled-39") != nil && !fixture.controller.isHistorySnapshotCommitInFlightForTesting }
        let newCell = try XCTUnwrap(fixture.list.cellForItem(at: try XCTUnwrap(source.indexPath(for: "controlled-39"))))
        XCTAssertEqual(newCell.contentView.layer.opacity, 0)
        XCTAssertTrue(newCell.contentView.accessibilityElementsHidden)
        XCTAssertEqual(oldCell.contentView.layer.opacity, 1)
        XCTAssertNil(oldCell.contentView.layer.animation(forKey: "conversation-content-reveal"))
        XCTAssertFalse(fixture.list.isHidden)
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
        XCTAssertTrue(admission.isPending(sessionID: "controlled"), "透明行不能提前确认呈现并释放准入")
        fixture.controller.onHistoryPresented = { session, consumer, actual in
            XCTAssertEqual(newCell.contentView.layer.opacity, 1)
            XCTAssertTrue(fixture.controller.pendingHistoryRevealIDsForTesting.isEmpty)
            admission.acknowledge(sessionID: session, consumerID: consumer, stamp: actual, domainLoading: false)
        }
        admission.terminal(sessionID: "controlled", domainLoading: false, operationID: operation)
        await wait { fixture.controller.pendingHistoryRevealIDsForTesting.isEmpty && fixture.list.showsVerticalScrollIndicator }
        XCTAssertEqual(newCell.contentView.layer.opacity, 1)
        XCTAssertFalse(newCell.contentView.accessibilityElementsHidden)
        XCTAssertNotNil(newCell.contentView.layer.animation(forKey: "conversation-content-reveal"))
        XCTAssertNil(oldCell.contentView.layer.animation(forKey: "conversation-content-reveal"))
        XCTAssertNil(fixture.list.layer.animation(forKey: "conversation-content-reveal"))
        // 短内容允许整体底对齐，但渐显本身不能再次移动阅读位置。
        let finalOffset = fixture.list.contentOffset.y
        await wait { newCell.contentView.layer.animation(forKey: "conversation-content-reveal") == nil }
        XCTAssertEqual(fixture.list.contentOffset.y, finalOffset, accuracy: 1)
    }

    func testNewDragRevealsPendingRowsAndStopsFadeWithoutWaitingForNetwork() async throws {
        let admission = HistoryPresentationAdmission()
        let fixture = try await fixture(admission: admission)
        defer { fixture.close() }
        fixture.timeline.publish(items(40..<42))
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting }
        _ = try XCTUnwrap(admission.begin(sessionID: "controlled", consumerID: fixture.controller.historyPresentationConsumerID,
            domainLoading: false, hasMore: true, producerBusy: false))
        admission.requireProjection(sessionID: "controlled", epoch: 1, historyEventSequence: 1)
        fixture.timeline.publish(items(39..<42), historyPresentationStamp: try XCTUnwrap(admission.stamp(sessionID: "controlled", committedEpoch: 1)))
        await wait { !fixture.controller.pendingHistoryRevealIDsForTesting.isEmpty
            && !fixture.controller.isHistorySnapshotCommitInFlightForTesting }
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        XCTAssertTrue(fixture.controller.pendingHistoryRevealIDsForTesting.isEmpty)
        XCTAssertTrue(admission.isPending(sessionID: "controlled"))
        for cell in fixture.list.visibleCells {
            XCTAssertEqual(cell.contentView.layer.opacity, 1)
            XCTAssertFalse(cell.contentView.accessibilityElementsHidden)
            XCTAssertNil(cell.contentView.layer.animation(forKey: "conversation-content-reveal"))
        }
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
    }

    func testReduceMotionAndSessionSwitchCannotLeaveStaleOpacity() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.controller.reduceContentMotionForTesting = true
        for session in ["reveal-a", "reveal-b"] {
            let timeline = ConversationTimeline(); timeline.publish(items(40..<42))
            fixture.controller.configure(sessionID: session, timeline: timeline, supplementalEntries: [],
                makeEntries: { self.entries($0) }, bottomInset: 0)
            await wait { !fixture.controller.isInitialContentRevealPendingForTesting }
            XCTAssertFalse(fixture.list.isHidden)
            XCTAssertNil(fixture.list.layer.animation(forKey: "conversation-content-reveal"))
            for cell in fixture.list.visibleCells { XCTAssertEqual(cell.contentView.layer.opacity, 1) }
        }
        fixture.controller.reduceContentMotionForTesting = false
        let timeline = ConversationTimeline(); timeline.publish(items(40..<42))
        fixture.controller.configure(sessionID: "animated-session", timeline: timeline, supplementalEntries: [],
            makeEntries: { self.entries($0) }, bottomInset: 0)
        await wait { !fixture.controller.isInitialContentRevealPendingForTesting }
        XCTAssertNotNil(fixture.list.layer.animation(forKey: "conversation-content-reveal"))
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        XCTAssertNil(fixture.list.layer.animation(forKey: "conversation-content-reveal"))
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        fixture.controller.detachHistoryPresentationConsumer()
        XCTAssertTrue(fixture.controller.pendingHistoryRevealIDsForTesting.isEmpty)
        XCTAssertEqual(fixture.list.layer.opacity, 1)
    }

    func testEmptySessionWaitsForContentAndSwitchCancelsPreviousFade() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.controller.reduceContentMotionForTesting = false
        let empty = ConversationTimeline()
        fixture.controller.configure(sessionID: "initially-empty", timeline: empty, supplementalEntries: [],
            makeEntries: { self.entries($0) }, bottomInset: 0)
        await wait { !fixture.controller.isHistorySnapshotCommitInFlightForTesting
            && !fixture.controller.isHistoryPresentationScheduledForTesting }
        XCTAssertTrue(fixture.list.isHidden)
        XCTAssertTrue(fixture.controller.isInitialContentRevealPendingForTesting)
        empty.publish(items(40..<42))
        await wait { !fixture.controller.isInitialContentRevealPendingForTesting }
        XCTAssertNotNil(fixture.list.layer.animation(forKey: "conversation-content-reveal"))
        let next = ConversationTimeline()
        fixture.controller.configure(sessionID: "next-empty", timeline: next, supplementalEntries: [],
            makeEntries: { self.entries($0) }, bottomInset: 0)
        XCTAssertTrue(fixture.list.isHidden)
        XCTAssertNil(fixture.list.layer.animation(forKey: "conversation-content-reveal"))
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting
            && !fixture.controller.isHistorySnapshotCommitInFlightForTesting }
        next.publish(items(70..<73))
        await wait { !fixture.controller.isInitialContentRevealPendingForTesting }
        XCTAssertFalse(fixture.list.isHidden)
        XCTAssertEqual(fixture.list.layer.opacity, 1)
    }

    func testInitialStreamingUpdatesStayImmediateAndRevealWhileReplyContinues() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.controller.reduceContentMotionForTesting = false
        let timeline = ConversationTimeline()
        fixture.controller.configure(sessionID: "streaming-reveal", timeline: timeline, supplementalEntries: [],
            makeEntries: { items in items.map { .init(id: $0.id, revision: $0.text.count,
                streamingAssistant: .init(title: "", text: $0.text)) } }, bottomInset: 0)
        // 先完成会话切换的清空事务；以下断言专门检查纯token更新，不混入旧会话diffable提交。
        await wait { !fixture.controller.isHistorySnapshotCommitInFlightForTesting
            && !fixture.controller.isHistoryPresentationScheduledForTesting }
        var text = ""
        func publish() {
            timeline.publish([.init(id: "active-stream", kind: .assistant, title: "", text: text,
                isError: false, date: Date(timeIntervalSince1970: 1))])
        }
        text = "start "; publish()
        await wait { !fixture.controller.isHistorySnapshotCommitInFlightForTesting
            && fixture.list.cellForItem(at: IndexPath(item: 0, section: 0)) is StreamingAssistantCell }
        for _ in 0..<60 { text += "token "; publish() }
        let cell = try XCTUnwrap(fixture.list.cellForItem(at: IndexPath(item: 0, section: 0)) as? StreamingAssistantCell)
        XCTAssertEqual(cell.renderedCharacterCount, text.count, "视觉等待不能把正常token更新转入历史批次队列")
        for _ in 0..<5 {
            text += String(repeating: "new text ", count: 20); publish()
            await InlineImageActualTick().next()
        }
        await wait { !fixture.controller.isInitialContentRevealPendingForTesting }
        XCTAssertEqual(fixture.list.layer.opacity, 1)
        XCTAssertFalse(fixture.list.isHidden)
        text += "still generating"; publish()
        let latestCell = try XCTUnwrap(fixture.list.cellForItem(at: IndexPath(item: 0, section: 0)) as? StreamingAssistantCell)
        XCTAssertEqual(latestCell.renderedCharacterCount, text.count)
    }

    func testHistoryInsertionNeverExposesOldOffscreenScreenshotBeforeFinalization() async throws {
        final class ImageState { var loaded = true }
        let screenshot = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 24)).image { context in
            UIColor.magenta.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 24))
        }.pngData()!
        for scenario in ["replacement", "leading_group_header", "image_bytes", "offscreen_height"] {
            let fixture = try await fixture()
            defer { fixture.controller.historyDiffableCompletionGateForTesting = nil; fixture.close() }
            let image = ImageState(); image.loaded = scenario != "image_bytes"
            fixture.controller.configure(sessionID: "controlled", timeline: fixture.timeline, supplementalEntries: [], makeEntries: { items in
                items.map { item in
                    if item.id == "controlled-40" {
                        return .init(id: item.id, revision: image.loaded ? 101 : 100,
                            userMessage: .init(text: "", images: [.init(id: "old-screenshot", data: image.loaded ? screenshot : nil,
                                width: 120, height: 240, name: "synthetic.png")], showsCopyButton: false))
                    }
                    let height: CGFloat = item.id == "controlled-39" ? 1_100 : (item.text == "offscreen grows" ? 180 : 60)
                    return .init(id: item.id, revision: item.text.count, content: AnyView(Text(item.text).frame(height: height)))
                }
            }, bottomInset: 0)
            await wait { !fixture.controller.isHistoryPresentationScheduledForTesting
                && !fixture.controller.isHistorySnapshotCommitInFlightForTesting }
            fixture.controller.scrollViewWillBeginDragging(fixture.list)
            fixture.list.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
            fixture.controller.scrollViewDidScroll(fixture.list)
            fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
            await wait { !fixture.controller.isHistoryPresentationScheduledForTesting }
            let source = try XCTUnwrap(fixture.list.dataSource as? UICollectionViewDiffableDataSource<Int, String>)
            func visibleIDs() -> [String] {
                fixture.list.indexPathsForVisibleItems.sorted().compactMap { path in
                    guard let frame = fixture.list.layoutAttributesForItem(at: path)?.frame,
                          frame.intersects(fixture.list.bounds) else { return nil }
                    return source.itemIdentifier(for: path)
                }
            }
            let visible = visibleIDs()
            XCTAssertFalse(visible.contains("controlled-40"), "旧截图必须在原阅读窗口之外")
            let retainedVisible = scenario == "leading_group_header" ? Array(visible.dropFirst()) : visible
            let anchor = try XCTUnwrap(retainedVisible.first)
            let anchorPath = try XCTUnwrap(source.indexPath(for: anchor))
            let anchorOffset = try XCTUnwrap(fixture.list.layoutAttributesForItem(at: anchorPath)).frame.minY - fixture.list.contentOffset.y
            let entered = expectation(description: "\(scenario) UIKit commit reached before manual restoration")
            var release: (() -> Void)?
            fixture.controller.historyDiffableCompletionGateForTesting = { completion in
                fixture.controller.historyDiffableCompletionGateForTesting = nil
                release = completion; entered.fulfill()
            }
            var target = items(39..<60)
            if scenario == "replacement" { target.removeAll { $0.id == "controlled-41" } }
            if scenario == "leading_group_header" { target.removeAll { $0.id == visible.first } }
            if scenario == "image_bytes" { image.loaded = true }
            if scenario == "offscreen_height" {
                target = target.map { item in
                    item.id == "controlled-41" ? ConversationItem(id: item.id, kind: .assistant, title: "",
                        text: "offscreen grows", isError: false, date: item.date) : item
                }
            }
            var acknowledged = false
            fixture.controller.onHistoryPresented = { _, _, _ in acknowledged = true }
            fixture.timeline.publish(target, historyPresentationStamp: .init(operationID: UUID(), projectionEpoch: 1))
            await fulfillment(of: [entered], timeout: 6)
            XCTAssertTrue(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
            for _ in 0..<3 {
                if scenario == "leading_group_header" {
                    let retained = Set(retainedVisible)
                    XCTAssertEqual(visibleIDs().filter { retained.contains($0) }, retainedVisible,
                                   "分组头替换后仍保留原来实际阅读的正文窗口")
                } else {
                    XCTAssertEqual(visibleIDs(), visible, "\(scenario): 手动恢复前也不能闪现别的阅读窗口")
                }
                XCTAssertFalse(visibleIDs().contains("controlled-40"), "新插入内容没有图片，旧截图不可短暂出现")
                let path = try XCTUnwrap(source.indexPath(for: anchor))
                let frame = try XCTUnwrap(fixture.list.layoutAttributesForItem(at: path)).frame
                XCTAssertEqual(frame.minY - fixture.list.contentOffset.y, anchorOffset, accuracy: 1,
                               "\(scenario): 不能仅检查completion恢复后的锚点")
                await InlineImageActualTick().next()
            }
            try XCTUnwrap(release)()
            await wait { acknowledged && !fixture.controller.isHistoryPresentationScheduledForTesting }
            let path = try XCTUnwrap(source.indexPath(for: anchor))
            XCTAssertEqual(try XCTUnwrap(fixture.list.layoutAttributesForItem(at: path)).frame.minY - fixture.list.contentOffset.y,
                           anchorOffset, accuracy: 1)
        }
    }

    func testHistoryScrollIndicatorStaysHiddenUntilAllBatchesAndStableGeometry() async throws {
        let admission = HistoryPresentationAdmission()
        let fixture = try await fixture(admission: admission)
        defer { fixture.close() }
        XCTAssertTrue(fixture.list.showsVerticalScrollIndicator)
        let operation = try XCTUnwrap(admission.begin(sessionID: "controlled",
            consumerID: fixture.controller.historyPresentationConsumerID, domainLoading: false, hasMore: true, producerBusy: false))
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
        admission.requireProjection(sessionID: "controlled", epoch: 1, historyEventSequence: 1)
        let stamp = try XCTUnwrap(admission.stamp(sessionID: "controlled", committedEpoch: 1))
        fixture.controller.seedPresentationHeightForTesting(entries(items(36..<60)), height: 60)
        var acknowledged = false
        fixture.controller.onHistoryPresented = { session, consumer, actual in
            XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 24)
            XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
            admission.acknowledge(sessionID: session, consumerID: consumer, stamp: actual, domainLoading: false)
            XCTAssertFalse(fixture.list.showsVerticalScrollIndicator, "完成回调不能在布局收尾前直接显示滚动条")
            acknowledged = true
        }
        fixture.timeline.publish(items(36..<60), historyPresentationStamp: stamp)
        admission.terminal(sessionID: "controlled", domainLoading: false, operationID: operation)
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator, "网络结束不代表历史已经完整呈现")
        await wait { fixture.list.numberOfItems(inSection: 0) > 20 }
        XCTAssertLessThan(fixture.list.numberOfItems(inSection: 0), 24)
        XCTAssertTrue(admission.isPending(sessionID: "controlled"))
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        await InlineImageActualTick().next()
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { acknowledged && fixture.list.showsVerticalScrollIndicator
            && !fixture.controller.isHistoryPresentationScheduledForTesting }
        XCTAssertFalse(admission.isPending(sessionID: "controlled"))
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 24)
    }

    func testHistoryScrollIndicatorWaitsForDeferredFinalizationAfterAnotherDrag() async throws {
        let admission = HistoryPresentationAdmission()
        let fixture = try await fixture(admission: admission)
        defer { fixture.controller.historyDiffableCompletionGateForTesting = nil; fixture.close() }
        let operation = try XCTUnwrap(admission.begin(sessionID: "controlled",
            consumerID: fixture.controller.historyPresentationConsumerID, domainLoading: false, hasMore: true, producerBusy: false))
        admission.requireProjection(sessionID: "controlled", epoch: 1, historyEventSequence: 1)
        let stamp = try XCTUnwrap(admission.stamp(sessionID: "controlled", committedEpoch: 1))
        let entered = expectation(description: "UIKit completed before history finalization")
        var release: (() -> Void)?
        fixture.controller.historyDiffableCompletionGateForTesting = { completion in
            fixture.controller.historyDiffableCompletionGateForTesting = nil
            release = completion
            entered.fulfill()
        }
        fixture.controller.seedPresentationHeightForTesting(entries(items(39..<60)), height: 60)
        fixture.timeline.publish(items(39..<60), historyPresentationStamp: stamp)
        admission.terminal(sessionID: "controlled", domainLoading: false, operationID: operation)
        await fulfillment(of: [entered], timeout: 4)
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        try XCTUnwrap(release)()
        XCTAssertTrue(fixture.controller.isHistoryFinalizationPendingForTesting)
        XCTAssertTrue(admission.isPending(sessionID: "controlled"))
        await InlineImageActualTick().next()
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { !admission.isPending(sessionID: "controlled") && fixture.list.showsVerticalScrollIndicator }
        XCTAssertFalse(fixture.controller.isHistoryFinalizationPendingForTesting)
    }

    func testHistoryScrollIndicatorRecoversAfterFailureEmptyAndDetachWithoutStaleFinish() async throws {
        let admission = HistoryPresentationAdmission()
        let fixture = try await fixture(admission: admission)
        defer { fixture.close() }
        let first = try XCTUnwrap(admission.begin(sessionID: "controlled",
            consumerID: fixture.controller.historyPresentationConsumerID, domainLoading: false, hasMore: true, producerBusy: false))
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
        admission.cancel(sessionID: "controlled", outcome: .failed, operationID: first)
        await wait { fixture.list.showsVerticalScrollIndicator }
        let second = try XCTUnwrap(admission.begin(sessionID: "controlled",
            consumerID: fixture.controller.historyPresentationConsumerID, domainLoading: false, hasMore: true, producerBusy: false))
        fixture.controller.recordHistoryPresentationLifecycle(.finished(first, .failed))
        await InlineImageActualTick().next(); await InlineImageActualTick().next()
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator, "旧请求的完成不能恢复新请求的滚动条")
        admission.terminal(sessionID: "controlled", domainLoading: false, operationID: second)
        await wait { fixture.list.showsVerticalScrollIndicator }
        _ = try XCTUnwrap(admission.begin(sessionID: "controlled",
            consumerID: fixture.controller.historyPresentationConsumerID, domainLoading: false, hasMore: true, producerBusy: false))
        XCTAssertFalse(fixture.list.showsVerticalScrollIndicator)
        fixture.controller.detachHistoryPresentationConsumer()
        XCTAssertTrue(fixture.list.showsVerticalScrollIndicator)
        XCTAssertFalse(admission.isPending(sessionID: "controlled"))
    }

    func testCacheHitAndLayoutDrainCannotCommitOrBuildWhileDraggingThenOnlyLatestIsShown() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let target = items(0..<60)
        fixture.controller.seedPresentationHeightForTesting(entries(target), height: 60)
        let builds = fixture.counter.builds
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.timeline.publish(items(20..<60))
        fixture.timeline.publish(target)
        fixture.controller.view.layoutIfNeeded()
        await InlineImageActualTick().next(); await InlineImageActualTick().next()
        XCTAssertEqual(fixture.counter.builds, builds, "冻结必须发生在makeEntries之前")
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 20)
        XCTAssertFalse(fixture.controller.isHistoryPreparationPendingForTesting)
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 20, "cache-hit不能绕过120ms稳定入口")
        await wait { fixture.list.numberOfItems(inSection: 0) == 60 }
        XCTAssertEqual(fixture.counter.builds, builds + 1)
    }
    func testPartialHistoryStopsOnNewDragAndAcknowledgesOnlyCompleteLatestEpoch() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let operation = UUID(), first = HistoryPresentationStamp(operationID: operation, projectionEpoch: 1)
        fixture.controller.seedPresentationHeightForTesting(entries(items(0..<60)), height: 60)
        var acknowledged: [HistoryPresentationStamp] = []
        fixture.controller.onHistoryPresented = { _, _, stamp in
            acknowledged.append(stamp)
            XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 60)
        }
        fixture.timeline.publish(items(0..<60), historyPresentationStamp: first)
        await wait { fixture.list.numberOfItems(inSection: 0) > 20 }
        let partial = fixture.list.numberOfItems(inSection: 0)
        XCTAssertLessThan(partial, 60)
        XCTAssertTrue(acknowledged.isEmpty)
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        await InlineImageActualTick().next(); await InlineImageActualTick().next()
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), partial)
        let latest = HistoryPresentationStamp(operationID: operation, projectionEpoch: 2)
        fixture.timeline.publish(items(0..<60), historyPresentationStamp: latest)
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { !acknowledged.isEmpty }
        XCTAssertEqual(acknowledged, [latest])
    }
    func testSameHistoryEpochLiveUpdatesDoNotStarveFinalHistoryAcknowledgment() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let stamp = HistoryPresentationStamp(operationID: UUID(), projectionEpoch: 4)
        var acknowledgments = 0
        fixture.controller.onHistoryPresented = { _, _, actual in
            XCTAssertEqual(actual, stamp)
            XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 24)
            acknowledgments += 1
        }
        fixture.timeline.publish(items(36..<60), historyPresentationStamp: stamp)
        let deadline = CACurrentMediaTime() + 5
        var revision = 0
        while acknowledgments == 0, CACurrentMediaTime() < deadline {
            revision += 1
            fixture.timeline.publish(items(36..<60, tail: String(repeating: "x", count: revision)))
            await InlineImageActualTick().next()
        }
        XCTAssertEqual(acknowledgments, 1, "同history epoch的持续live不能使已完整呈现的历史永不确认")
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting }
    }
    func testInFlightCompletionDefersFinalizationAndKeepsNewReadingPositionAfterAnotherDrag() async throws {
        let fixture = try await fixture()
        defer { fixture.controller.historyDiffableCompletionGateForTesting = nil; fixture.close() }
        let target = items(39..<60)
        fixture.controller.seedPresentationHeightForTesting(entries(target), height: 60)
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.list.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting }
        let entered = expectation(description: "real diffable completion reached before finalization")
        var release: (() -> Void)?
        fixture.controller.historyDiffableCompletionGateForTesting = { completion in
            release = completion
            fixture.controller.historyDiffableCompletionGateForTesting = nil
            entered.fulfill()
        }
        var acknowledgments = 0
        fixture.controller.onHistoryPresented = { _, _, _ in acknowledgments += 1 }
        fixture.timeline.publish(target, historyPresentationStamp: .init(operationID: UUID(), projectionEpoch: 7))
        await fulfillment(of: [entered], timeout: 4)
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 21)
        XCTAssertEqual(acknowledgments, 0)
        XCTAssertTrue(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.list.setContentOffset(CGPoint(x: 0, y: 260), animated: false)
        let userOffset = fixture.list.contentOffset.y
        try XCTUnwrap(release)()
        XCTAssertTrue(fixture.controller.isHistoryFinalizationPendingForTesting)
        XCTAssertTrue(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
        await InlineImageActualTick().next(); await InlineImageActualTick().next()
        XCTAssertEqual(acknowledgments, 0)
        XCTAssertEqual(fixture.list.contentOffset.y, userOffset, accuracy: 0.5,
                       "movement期间completion不可恢复旧anchor或主动拉回")
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { acknowledgments == 1 && !fixture.controller.isHistoryFinalizationPendingForTesting }
        XCTAssertEqual(fixture.list.contentOffset.y, userOffset, accuracy: 1,
                       "idle finalization必须保用户新阅读位置，而非提交前旧anchor")
        await InlineImageActualTick().next()
        XCTAssertEqual(acknowledgments, 1)
        XCTAssertFalse(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
    }
    func testActualSnapshotsInsertAtMostOneEntryIncludingChromeCacheHitsAndHeavyMarkdown() async throws {
        let fixture = try await fixture()
        defer { fixture.controller.historyDiffableCompletionGateForTesting = nil; fixture.close() }
        let dataSource = try XCTUnwrap(fixture.list.dataSource as? UICollectionViewDiffableDataSource<Int, String>)
        var previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        var insertions: [Int] = []
        var observations: [[String: Any]] = []
        let anchorID = "controlled-43"
        func observe(_ stage: String) {
            let frame = dataSource.indexPath(for: anchorID).flatMap { fixture.list.layoutAttributesForItem(at: $0)?.frame }
            let firstPath = fixture.list.indexPathsForVisibleItems.sorted().first
            let firstID = firstPath.flatMap { dataSource.itemIdentifier(for: $0) }
            let firstFrame = firstPath.flatMap { fixture.list.layoutAttributesForItem(at: $0)?.frame }
            observations.append([
                "stage": stage, "batch": insertions.count, "anchor_id": anchorID,
                "anchor_min_y": frame.map { Double($0.minY) } ?? -1,
                "offset_y": Double(fixture.list.contentOffset.y),
                "anchor_offset": frame.map { Double($0.minY - fixture.list.contentOffset.y) } ?? -1,
                "first_visible_id": firstID ?? "none", "first_visible_min_y": firstFrame.map { Double($0.minY) } ?? -1,
                "content_height": Double(fixture.list.contentSize.height), "bounds_height": Double(fixture.list.bounds.height),
                "bottom_offset": Double(max(-fixture.list.adjustedContentInset.top,
                    fixture.list.contentSize.height - fixture.list.bounds.height + fixture.list.adjustedContentInset.bottom)),
                "pending_finalization": fixture.controller.isHistoryFinalizationPendingForTesting,
                "inflight": fixture.controller.isHistorySnapshotCommitInFlightForTesting,
                "scheduled": fixture.controller.isHistoryPresentationScheduledForTesting,
                "pinned_changes": fixture.counter.pinnedChanges,
                "native_offset_active": fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting
            ])
        }
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "synthetic-cap1-reading-anchor-observations.json"; attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        observe("initial_before_offset")
        // 建立真实阅读前置：用户手势取消初始confirmStableBottomAlignment链。
        // 只程序化改offset并不代表用户离开尾部，不能让fixture的旧尾链污染后续保锚断言。
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.list.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        observe("initial_after_offset")
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting
            && !fixture.controller.isHistorySnapshotCommitInFlightForTesting }
        observe("settled_user_reading_baseline")
        let anchorPath = try XCTUnwrap(dataSource.indexPath(for: anchorID))
        let initialAnchor = try XCTUnwrap(fixture.list.layoutAttributesForItem(at: anchorPath)).frame.minY - fixture.list.contentOffset.y
        let initialVisibleContent = Set(fixture.list.indexPathsForVisibleItems.compactMap { path -> String? in
            guard let frame = fixture.list.layoutAttributesForItem(at: path)?.frame,
                  frame.intersects(fixture.list.bounds) else { return nil }
            return dataSource.itemIdentifier(for: path)
        })
        var epochs: [Int] = []
        var expectsNativeOffset = true
        fixture.controller.onHistoryPresented = { _, _, stamp in epochs.append(stamp.projectionEpoch) }
        fixture.controller.historyDiffableCompletionGateForTesting = { completion in
            let current = Set(dataSource.snapshot().itemIdentifiers)
            let inserted = current.subtracting(previousIDs).count
            insertions.append(inserted)
            XCTAssertLessThanOrEqual(inserted, 1, "实际每个diffable snapshot新增展示行必须≤1，不能只测planner")
            previousIDs = current
            observe("diffable_completion_before_finalize")
            XCTAssertEqual(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting, expectsNativeOffset)
            if expectsNativeOffset {
                XCTAssertEqual(fixture.counter.pinnedChanges.last, false,
                               "原生补偿的中间contentSize不能把阅读意图改成跟尾")
                if let path = dataSource.indexPath(for: anchorID), let frame = fixture.list.layoutAttributesForItem(at: path)?.frame {
                    XCTAssertEqual(frame.minY - fixture.list.contentOffset.y, initialAnchor, accuracy: 1,
                                   "原生补偿须在手动restore前已保阅读窗口")
                } else { XCTFail("原生更新期间原阅读锚点必须存在") }
                let visible = Set(fixture.list.indexPathsForVisibleItems.compactMap { path -> String? in
                    guard let frame = fixture.list.layoutAttributesForItem(at: path)?.frame,
                          frame.intersects(fixture.list.bounds) else { return nil }
                    return dataSource.itemIdentifier(for: path)
                })
                XCTAssertEqual(visible, initialVisibleContent, "不可先为错误窗口建树再靠手动restore回原窗口")
            }
            completion()
            XCTAssertFalse(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
            observe("diffable_completion_after_finalize")
            if let path = dataSource.indexPath(for: anchorID), let frame = fixture.list.layoutAttributesForItem(at: path)?.frame {
                XCTAssertEqual(frame.minY - fixture.list.contentOffset.y, initialAnchor, accuracy: 1)
            } else { XCTFail("原阅读锚点必须保留") }
        }
        let header = ConversationViewportEntry(id: "history-loading", revision: 1,
            content: AnyView(Text("loading").frame(height: 20)), allowsScrollAnchoring: false)
        let cachedItems = items(38..<60)
        fixture.controller.seedPresentationHeightForTesting(entries(cachedItems), height: 60)
        fixture.controller.seedPresentationHeightForTesting([header], height: 20)
        fixture.controller.configure(sessionID: "controlled", timeline: fixture.timeline, supplementalEntries: [header], makeEntries: { items in
            items.map { .init(id: $0.id, revision: $0.text.count, content: AnyView(Text($0.text).frame(height: 60))) }
        }, bottomInset: 0)
        let operation = UUID()
        fixture.timeline.publish(cachedItems, historyPresentationStamp: .init(operationID: operation, projectionEpoch: 1))
        await wait { epochs == [1] }
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 23)
        XCTAssertEqual(insertions, [1, 1, 1], "chrome-only先呈现，随后两条缓存正文逐条呈现，不能提前ack")
        let paragraph = "### 表达式与说明\n\n中文与 English 的较长说明，包含 **强调**、`inline_code` 与可换行文本。\n\n"
        let heavy = String(repeating: paragraph, count: 12)
        let heavyItems = items(36..<60).map { item in
            guard item.id == "controlled-36" || item.id == "controlled-37" else { return item }
            return ConversationItem(id: item.id, kind: .assistant, title: "", text: heavy,
                                    isError: false, date: item.date)
        }
        fixture.controller.configure(sessionID: "controlled", timeline: fixture.timeline, supplementalEntries: [], makeEntries: { items in
            items.map { item in
                let content: AnyView = item.id == "controlled-36" || item.id == "controlled-37"
                    ? AnyView(Markdown(item.text).markdownTheme(.gitHub)) : AnyView(Text(item.text).frame(height: 60))
                return .init(id: item.id, revision: item.text.count, content: content)
            }
        }, bottomInset: 0)
        fixture.timeline.publish(heavyItems, historyPresentationStamp: .init(operationID: operation, projectionEpoch: 2))
        await wait({ epochs == [1, 2] }, timeout: 8)
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 24)
        XCTAssertEqual(insertions, [1, 1, 1, 1, 1])
        observe("phase2_ack_before_mixed_configure")
        // A retained visible row really grows. Its bottom-relative compensation
        // need not preserve our top reading anchor, so retain the manual policy.
        expectsNativeOffset = false
        let mixedItems = [items(35..<36)[0]] + heavyItems.map { item in
            guard item.id == "controlled-44" else { return item }
            return ConversationItem(id: item.id, kind: .assistant, title: "", text: "changed existing height",
                                    isError: false, date: item.date)
        }
        fixture.controller.configure(sessionID: "controlled", timeline: fixture.timeline, supplementalEntries: [], makeEntries: { items in
            items.map { item in
                let content: AnyView
                if item.id == "controlled-36" || item.id == "controlled-37" {
                    content = AnyView(Markdown(item.text).markdownTheme(.gitHub))
                } else {
                    content = AnyView(Text(item.text).frame(height: item.id == "controlled-44" && item.text == "changed existing height" ? 90 : 60))
                }
                return .init(id: item.id, revision: item.text.count, content: content)
            }
        }, bottomInset: 0)
        observe("mixed_after_configure_before_publish")
        fixture.timeline.publish(mixedItems, historyPresentationStamp: .init(operationID: operation, projectionEpoch: 3))
        observe("mixed_after_publish")
        await wait({ epochs == [1, 2, 3] }, timeout: 8)
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 25)
        XCTAssertEqual(insertions, [1, 1, 1, 1, 1, 1])
    }
    func testNativeOffsetLeaseSurvivesInFlightDetachButCannotLeakIntoReplacementSession() async throws {
        let fixture = try await fixture()
        defer { fixture.controller.historyDiffableCompletionGateForTesting = nil; fixture.close() }
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.list.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting }
        let entered = expectation(description: "old native offset transaction completed in UIKit")
        var release: (() -> Void)?
        fixture.controller.historyDiffableCompletionGateForTesting = { completion in
            release = completion
            fixture.controller.historyDiffableCompletionGateForTesting = nil
            entered.fulfill()
        }
        let target = items(39..<60)
        fixture.controller.seedPresentationHeightForTesting(entries(target), height: 60)
        fixture.timeline.publish(target, historyPresentationStamp: .init(operationID: UUID(), projectionEpoch: 1))
        await fulfillment(of: [entered], timeout: 4)
        XCTAssertTrue(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.list.setContentOffset(CGPoint(x: 0, y: fixture.list.contentSize.height - fixture.list.bounds.height), animated: false)
        fixture.controller.scrollViewDidScroll(fixture.list)
        await wait { fixture.counter.pinnedChanges.last == true }
        XCTAssertEqual(fixture.counter.pinnedChanges.last, true, "真实用户动作在native lease内仍能选择跟尾")
        fixture.list.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        fixture.controller.scrollViewDidScroll(fixture.list)
        await wait { fixture.counter.pinnedChanges.last == false }
        XCTAssertEqual(fixture.counter.pinnedChanges.last, false, "真实用户离尾仍须立即更新意图")
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        // The consumer can leave before our completion callback is admitted. Keep
        // the old layout's policy until that UUID exits; never turn it off mid-update.
        fixture.controller.detachHistoryPresentationConsumer()
        XCTAssertTrue(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
        try XCTUnwrap(release)()
        XCTAssertFalse(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
        XCTAssertFalse(fixture.controller.isHistorySnapshotCommitInFlightForTesting)
        let replacement = ConversationTimeline()
        replacement.publish(items(100..<103))
        fixture.controller.configure(sessionID: "new-offset-session", timeline: replacement, supplementalEntries: [],
            makeEntries: { self.entries($0) }, bottomInset: 0)
        await wait { fixture.list.numberOfItems(inSection: 0) == 3
            && !fixture.controller.isHistorySnapshotCommitInFlightForTesting }
        XCTAssertFalse(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
    }
    func testShortContentHistoryAndReplacementKeepOriginalOffsetPolicy() async throws {
        let fixture = try await fixture()
        defer { fixture.controller.historyDiffableCompletionGateForTesting = nil; fixture.close() }
        fixture.timeline.publish(items(40..<43))
        await wait { fixture.list.numberOfItems(inSection: 0) == 3
            && !fixture.controller.isHistorySnapshotCommitInFlightForTesting }
        XCTAssertLessThan(fixture.list.contentSize.height, fixture.list.bounds.height)
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.controller.scrollViewDidEndDragging(fixture.list, willDecelerate: false)
        await wait { !fixture.controller.isHistoryPresentationScheduledForTesting }
        var completions = 0
        fixture.controller.historyDiffableCompletionGateForTesting = { completion in
            completions += 1
            XCTAssertFalse(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting,
                           "旧内容未填满viewport不能启用库的短内容底部补偿")
            completion()
        }
        var acknowledged = 0
        fixture.controller.onHistoryPresented = { _, _, _ in acknowledged += 1 }
        fixture.timeline.publish(items(39..<43), historyPresentationStamp: .init(operationID: UUID(), projectionEpoch: 1))
        await wait { acknowledged == 1 }
        XCTAssertEqual(completions, 1)
        fixture.timeline.publish(items(100..<120), historyPresentationStamp: .init(operationID: UUID(), projectionEpoch: 2))
        await wait { acknowledged == 2 }
        XCTAssertEqual(completions, 2, "replacement保原route，不分批冒充prepend")
        XCTAssertFalse(fixture.controller.isNativeHistoryOffsetCompensationActiveForTesting)
    }
    func testWidthChangeAndNewEmptyEpochDiscardUnfinishedPreparedHistory() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let operation = UUID()
        var acknowledged: [Int] = []
        fixture.controller.onHistoryPresented = { _, _, stamp in acknowledged.append(stamp.projectionEpoch) }
        fixture.timeline.publish(items(0..<60), historyPresentationStamp: .init(operationID: operation, projectionEpoch: 1))
        await wait { fixture.controller.isHistoryPreparationPendingForTesting }
        fixture.controller.view.frame.size.width = 320
        fixture.controller.view.layoutIfNeeded()
        fixture.timeline.publish([], historyPresentationStamp: .init(operationID: operation, projectionEpoch: 2))
        await wait { fixture.list.numberOfItems(inSection: 0) == 0 && acknowledged == [2] }
        await InlineImageActualTick().next(); await InlineImageActualTick().next()
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 0)
        XCTAssertEqual(acknowledged, [2], "旧width/epoch准备不能复活历史或发送旧ack")
    }
    func testSessionSwitchDiscardsPausedTargetAndOldAcknowledgment() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        var oldAck = 0
        fixture.controller.onHistoryPresented = { _, _, _ in oldAck += 1 }
        fixture.controller.scrollViewWillBeginDragging(fixture.list)
        fixture.timeline.publish(items(0..<60), historyPresentationStamp: .init(operationID: UUID(), projectionEpoch: 9))
        let replacement = ConversationTimeline()
        replacement.publish(items(100..<103))
        fixture.controller.configure(sessionID: "replacement", timeline: replacement, supplementalEntries: [], makeEntries: { items in
            items.map { .init(id: $0.id, revision: 0, content: AnyView(Text($0.text).frame(height: 60))) }
        }, bottomInset: 0)
        await wait { fixture.list.numberOfItems(inSection: 0) == 3 }
        await InlineImageActualTick().next(); await InlineImageActualTick().next()
        XCTAssertEqual(oldAck, 0)
        XCTAssertEqual(fixture.list.numberOfItems(inSection: 0), 3)
    }
}
#endif


@MainActor
private final class HistoryReadingProbe {
    var began = 0
    var terminals = 0
    var outcomes: [HistoryPresentationOutcome] = []
    func receive(_ event: HistoryPresentationLifecycleEvent) {
        if case .began = event { began += 1 }
        if case .terminal = event { terminals += 1 }
        if case .finished(_, let outcome) = event { outcomes.append(outcome) }
    }
}

final class HistoryReadingBatchTests: XCTestCase {
    private func batch() -> HistoryReadingBatch {
        .init(operationID: UUID(), originalIDs: ["existing"], viewportHeight: 400, contentWidth: 320,
            fontScale: 1, startedAt: 0, beforeSequence: 100, rounds: 1)
    }
    private func item(_ id: String, kind: ConversationItem.Kind = .user, text: String = "短消息") -> ConversationItem {
        .init(id: id, kind: kind, title: "", text: text, isError: false, date: .distantPast)
    }
    func testToolsDoNotCountAsReadableBody() {
        let batch = batch()
        let window = batch.window(in: (1...200).map { item("tool-\($0)", kind: .tool) } + [item("existing")])
        XCTAssertEqual(window.messages, 0)
        XCTAssertEqual(window.height, 0)
        XCTAssertNil(batch.stopReason(window: window, earliestSequence: 50, hasMore: true, now: 0.1))
    }
    func testShortMessagesAccumulateToTwoScreens() {
        let batch = batch()
        XCTAssertNil(batch.stopReason(window: batch.window(in: [item("new")]), earliestSequence: 99, hasMore: true, now: 0.1))
        let enough = batch.window(in: (1...16).map { item("new-\($0)") })
        XCTAssertEqual(enough.messages, 16)
        XCTAssertEqual(batch.stopReason(window: enough, earliestSequence: 80, hasMore: true, now: 0.1), "window-filled")
    }
    func testOneLongReplyCanFillWindowWithoutCountingMarkdownBlocks() {
        let batch = batch(), text = String(repeating: "正文。\n\n", count: 200)
        let window = batch.window(in: [item("new", kind: .assistant, text: text)])
        XCTAssertEqual(window.messages, 1)
        XCTAssertEqual(batch.stopReason(window: window, earliestSequence: 99, hasMore: true, now: 0.1), "window-filled")
    }
    func testExistingMessagesAndLiveTailDoNotFillOlderWindow() {
        let batch = batch(), long = String(repeating: "x", count: 10000)
        let window = batch.window(in: [item("new"), item("existing", text: long), item("live", text: long)])
        XCTAssertEqual(window.messages, 1)
        XCTAssertNil(batch.stopReason(window: window, earliestSequence: 99, hasMore: true, now: 0.1))
    }
    func testEndErrorAndNoProgressStopSupplementing() {
        var batch = batch()
        let empty = HistoryReadingBatch.Window()
        XCTAssertEqual(batch.stopReason(window: empty, earliestSequence: 99, hasMore: false, now: 0.1), "end")
        XCTAssertEqual(batch.stopReason(window: empty, earliestSequence: 100, hasMore: true, now: 0.1), "no-progress")
        batch.failed = true
        XCTAssertEqual(batch.stopReason(window: empty, earliestSequence: 99, hasMore: true, now: 0.1), "error")
    }
    func testSparseHistoryHasCountTimeAndContentBudgets() {
        var batch = batch()
        XCTAssertEqual(batch.stopReason(window: .init(), earliestSequence: 99, hasMore: true, now: 2.5), "time-budget")
        batch.rounds = 8
        XCTAssertEqual(batch.stopReason(window: .init(), earliestSequence: 99, hasMore: true, now: 0.1), "round-budget")
        batch.rounds = 1
        XCTAssertEqual(batch.stopReason(window: .init(characters: 1048576), earliestSequence: 99, hasMore: true, now: 0.1), "content-budget")
    }
}
