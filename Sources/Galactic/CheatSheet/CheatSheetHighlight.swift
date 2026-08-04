import SwiftUI

/// Tinting the characters a query matched.
///
/// Its own type rather than a method on the view. "The sheet's highlighter" is
/// exactly the framing that produced two of these in one app, drawn
/// differently, neither knowing about the other.
///
/// Internal, because there is one caller. Promoting it is one word when a
/// second arrives.
enum CheatSheetHighlight {

    /// `text` with the matched characters tinted, from the offsets the filter
    /// already computed — so the highlight cannot disagree with the filter
    /// about what matched. Walked character by character rather than indexed,
    /// which keeps a stray offset from trapping.
    ///
    /// Background only, no foreground. The caller has already said what colour
    /// its text is, with a `.foregroundStyle` on the `Text` or a colour on the
    /// string, and an attribute run setting one here would quietly win over
    /// both. A caller that needs matched characters to come *forward* out of
    /// dimmed text owns that decision, the same way it owns the rest of its
    /// type ramp.
    static func highlighted(
        _ text: String, _ offsets: [Int]
    ) -> AttributedString {
        guard !offsets.isEmpty else { return AttributedString(text) }
        let marked = Set(offsets)
        var out = AttributedString()
        for (i, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if marked.contains(i) {
                piece.backgroundColor = .yellow.opacity(0.35)
            }
            out += piece
        }
        return out
    }
}
