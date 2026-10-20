import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit

/// Offers a host-supplied action while text is selected in a non-editable text
/// view.
///
/// Two delivery paths are used because neither is reliable on its own once
/// `isEditable` is `false`: the edit menu is asked for an extra item through
/// `buildMenu(with:)`, and a small capsule button is pinned above the selection
/// so the action is reachable even when the system menu ignores the request.
/// `UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)` is never
/// consulted in this configuration, which is why it is not used here.
final class QuoteMenuTextView: UITextView {
  var quoteTitle: String? {
    didSet { refreshQuoteAffordance() }
  }
  var onQuote: ((String) -> Void)?

  /// Paragraphs are separate text views, so only one capsule may be visible at
  /// a time; the previous one is torn down when a new selection takes over.
  private static weak var activeView: QuoteMenuTextView?

  private var buttonStorage: UIButton?

  private var quoteButton: UIButton {
    if let button = self.buttonStorage { return button }
    let button = self.makeQuoteButton()
    self.buttonStorage = button
    return button
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    self.placeQuoteButton()
  }

  /// Recomputes the capsule from the current selection.
  func refreshQuoteAffordance() {
    guard let title = self.quoteTitle,
          !title.isEmpty,
          self.onQuote != nil,
          self.selectedExcerpt() != nil
    else {
      self.hideQuoteAffordance()
      return
    }

    if let active = Self.activeView, active !== self {
      active.hideQuoteAffordance()
    }
    Self.activeView = self

    if self.quoteButton.superview == nil {
      self.addSubview(self.quoteButton)
    }
    self.quoteButton.configuration?.title = title
    self.quoteButton.isHidden = false
    self.placeQuoteButton()
  }

  private func hideQuoteAffordance() {
    self.buttonStorage?.isHidden = true
    if Self.activeView === self {
      Self.activeView = nil
    }
  }

  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    guard let title = self.quoteTitle,
          !title.isEmpty,
          let onQuote = self.onQuote,
          let excerpt = self.selectedExcerpt()
    else { return }

    let action = UIAction(title: title, image: UIImage(systemName: "text.quote")) { _ in
      onQuote(excerpt)
    }
    builder.insertChild(
      UIMenu(title: "", options: .displayInline, children: [action]),
      atStartOfMenu: .standardEdit
    )
  }

  // MARK: - Selection plumbing

  /// The selected text, or `nil` when the selection is empty or whitespace only.
  private func selectedExcerpt() -> String? {
    guard self.selectedRange.length > 0,
          let text = self.text,
          let range = Range(self.selectedRange, in: text)
    else { return nil }

    let excerpt = String(text[range])
    guard excerpt.contains(where: { !$0.isWhitespace }) else { return nil }
    return excerpt
  }

  private func makeQuoteButton() -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.image = UIImage(systemName: "text.quote")
    configuration.imagePadding = 5
    configuration.cornerStyle = .capsule
    // Opaque, so the paragraph underneath never shows through the capsule.
    configuration.baseBackgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : UIColor(white: 0.97, alpha: 1)
    }
    configuration.baseForegroundColor = .label
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 11, bottom: 5, trailing: 11)

    let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
      guard let self, let onQuote = self.onQuote, let excerpt = self.selectedExcerpt() else { return }
      self.selectedRange = NSRange(location: 0, length: 0)
      self.hideQuoteAffordance()
      onQuote(excerpt)
    })
    button.isHidden = true
    button.layer.borderWidth = 0.5
    button.layer.borderColor = UIColor.separator.cgColor
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.16
    button.layer.shadowRadius = 8
    button.layer.shadowOffset = CGSize(width: 0, height: 3)
    return button
  }

  private func placeQuoteButton() {
    guard let button = self.buttonStorage,
          !button.isHidden,
          let anchor = self.quoteAnchorRect()
    else { return }

    let size = self.quoteButton.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
    if origin.y < 0 {
      // Selections on the first line have no room above them.
      origin.y = min(anchor.maxY + 6, max(0, self.bounds.height - size.height))
    }
    origin.x = max(0, min(origin.x, max(0, self.bounds.width - size.width)))
    self.quoteButton.frame = CGRect(origin: origin, size: size)
  }

  /// Rect of the selection's first line, in this view's coordinate space.
  private func quoteAnchorRect() -> CGRect? {
    guard self.selectedRange.length > 0,
          let start = self.position(from: self.beginningOfDocument, offset: self.selectedRange.location),
          let end = self.position(from: start, offset: self.selectedRange.length),
          let range = self.textRange(from: start, to: end)
    else { return nil }

    let rect = self.firstRect(for: range)
    guard !rect.isNull, !rect.isInfinite, rect.height > 0 else { return nil }
    return rect
  }
}

/// Renders one inline run (a Markdown paragraph line) inside a real `UITextView`
/// so iOS shows the native selection handles and lets the user drag a partial
/// range. SwiftUI's `Text` + `.textSelection(.enabled)` only offers whole-view
/// selection and loses the drag gesture to the hosting scroll/collection view,
/// which is why long-press produced "Copy / Share" with no handles.
///
/// The incoming AttributedString is *unresolved*: it still carries MarkdownUI's
/// `fontProperties` instead of a SwiftUI `Font`, because `NSAttributedString`
/// cannot bridge SwiftUI fonts (that mismatch made text fall back to 12 pt).
struct SelectableInlineText: UIViewRepresentable {
  let attributed: AttributedString
  /// Host reaction to the quote menu item; `nil` keeps the stock edit menu.
  var onQuote: ((String) -> Void)? = nil
  /// Menu item title supplied by the host, applied when `onQuote` is set.
  var quoteTitle: String? = nil

  @Environment(\.openURL) private var openURL
  @Environment(\.colorScheme) private var colorScheme

  func makeUIView(context: Context) -> UITextView {
    let view = QuoteMenuTextView()
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
    if let quoting = view as? QuoteMenuTextView {
      quoting.quoteTitle = self.quoteTitle
      quoting.onQuote = self.onQuote
      quoting.refreshQuoteAffordance()
    }
    let rendered = Self.makeAttributedString(self.attributed)
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

    func textViewDidChangeSelection(_ textView: UITextView) {
      (textView as? QuoteMenuTextView)?.refreshQuoteAffordance()
    }

    func textView(
      _ textView: UITextView,
      shouldInteractWith URL: URL,
      in characterRange: NSRange,
      interaction: UITextItemInteraction
    ) -> Bool {
      guard let openURL else { return true }
      Task { @MainActor in _ = openURL(URL) }
      return false
    }
  }

  // MARK: - AttributedString -> NSAttributedString

  static func makeAttributedString(_ source: AttributedString) -> NSAttributedString {
    let baseFont = UIFont.preferredFont(forTextStyle: .body)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = (baseFont.lineHeight * 0.22).rounded()

    let output = NSMutableAttributedString()
    for run in source.runs {
      let slice = source[run.range]
      let text = String(slice.characters)
      guard !text.isEmpty else { continue }

      var attributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
      ]

      if let properties = slice[FontPropertiesAttribute.self] {
        attributes[.font] = uiFont(from: properties)
      } else {
        attributes[.font] = baseFont
      }

      if let color = slice[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] {
        attributes[.foregroundColor] = UIColor(color)
      } else {
        attributes[.foregroundColor] = UIColor.label
      }

      if let link = slice[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
        attributes[.link] = link
      }

      output.append(NSAttributedString(string: text, attributes: attributes))
    }
    return output
  }

  private static func uiFont(from properties: FontProperties) -> UIFont {
    let size = properties.scaledSize
    let weight = uiWeight(properties.weight)

    var font: UIFont
    switch properties.family {
    case .system(let design):
      font = UIFont.systemFont(ofSize: size, weight: weight)
      if let systemDesign = uiDesign(design),
         let descriptor = font.fontDescriptor.withDesign(systemDesign) {
        font = UIFont(descriptor: descriptor, size: size)
      }
    case .custom(let name):
      font = UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
    }

    if properties.familyVariant == .monospaced,
       let descriptor = font.fontDescriptor.withDesign(.monospaced) {
      font = UIFont(descriptor: descriptor, size: size)
    }

    if case .italic = properties.style,
       let descriptor = font.fontDescriptor.withSymbolicTraits(
         font.fontDescriptor.symbolicTraits.union(.traitItalic)
       ) {
      font = UIFont(descriptor: descriptor, size: size)
    }

    return font
  }

  private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
    switch weight {
    case .ultraLight: return .ultraLight
    case .thin: return .thin
    case .light: return .light
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .heavy: return .heavy
    case .black: return .black
    default: return .regular
    }
  }

  private static func uiDesign(_ design: Font.Design) -> UIFontDescriptor.SystemDesign? {
    switch design {
    case .monospaced: return .monospaced
    case .serif: return .serif
    case .rounded: return .rounded
    default: return nil
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
    attributes: AttributeContainer,
    resolveFonts: Bool = true
  ) -> AttributedString {
    self.reduce(into: AttributedString()) { result, inline in
      result.append(
        inline.renderAttributedString(
          baseURL: baseURL,
          textStyles: textStyles,
          softBreakMode: softBreakMode,
          attributes: attributes,
          resolveFonts: resolveFonts
        )
      )
    }
  }
}
#endif
