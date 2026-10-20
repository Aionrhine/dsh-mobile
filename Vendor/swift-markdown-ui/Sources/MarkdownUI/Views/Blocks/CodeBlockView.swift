import SwiftUI

struct CodeBlockView: View {
  @Environment(\.theme.codeBlock) private var codeBlock
  @Environment(\.codeSyntaxHighlighter) private var codeSyntaxHighlighter
  @Environment(\.markdownCodeBlockOverride) private var codeBlockOverride

  private let fenceInfo: String?
  private let content: String

  init(fenceInfo: String?, content: String) {
    self.fenceInfo = fenceInfo
    self.content = content.hasSuffix("\n") ? String(content.dropLast()) : content
  }

  var body: some View {
    if let custom = self.customBody {
      custom
    } else {
      self.codeBlock.makeBody(
        configuration: .init(
          language: self.fenceInfo,
          content: self.content,
          label: .init(self.label)
        )
      )
    }
  }

  /// Host-rendered content for fences it claims; `nil` keeps the code block.
  private var customBody: AnyView? {
    guard let codeBlockOverride else { return nil }
    return codeBlockOverride.render(self.fenceInfo, self.content)
  }

  private var label: some View {
    self.codeSyntaxHighlighter.highlightCode(self.content, language: self.fenceInfo)
      .textStyleFont()
      .textStyleForegroundColor()
  }
}
