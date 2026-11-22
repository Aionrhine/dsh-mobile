import SwiftUI
import DeepSeekHarnessShared

private let changesGreen = Color(red: 0.16, green: 0.52, blue: 0.23)
private let changesRed = Color(red: 0.77, green: 0.29, blue: 0.32)


private struct WorkspaceDiffLineViewport: View {
    let row: WorkspaceDiffRow
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 23
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                WorkspaceDiffLine(row: row).frame(minWidth: geometry.size.width, alignment: .leading)
            }.textSelection(.enabled)
        }.frame(height: lineHeight)
            .background(row.kind == "added" ? changesGreen.opacity(0.14) : row.kind == "deleted" ? changesRed.opacity(0.14) : Color.secondary.opacity(0.025))
    }
}

private struct WorkspaceDiffLine: View {
    let row: WorkspaceDiffRow
    private var tint: Color {
        switch row.kind {
        case "added": return changesGreen
        case "deleted": return changesRed
        case "context": return .primary
        default: return .secondary
        }
    }

    private func height(_ row: WorkspaceReviewRow) -> CGFloat { row.kind == "hunk" || row.kind == "omitted" ? 32 : lineHeight + 6 }
    private func background(_ row: WorkspaceReviewRow) -> Color {
        switch row.kind { case "added": return ReviewTheme.addedBG; case "deleted": return ReviewTheme.deletedBG; case "hunk": return ReviewTheme.hunkBG; default: return ReviewTheme.surface }
    }
    private func number(_ row: WorkspaceReviewRow) -> some View {
        Text(row.lineNumber.map { "\($0.intValue)" } ?? "")
            .font(.custom("JetBrainsMono-Regular", size: 12 * AppFontScale.current, relativeTo: .caption))
            .foregroundStyle(ReviewTheme.muted).frame(width: gutter, height: lineHeight, alignment: .topTrailing)
    }
    private func section(_ row: WorkspaceReviewRow) -> some View {
        Text(row.uiMessage?.localized ?? row.text).font(ReviewTheme.font(12)).foregroundStyle(row.kind == "omitted" ? ReviewTheme.muted : ReviewTheme.secondary)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 32, alignment: row.kind == "omitted" ? .center : .leading)
            .background(background(row))
    }
    private func code(_ row: WorkspaceReviewRow, wraps: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(row.oldLine.map { "\($0.intValue)" } ?? "").frame(width: 46, alignment: .trailing).padding(.trailing, 8)
            Text(row.newLine.map { "\($0.intValue)" } ?? "").frame(width: 46, alignment: .trailing).padding(.trailing, 12)
            Text(verbatim: row.text).foregroundStyle(tint).fixedSize(horizontal: true, vertical: true).padding(.trailing, 20)
            Spacer(minLength: 0)
        }
        return value
    }
}

/// TextKit 按可用宽度返回真实段落高度；没有行级横向或纵向滚动。
private struct ReviewCodeLabel: UIViewRepresentable {
    let text: String
    let size: CGFloat
    let lineHeight: CGFloat
    let wraps: Bool
    let color: UIColor
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.showsHorizontalScrollIndicator = false; view.showsVerticalScrollIndicator = false
        view.bounces = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.layoutManager.usesFontLeading = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        view.attributedText = ReviewCodeText.attributed(text, size: size, lineHeight: lineHeight, color: color)
        view.textContainer.maximumNumberOfLines = wraps ? 0 : 1
        view.accessibilityLabel = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if wraps {
            let width = max(1, proposal.width ?? 300)
            let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            return CGSize(width: width, height: max(lineHeight, ceil(height)))
        }
        let width = uiView.attributedText.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: lineHeight),
            options: [.usesLineFragmentOrigin], context: nil).width
        return CGSize(width: ceil(width) + 1, height: lineHeight)
    }
}

#if DEBUG
/// 通过正式状态机提供可重复的 UI 回归数据，不修改网关、连接配置或设备身份。
@MainActor private final class ReviewUITestModel: ObservableObject {
    private let shared = SharedWorkspaceChangesStore()
    @Published var snapshot = SharedWorkspaceChangesStore().snapshot()
    init() {
        _ = shared.open(sessionId: "review-ui-test", supported: true, connected: true)
        let announcement = shared.acceptJson(json: """
        {"kind":"event","sessionId":"review-ui-test","seq":1,"event":{"type":"workspace/changes","turn":1}}
        """)
        let id = announcement.requests.first?.correlationId ?? ""
        _ = shared.acceptJson(json: """
        {"kind":"workspace-changes-summary","sessionId":"review-ui-test","seq":1,"requestId":"\(id)","summary":{"turn":1,"total":4,"added":15,"deleted":2,"files":[
        {"path":"README.md","display":"README.md","added":3,"deleted":1},
        {"path":"app.js","display":"app.js","added":4,"deleted":0},
        {"path":"index.html","display":"index.html","added":2,"deleted":1},
        {"path":"style.css","display":"style.css","added":6,"deleted":0}]}}
        """)
        select(0)
    }
    func select(_ index: Int) {
        let transition = shared.selectFile(index: Int32(index))
        if let request = transition.requests.first {
            let names = ["README.md", "app.js", "index.html", "style.css"]
            let lines = index == 0 ? ["-# 小待办", "+# 今日", " ", " 一个极简的中文待办清单，纯 HTML / CSS / JavaScript，无依赖。", " "] : // i18n-ignore: 调试差异正文样例，验证中文排版，不是产品界面文案。
                (1...160).map { $0 == 1 ? "+  const remaining = todos.filter(todo => !todo.done).length;" : "+  const line\($0) = '保留中文与缩进，并验证较长代码不会遮挡相邻行';" } // i18n-ignore: 调试差异正文样例，验证中文排版，不是产品界面文案。
            let hunks: [[String: Any]] = index == 0 ? [
                ["oldStart": 1, "oldLines": 4, "newStart": 1, "newLines": 4, "lines": lines],
                ["oldStart": 7, "oldLines": 6, "newStart": 7, "newLines": 8, "lines": [" - 添加待办", " - 点击文字标记完成 / 取消完成", " - 点击「删除」移除待办", "+- 顶部显示剩余未完成数量", "+- 蓝色主题", " - 数据保存在浏览器 localStorage，刷新不会丢失。", " ", " ## 使用"]] // i18n-ignore: 调试差异正文样例，验证中文排版，不是产品界面文案。
            ] : [["oldStart": 1, "oldLines": 0, "newStart": 1, "newLines": 160, "lines": lines]]
            let payload: [String: Any] = ["kind": "workspace-changes-diff", "requestId": request.correlationId ?? "", "sessionId": "review-ui-test", "seq": 1, "index": index,
                "diff": ["kind": "text", "path": names[index], "display": names[index], "before": true, "after": true, "hunks": hunks]]
            if let data = try? JSONSerialization.data(withJSONObject: payload) { _ = shared.acceptJson(json: String(decoding: data, as: UTF8.self)) }
        }
        snapshot = shared.snapshot()
    }
}

struct WorkspaceReviewUITestHarness: View {
    @StateObject private var model = ReviewUITestModel()
    @State private var presented = true
    var body: some View {
        Color(.systemGroupedBackground).sheet(isPresented: $presented) {
            WorkspaceChangesSheet(state: model.snapshot, selectFile: model.select, retrySummary: {}, workspaceName: "file-changes-demo",
                                  workspaceRoot: "/Users/demo/file-changes-demo")
                .presentationDetents([.large]).presentationDragIndicator(.hidden).modifier(ReviewPageSizing())
        }
    }
}
#endif

private let changesLabel = changesColor(WorkspaceChangesStyle.shared.LABEL_COLOR_ARGB)
private let changesGreen = changesColor(WorkspaceChangesStyle.shared.ADDED_COLOR_ARGB)
private let changesRed = changesColor(WorkspaceChangesStyle.shared.DELETED_COLOR_ARGB)

struct WorkspaceChangesDock: View {
    @ObservedObject var store: AppStore
    @State private var expanded = false
    @State private var filePreviewID: UUID?
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight = WorkspaceChangesStyle.shared.LINE_HEIGHT
    private let style = WorkspaceChangesStyle.shared

    var body: some View {
        Group {
            if store.workspaceChanges.sessionId == store.selectedSessionId && store.workspaceChanges.visible {
                Button { expanded = true } label: {
                    HStack(spacing: style.ITEM_SPACING) {
                        if let summary = store.workspaceChanges.summary {
                            Text(String(localized: "\(summary.total) 个文件")).foregroundStyle(changesLabel)
                            Text("+\(summary.added)").foregroundStyle(changesGreen)
                            Text("−\(summary.deleted)").foregroundStyle(changesRed)
                        } else {
                            Text(String(localized: "文件改动")).foregroundStyle(changesLabel)
                            if store.workspaceChanges.loading {
                                ProgressView().controlSize(.mini)
                                    .frame(width: style.PROGRESS_SIZE, height: style.PROGRESS_SIZE)
                            }
                        }
                    }
                    .appFont(.system(size: style.FONT_SIZE))
                    .monospacedDigit()
                    .frame(minHeight: lineHeight)
                    .padding(.horizontal, style.HORIZONTAL_PADDING)
                    .padding(.vertical, style.VERTICAL_PADDING)
                    .composerGlassSurface(radius: 1000)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "查看本轮文件改动"))
                .padding(.bottom, style.COMPOSER_SPACING)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, style.HORIZONTAL_PADDING)
        .task(id: store.selectedSessionId) { store.refreshWorkspaceChanges() }
        .onChangeCompat(of: store.selectedSessionId) { _, _ in expanded = false; store.closeChangesDiff() }
        .sheet(isPresented: $expanded, onDismiss: { closeFilePreview(); store.closeChangesDiff() }) {
            WorkspaceChangesSheet(state: store.workspaceChanges, selectFile: store.selectChangedFile, retrySummary: store.retryWorkspaceChanges,
                                  workspaceName: store.activeWorkspace?.title ?? String(localized: "工作区"),
                                  workspaceRoot: store.workspaces.first { $0.sessionIds.contains(store.workspaceChanges.sessionId ?? "") }?.path,
                                  openFile: openFile)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .modifier(ReviewPageSizing())
                .sheet(item: filePreviewBinding) { request in
                    WorkspaceFilePreviewLoadingSheet(store: store, request: request)
                }
        }
    }

    private var filePreviewBinding: Binding<WorkspaceFilePreviewRequest?> {
        Binding(get: {
            guard store.workspaceFilePreviewRequest?.id == filePreviewID else { return nil }
            return store.workspaceFilePreviewRequest
        }, set: { if $0 == nil { closeFilePreview() } })
    }

    private func openFile(_ path: String) {
        guard store.selectedSessionId == store.workspaceChanges.sessionId,
              store.workspaceFilePreviewRequest == nil, !store.conversationFileIsOpening else { return }
        // 文件列表入口不会触发聊天底层的 Sheet；完整预览由当前审阅面板原生呈现。
        store.openWorkspaceFile(GatewayDirectoryItem(name: (path as NSString).lastPathComponent, path: path, kind: "file"), purpose: "preview")
        filePreviewID = store.workspaceFilePreviewRequest?.id
    }

    private func closeFilePreview() {
        if let filePreviewID, store.workspaceFilePreviewRequest?.id == filePreviewID { store.cancelWorkspaceFileDownload() }
        filePreviewID = nil
    }
}

private struct ReviewPageSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.presentationSizing(.page).presentationCornerRadius(28) }
        else if #available(iOS 16.4, *) { content.presentationCornerRadius(28) }
        else { content }
    }
}
