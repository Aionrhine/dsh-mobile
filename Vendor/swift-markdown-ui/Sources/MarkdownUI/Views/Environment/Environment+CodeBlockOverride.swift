import SwiftUI

/// Lets a host replace a fenced code block with its own renderer.
///
/// The host decides which languages it claims; returning `nil` keeps the stock
/// code block, so unsupported or malformed fences stay readable instead of
/// turning into an empty box.
public struct MarkdownCodeBlockOverride: @unchecked Sendable {
  public typealias Render = (_ language: String?, _ content: String) -> AnyView?

  public let render: Render

  public init(render: @escaping Render) {
    self.render = render
  }
}

extension View {
  /// Installs a custom renderer for fenced code blocks.
  ///
  /// - parameter custom: `nil` restores the stock code block for every fence.
  ///
  /// - Returns: A view that applies the renderer to itself and its child views.
  public func markdownCodeBlockOverride(_ custom: MarkdownCodeBlockOverride?) -> some View {
    self.environment(\.markdownCodeBlockOverride, custom)
  }
}

extension EnvironmentValues {
  var markdownCodeBlockOverride: MarkdownCodeBlockOverride? {
    get { self[MarkdownCodeBlockOverrideKey.self] }
    set { self[MarkdownCodeBlockOverrideKey.self] = newValue }
  }
}

private struct MarkdownCodeBlockOverrideKey: EnvironmentKey {
  static let defaultValue: MarkdownCodeBlockOverride? = nil
}
