import SwiftUI

/// A host-supplied reaction to a text selection inside rendered Markdown.
///
/// MarkdownUI stays unaware of what the host wants to do with the excerpt; the
/// host installs this value and decides whether it lands in a composer, a note,
/// or nowhere at all.
public struct MarkdownTextSelectionQuote: @unchecked Sendable {
  /// Edit-menu item title, e.g. "Quote this".
  public let title: String
  /// Receives the exact text the user had selected.
  public let handler: (String) -> Void

  public init(title: String, handler: @escaping (String) -> Void) {
    self.title = title
    self.handler = handler
  }
}

extension View {
  /// Adds a quote action to the text-selection edit menu of rendered Markdown.
  ///
  /// - parameter quote: `nil` leaves the stock menu untouched, which keeps
  ///   selection and copy working for hosts that do not offer quoting.
  ///
  /// - Returns: A view that installs the quote action for itself and its child
  ///   views.
  public func markdownTextSelectionQuote(_ quote: MarkdownTextSelectionQuote?) -> some View {
    self.environment(\.markdownTextSelectionQuote, quote)
  }
}

extension EnvironmentValues {
  var markdownTextSelectionQuote: MarkdownTextSelectionQuote? {
    get { self[MarkdownTextSelectionQuoteKey.self] }
    set { self[MarkdownTextSelectionQuoteKey.self] = newValue }
  }
}

private struct MarkdownTextSelectionQuoteKey: EnvironmentKey {
  static let defaultValue: MarkdownTextSelectionQuote? = nil
}
