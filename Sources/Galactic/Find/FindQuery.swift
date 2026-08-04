import Foundation

/// What the page searches for, given what someone typed.
///
/// The find bar used to hand the field's text to the matcher untouched, and the
/// matcher searches literally — so a trailing space left by typing became a
/// character the document had to contain, and matches disappeared for a reason
/// nothing on screen explained. `CheatSheetSearch` had already met this and
/// trims before it reads a query; the two search surfaces disagreed only
/// because one of them never asked the question.
///
/// Pure and Foundation-only for the same reason that one is: the pipeline it
/// feeds is main-actor, Combine-driven, and pointed at a web view, so the rule
/// is only checkable if it lives somewhere a test can reach without any of
/// that.
public enum FindQuery {

    /// The text to search for, or the empty string when there is nothing to
    /// search for.
    ///
    /// Trimming is the whole job. Interior whitespace is intent — a query of
    /// two words asks for two words with a space between them, which is a
    /// search the page should attempt — so only the ends are cleaned and the
    /// middle survives exactly as typed.
    ///
    /// Whitespace alone normalizes to empty, which every consumer already
    /// treats as "nothing to search for": the matcher drops its highlights and
    /// the bar draws no count. That case is worth naming because the
    /// alternative is not a harmless no-op — a lone space searched literally
    /// matches the blank padding of every line in a terminal buffer, wrapping
    /// thousands of nodes to say nothing.
    public static func normalized(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
