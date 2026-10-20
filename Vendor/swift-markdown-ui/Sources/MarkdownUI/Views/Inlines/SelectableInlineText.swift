import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit

/// Renders one inline run (a Markdown paragraph line) inside a real `UITextView`
/// so iOS shows the native selection handles and lets the user drag a partial
/// range. SwiftUI's `Text` + `.textSelection(.enabled)` only offers whole-view
/// selection and loses the drag gesture to the hosting scroll/collection view,
/// which is why long-press produced "Copy / Share" with no handles.
struct SelectableInlineText: UIViewRepresentable {
  let attributed: AttributedString

  @Environment(\.openURL) private var openURL

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.textContainer.widthTracksTextView = true
    view.dataDetectorTypes = []
    view.adjustsFontForContentSizeCategory = false
    view.textColor = .label
    view.tintColor = .tintColor
    view.delegate = context.coordinator
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.openURL = self.openURL
    let rendered = NSAttributedString(self.attributed)
    if view.attributedText != rendered {
      view.attributedText = rendered
    }
  }

  @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    let width = proposal.width ?? uiView.bounds.width
    guard width.isFinite, width > 0 else { return nil }
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: ceil(fitted.height))
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var openURL: OpenURLAction?

    func textView(
      _ textView: UITextView,
      shouldInteractWith URL: URL,
      in characterRange: NSRange,
      interaction: UITextItemInteraction
    ) -> Bool {
      guard let openURL else { return true }
      // Mirror MarkdownUI's SwiftUI behaviour: hand the URL to the environment
      // action so host-app link routing (file references, external links) works.
      Task { @MainActor in _ = openURL(URL) }
      return false
    }
  }
}

extension Array where Element == InlineNode {
  /// Array counterpart of `InlineNode.renderAttributedString`, used by
  /// `SelectableInlineText`. Inline images are not representable here; callers
  /// fall back to the SwiftUI renderer when images are present.
  func renderAttributedString(
    baseURL: URL?,
    textStyles: InlineTextStyles,
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) -> AttributedString {
    self.reduce(into: AttributedString()) { result, inline in
      result.append(
        inline.renderAttributedString(
          baseURL: baseURL,
          textStyles: textStyles,
          softBreakMode: softBreakMode,
          attributes: attributes
        )
      )
    }
  }
}
#endif
