import SwiftUI

/// A host-supplied reaction to a text selection inside rendered Markdown.
///
/// MarkdownUI stays unaware of what the host wants to do with the excerpt; the
/// host installs this value and decides whether it lands in a composer, a note,
/// or nowhere at all. `nil` is reported when the selection collapses, which is
/// how a host can withdraw a pending offer.
public struct MarkdownTextSelectionObserver: @unchecked Sendable {
  /// Receives the exact selected text, or `nil` once nothing is selected.
  public let handler: (String?) -> Void

  public init(handler: @escaping (String?) -> Void) {
    self.handler = handler
  }
}

extension View {
  /// Reports text selections made inside rendered Markdown.
  ///
  /// Nothing is drawn and no menu item is added, so selection handles, dragging
  /// to extend, and scrolling keep their stock behaviour.
  ///
  /// - parameter observer: `nil` stops the reporting.
  ///
  /// - Returns: A view that installs the observer for itself and its child
  ///   views.
  public func markdownTextSelectionObserver(_ observer: MarkdownTextSelectionObserver?) -> some View {
    self.environment(\.markdownTextSelectionObserver, observer)
  }
}

extension EnvironmentValues {
  var markdownTextSelectionObserver: MarkdownTextSelectionObserver? {
    get { self[MarkdownTextSelectionObserverKey.self] }
    set { self[MarkdownTextSelectionObserverKey.self] = newValue }
  }
}

private struct MarkdownTextSelectionObserverKey: EnvironmentKey {
  static let defaultValue: MarkdownTextSelectionObserver? = nil
}
