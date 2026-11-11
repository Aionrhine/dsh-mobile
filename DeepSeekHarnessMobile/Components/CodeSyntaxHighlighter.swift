import DeepSeekHarnessShared
import MarkdownUI
import SwiftUI
import UIKit

struct DSHCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    var dark = false

    private struct Key: Hashable {
        let source: String
        let language: String?
        let dark: Bool
    }

    private static let cache = MarkdownRenderProductCache<Key, NSAttributedString>(
        countLimit: 128, costLimit: 4 * 1_024 * 1_024
    )

    func highlightCode(_ code: String, language: String?) -> Text {
        Text(highlightedCode(code, language: language))
    }

    func highlightedCode(_ code: String, language: String?) -> AttributedString {
        let value = attributedCode(code, language: language)
        let source = code as NSString
        var result = AttributedString()
        // 显式转为 SwiftUI 的 Color；NSAttributedString 的 UIKit 属性不能直接交给 Text。
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { color, range, _ in
            var part = AttributedString(source.substring(with: range))
            if let color = color as? UIColor { part.foregroundColor = Color(uiColor: color) }
            result += part
        }
        return result
    }

    func attributedCode(_ code: String, language: String?) -> NSAttributedString {
        Self.cache.value(for: Key(source: code, language: language, dark: dark)) {
            let result = NSMutableAttributedString(string: code)
            let tokens = CodeSyntaxHighlighting.shared.highlight(source: code, info: language)
            for token in tokens {
                let start = Int(token.start)
                let end = Int(token.endExclusive)
                guard start >= 0, end > start, end <= result.length else { continue }
                let rgb = UInt32(bitPattern: CodeSyntaxHighlighting.shared.color(kind: token.kind, dark: dark))
                let color = UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255,
                                    green: CGFloat((rgb >> 8) & 0xff) / 255,
                                    blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
                result.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: end - start))
            }
            return (NSAttributedString(attributedString: result), code.utf16.count * 12)
        }
    }
}

/// Reuses only render products; callbacks, font sizes and themes stay on the
/// current view. File order owns the synthetic URL indices and belongs in the key.
enum PreparedMarkdownCache {
    private struct Key: Hashable {
        let source: String
        let filePaths: [String]
    }

    private static let cache = MarkdownRenderProductCache<Key, MarkdownUI.MarkdownContent>(
        countLimit: 128, costLimit: 8 * 1_024 * 1_024
    )

    static func document(for source: String, filePaths: [String]) -> MarkdownUI.MarkdownContent {
        let key = Key(source: source, filePaths: filePaths)
        return cache.value(for: key) {
            // File references keep the original inline-code text for AST linking.
            let math = MarkdownMath.prepare(source)
            let padded = filePaths.isEmpty ? InlineCodePadding.apply(to: math) : math
            var destinations: [String: String] = [:]
            for (index, path) in filePaths.enumerated() {
                let destination = "dsh-file-reference:///(index)"
                destinations[path] = destination
                let name = path.replacingOccurrences(of: "\\", with: "/")
                    .split(separator: "/").last.map(String.init) ?? path
                if ConversationFileReferences.shared.knownPath(code: name, paths: filePaths) != nil {
                    destinations[name] = destination
                }
            }
            let document = ParsedMarkdownCache.document(for: padded).linkingInlineCode(destinations)
            let bytes = source.utf16.count * 2 + filePaths.reduce(0) { $0 + $1.utf16.count * 2 }
            // Account for the retained key/source and parsed/re-written tree.
            return (document, bytes * 4)
        }
    }
}

/// A small, bounded LRU for immutable rendering products. Oversized entries are
/// rendered normally without displacing the whole conversation's cached work.
final class MarkdownRenderProductCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let cost: Int
    }

    private let lock = NSLock()
    private let countLimit: Int
    private let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []
    private var totalCost = 0
    private var generation: UInt64 = 0
    private var memoryWarningObserver: NSObjectProtocol?

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = max(0, countLimit)
        self.costLimit = max(0, costLimit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func value(for key: Key, makeValue: () -> (Value, Int)) -> Value {
        lock.lock()
        if let entry = entries[key] {
            touch(key)
            lock.unlock()
            return entry.value
        }
        let startedGeneration = generation
        lock.unlock()
        let (value, cost) = makeValue()
        guard countLimit > 0, cost >= 0, cost <= costLimit else { return value }
        lock.lock()
        defer { lock.unlock() }
        guard generation == startedGeneration else { return value }
        if let entry = entries[key] {
            touch(key)
            return entry.value
        }
        while entries.count >= countLimit || cost > costLimit - totalCost {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
        }
        entries[key] = Entry(value: value, cost: cost)
        totalCost += cost
        recency.append(key)
        return value
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        totalCost = 0
        generation &+= 1
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// Completed messages are immutable, but collection-view reuse can bring the
/// same message on screen many times. Reuse MarkdownUI's parsed block tree so
/// scrolling does not repeatedly parse long responses on the main thread.
private enum ParsedMarkdownCache {
    private final class Box: NSObject {
        let document: MarkdownUI.MarkdownContent

        init(_ document: MarkdownUI.MarkdownContent) {
            self.document = document
        }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    static func document(for source: String) -> MarkdownUI.MarkdownContent {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.document
        }
        let document = MarkdownUI.MarkdownContent(source)
        cache.setObject(Box(document), forKey: key, cost: source.utf8.count)
        return document
    }
}
