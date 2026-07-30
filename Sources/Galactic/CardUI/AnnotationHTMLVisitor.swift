import Foundation

/// Escapes annotation/note content for safe HTML splicing.
///
/// Notes and annotations are rendered verbatim — what the user
/// typed is what gets displayed and what the agent receives via
/// timeline events. There is no markdown parsing, no auto-linking,
/// and no soft-break translation. CSS `white-space: pre-wrap` on
/// the `.verbatim-card-content` container preserves newlines and
/// runs of whitespace, so this function only needs to escape the
/// three characters that would otherwise break HTML parsing.
///
/// The filename predates the rewrite — when it housed a
/// swift-markdown `MarkupVisitor` — and is left in place to keep
/// the diff focused.
public func escapeAnnotationContent(_ source: String) -> String {
    var s = source
    s = s.replacingOccurrences(of: "&", with: "&amp;")
    s = s.replacingOccurrences(of: "<", with: "&lt;")
    s = s.replacingOccurrences(of: ">", with: "&gt;")
    return s
}
