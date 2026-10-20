import Combine
import Foundation

/// One excerpt the user captured from a conversation message and parked above
/// the composer until the next prompt is sent.
///
/// `sourceMessageID` / `sourceSeq` are reserved for the protocol-backed quote:
/// the gateway's `message` frame currently carries only `text` and `images`, so
/// these stay `nil` and the excerpt travels as a Markdown blockquote inside the
/// prompt text. Once the gateway accepts a structured `quoted` field the same
/// value can be sent verbatim and rendered as a tappable citation.
struct MessageQuote: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let sourceMessageID: String?
    let sourceSeq: Int?
    let capturedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        sourceMessageID: String? = nil,
        sourceSeq: Int? = nil,
        capturedAt: Date = .now
    ) {
        self.id = id
        self.text = text
        self.sourceMessageID = sourceMessageID
        self.sourceSeq = sourceSeq
        self.capturedAt = capturedAt
    }

    /// Blockquote form folded into the outgoing prompt. Trailing whitespace is
    /// dropped but leading indentation is kept, so quoted code stays code; blank
    /// lines collapse to keep the excerpt inside one quote block.
    var promptBlock: String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(Self.trailingTrimmed)
            .filter { !$0.isEmpty }
        return lines.map { "> " + $0 }.joined(separator: "\n")
    }

    private static func trailingTrimmed(_ line: Substring) -> String {
        let text = String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard let end = text.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(text[...end])
    }

    /// Single-line label for the collapsed quote strip.
    var summary: String {
        let flat = text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }
}

/// App-wide queue of pending quotes.
///
/// Selection handlers run deep inside the message collection view, so they
/// append here instead of reaching the composer through per-row callbacks; the
/// composer observes the same object and owns presentation plus send-time
/// merging.
///
/// Every mutating call originates from a UI action, so the queue is only ever
/// touched on the main actor and needs no further isolation of its own.
final class ConversationQuoteInbox: ObservableObject {
    static let shared = ConversationQuoteInbox()

    /// Keeps the strip compact; the oldest capture falls off first.
    static let limit = 5

    @Published private(set) var quotes: [MessageQuote] = []

    var isEmpty: Bool { quotes.isEmpty }

    var count: Int { quotes.count }

    func capture(_ raw: String, sourceMessageID: String? = nil, sourceSeq: Int? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Re-quoting the same excerpt should not evict an older, different one.
        guard !quotes.contains(where: { $0.text == text }) else { return }
        quotes.append(
            MessageQuote(
                text: text,
                sourceMessageID: sourceMessageID,
                sourceSeq: sourceSeq
            )
        )
        if quotes.count > Self.limit {
            quotes.removeFirst(quotes.count - Self.limit)
        }
    }

    func remove(_ id: UUID) {
        quotes.removeAll { $0.id == id }
    }

    /// Called on send and on session switch; both end the lifetime of a quote.
    func clear() {
        guard !quotes.isEmpty else { return }
        quotes.removeAll()
    }

    /// Merges the queued excerpts in front of `body` as a single quote block.
    func applying(to body: String) -> String {
        guard !quotes.isEmpty else { return body }
        let quote = quotes.map(\.promptBlock).joined(separator: "\n>\n")
        return body.isEmpty ? quote : quote + "\n\n" + body
    }
}
