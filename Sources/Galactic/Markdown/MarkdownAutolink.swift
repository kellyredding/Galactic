import Foundation

/// Where the bare URLs are in a run of plain markdown text.
///
/// CommonMark links `[text](url)`, and the GFM autolink extension links a bare
/// `https://…` too — but swift-markdown attaches only `table`,
/// `strikethrough`, and `tasklist`, so bare URLs are never an extension's
/// business here. They arrive at an emitter as ordinary `Markdown.Text`, and
/// someone who pasted a URL into a note gets grey, unclickable text.
///
/// ### Why this runs after the parse, not over the source
///
/// The obvious fix is to rewrite the source first, wrapping each bare URL as
/// `[url](url)` — which is what the CLI does at write time. Repeating it here
/// would be wrong: a regex over source cannot see that it is inside a fenced
/// block or an inline code span, so it links text the document says is
/// literal, and it shifts every offset after it. Locating the spans *after*
/// the parse lets the node type answer that question instead — code is
/// `CodeBlock` and `InlineCode`, a link's target is a destination, and none of
/// those are `Text`. Nothing is rewritten, so nothing moves.
///
/// ### Why a scheme is required
///
/// `NSDataDetector` is the stock answer, and it is too eager for this content:
/// it reads a trailing two-letter TLD as a host, so a note mentioning
/// `paths.cr` or `scratch.cr` would come back as a link to Costa Rica.
/// Requiring `http://` or `https://` means a URL is linked because its author
/// wrote one, not because a filename resembled one — and it is the same rule
/// the CLI applies at write time, so the two agree about what a bare URL is.
enum MarkdownAutolink {

    /// A bare URL found in a string, and where it sits.
    struct Span {
        let range: Range<String.Index>
        let url: URL
    }

    /// The bare URLs in `text`, in the order they appear.
    static func spans(in text: String) -> [Span] {
        guard text.contains("://") else { return [] }

        var found: [Span] = []
        var searchFrom = text.startIndex

        while searchFrom < text.endIndex,
              let candidate = text.range(
                  of: Self.pattern,
                  options: .regularExpression,
                  range: searchFrom..<text.endIndex
              )
        {
            searchFrom = candidate.upperBound
            guard startsAtBoundary(candidate.lowerBound, in: text) else {
                continue
            }
            let range = trimmingTrailingNoise(candidate, in: text)
            // Anything Foundation will not read as a URL stays plain text: a
            // grey URL is a much smaller failure than a link that goes
            // somewhere the author did not write.
            guard let url = URL(
                string: String(text[range]), encodingInvalidCharacters: true
            ) else { continue }
            found.append(Span(range: range, url: url))
        }
        return found
    }

    /// Everything up to whitespace or an angle bracket. Angle brackets are
    /// excluded because `<https://…>` is already a parsed autolink and its
    /// closing bracket is not part of the address.
    private static let pattern = "https?://[^\\s<>]+"

    /// A URL has to start at a word boundary, so `nothttps://x` is not a link.
    /// Punctuation before it is fine — a URL in parentheses is still a URL.
    private static func startsAtBoundary(
        _ start: String.Index, in text: String
    ) -> Bool {
        guard start > text.startIndex else { return true }
        let previous = text[text.index(before: start)]
        return !previous.isLetter && !previous.isNumber
    }

    /// Drop the trailing characters that belong to the sentence rather than to
    /// the address.
    ///
    /// Two rules, both from the GFM autolink extension. Sentence punctuation
    /// never ends a URL, so it comes off unconditionally. A closing bracket
    /// might legitimately be part of one — Wikipedia's `Foo_(bar)` — so it
    /// comes off only when the address does not open it, which is what tells
    /// `(https://example.com)` apart from `https://example.com/Foo_(bar)`.
    private static func trimmingTrailingNoise(
        _ range: Range<String.Index>, in text: String
    ) -> Range<String.Index> {
        var end = range.upperBound
        while end > range.lowerBound {
            let last = text.index(before: end)
            let character = text[last]
            if Self.sentencePunctuation.contains(character) {
                end = last
                continue
            }
            if let opener = Self.brackets[character],
               isUnbalanced(character, opener, in: text[range.lowerBound..<end])
            {
                end = last
                continue
            }
            break
        }
        return range.lowerBound..<end
    }

    private static func isUnbalanced(
        _ closer: Character, _ opener: Character, in address: Substring
    ) -> Bool {
        address.filter { $0 == closer }.count
            > address.filter { $0 == opener }.count
    }

    /// Sentence punctuation, plus the markdown emphasis markers — an unpaired
    /// `*` or `_` is left in the text node verbatim, and it is not an address.
    private static let sentencePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "'", "\"", "*", "_", "~", "`",
    ]

    private static let brackets: [Character: Character] = [
        ")": "(",
        "]": "[",
        "}": "{",
    ]
}
