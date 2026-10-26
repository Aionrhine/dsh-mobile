import SwiftUI
import MarkdownUI
import DeepSeekHarnessShared
import UniformTypeIdentifiers

struct MarkdownTableModel {
    let cells: [[MarkdownUI.MarkdownContent]]
    let plainRows: [[String]]
    let alignments: [TextTableColumnAlignment]

    init(content: MarkdownUI.MarkdownContent) {
        cells = content.tableCells ?? []
        plainRows = content.tablePlainTextRows
        alignments = content.tableColumnAlignments
    }

    func widths(fontSize: CGFloat) -> [CGFloat] {
        let font = UIFont.systemFont(ofSize: fontSize)
        return alignments.indices.map { column in
            let natural = plainRows.flatMap { row in
                (row.indices.contains(column) ? row[column] : "").components(separatedBy: .newlines)
            }.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            return min(260, max(96, ceil(natural) + 24))
        }
    }
}

/// 表格宽度由列内容决定，聊天视口只负责横向滚动；全屏使用同一份单元格快照。
struct MarkdownTableCard: View {
    let model: MarkdownTableModel
    let fontSize: CGFloat
    @State private var fullscreen = false
    @State private var fullscreenModel: MarkdownTableModel?

    init(content: MarkdownUI.MarkdownContent, fontSize: CGFloat) {
        model = MarkdownTableModel(content: content)
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTableActions(model: model, onExpand: { fullscreenModel = model; fullscreen = true })
            ScrollView(.horizontal, showsIndicators: true) {
                MarkdownTableGrid(model: model, fontSize: fontSize)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background { Rectangle().fill(DocumentPageAppearance.toolbar) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("markdown-table-card")
        .fullScreenCover(isPresented: $fullscreen) {
            MarkdownTablePage(model: fullscreenModel ?? model, fontSize: fontSize)
        }
    }
}

struct MarkdownTablePage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rotationRequest = 0
    let model: MarkdownTableModel
    let fontSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTableActions(model: model, onClose: { dismiss() }, onRotate: { rotationRequest += 1 })
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    MarkdownTableGrid(model: model, fontSize: fontSize)
                }
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background { Rectangle().fill(DocumentPageAppearance.background).ignoresSafeArea() }
        .background(DocumentRotationSupport(rotationRequest: rotationRequest))
        .accessibilityIdentifier("markdown-table-fullscreen")
    }
}

private struct MarkdownTableGrid: View {
    let model: MarkdownTableModel
    let fontSize: CGFloat

    var body: some View {
        let widths = model.widths(fontSize: fontSize)
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(model.cells.indices, id: \.self) { row in
                GridRow(alignment: .top) {
                    ForEach(widths.indices, id: \.self) { column in
                        let alignment = alignment(column)
                        Group {
                            if model.cells[row].indices.contains(column) {
                                Markdown(model.cells[row][column])
                                    .markdownTheme(.basic.text {
                                        FontSize(fontSize)
                                        ForegroundColor(DocumentPageAppearance.foreground)
                                        BackgroundColor(nil)
                                        FontWeight(row == 0 ? .semibold : .regular)
                                    }.paragraph { configuration in
                                        configuration.label
                                            .fixedSize(horizontal: false, vertical: true)
                                            .relativeLineSpacing(.em(0.18))
                                    })
                                    .dynamicTypeSize(.large)
                                    .multilineTextAlignment(textAlignment(column))
                            } else { Text(" ") }
                        }
                        .padding(12)
                        .frame(width: widths[column], alignment: alignment)
                        .frame(maxHeight: .infinity, alignment: alignment)
                        .background {
                            Rectangle().fill(row == 0 ? DocumentPageAppearance.headerFill
                                : row.isMultiple(of: 2) ? DocumentPageAppearance.alternateFill : DocumentPageAppearance.background)
                        }
                        .overlay(Rectangle().strokeBorder(DocumentPageAppearance.border, lineWidth: 0.5))
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityIdentifier("markdown-table-grid")
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch model.alignments[column] {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func alignment(_ column: Int) -> Alignment {
        switch model.alignments[column] {
        case .center: return .top
        case .trailing: return .topTrailing
        default: return .topLeading
        }
    }
}

private struct MarkdownTableActions: View {
    let model: MarkdownTableModel
    var onExpand: (() -> Void)?
    var onClose: (() -> Void)?
    var onRotate: (() -> Void)?
    @State private var copied = false
    @State private var exporting = false
    @State private var exportDocument: MarkdownTableCSVDocument?
    @State private var exportError: String?

    var body: some View {
        Group {
            if let onClose {
                DocumentPageHeader(title: "表格", closeIdentifier: "markdown-table-close", onClose: onClose) {
                    buttons
                }
            } else {
                HStack(spacing: 0) {
                    Text("表格").appFont(.system(size: 12)).foregroundStyle(DocumentPageAppearance.icon).padding(.leading, 12)
                    Spacer(minLength: 0)
                    buttons
                }
                .frame(minHeight: 44)
            }
        }
        .task(id: copied) {
            if copied {
                try? await Task.sleep(for: .milliseconds(1800))
                if !Task.isCancelled { copied = false }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "table.csv") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
            exportDocument = nil
        }
        .alert("保存失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("关闭", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            if copied && onClose == nil { Text("已复制").appFont(.system(size: 12)).foregroundStyle(DocumentPageAppearance.icon) }
            if let onRotate { action("TableRotate", label: "旋转屏幕", onRotate) }
            action("TableCopy", label: "复制表格") {
                UIPasteboard.general.string = MarkdownTableExport.shared.plainText(rows: model.plainRows)
                copied = true
            }
            action("TableDownload", label: "下载 CSV") {
                exportDocument = MarkdownTableCSVDocument(data: Data(MarkdownTableExport.shared.csv(rows: model.plainRows).utf8))
                exporting = true
            }
            if let onExpand { action("TableExpand", label: "全屏浏览表格", onExpand) }
        }
    }

    private func action(_ symbol: String, label: LocalizedStringKey, _ callback: @escaping () -> Void) -> some View {
        Button(action: callback) {
            Image(symbol).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 20, height: 20).foregroundStyle(DocumentPageAppearance.icon)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

struct MarkdownTableCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
