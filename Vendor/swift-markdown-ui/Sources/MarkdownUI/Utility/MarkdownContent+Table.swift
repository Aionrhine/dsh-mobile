import Foundation

extension MarkdownContent {
  /// 已解析的单元格内容，供应用渲染独立表格；代码块内的竖线不会被识别为表格。
  public var tableCells: [[MarkdownContent]]? {
    guard blocks.count == 1, case .table(_, let rows) = blocks[0] else { return nil }
    return rows.map { row in row.cells.map { .init(block: .paragraph(content: $0.content)) } }
  }

  public var tableColumnAlignments: [TextTableColumnAlignment] {
    guard blocks.count == 1, case .table(let alignments, _) = blocks[0] else { return [] }
    return alignments.map {
      switch $0 {
      case .center: return .center
      case .right: return .trailing
      default: return .leading
      }
    }
  }

  public var tablePlainTextRows: [[String]] {
    guard blocks.count == 1, case .table(_, let rows) = blocks[0] else { return [] }
    func plain(_ nodes: [InlineNode]) -> String {
      nodes.map { node in
        switch node {
        case .text(let text): return text
        case .code(let text):
          // PreparedMarkdownCache 为行内代码添加的排版间距不进入剪贴板或 CSV。
          if text.hasPrefix("\u{2009}"), text.hasSuffix("\u{2009}") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\u{200B}", with: "")
          }
          return text
        case .softBreak: return " "
        case .lineBreak: return "\n"
        case .html(let html):
          return html.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil ? "\n" : ""
        default: return plain(node.children)
        }
      }.joined()
    }
    return rows.map { $0.cells.map { plain($0.content) } }
  }
}
