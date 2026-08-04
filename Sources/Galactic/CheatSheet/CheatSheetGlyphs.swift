import Foundation

/// Spelling a keystroke's glyphs out in words, so they can be searched.
///
/// A row's keys render as "⇧⌘⌫" or "⌥⌘H", and none of those characters can be
/// typed into a search field — so before this, no query could reach a modifier
/// at all. The names are derived from the glyphs rather than written per row:
/// there are a hundred rows and eleven glyphs, and a derived spelling cannot
/// fall out of step with what the row displays.
public enum CheatSheetGlyphs {

    /// Every glyph a host can put on a row, and the words a reader would type
    /// for it. Several map to more than one, because the same key has different
    /// names depending on which keyboard someone learned.
    private static let names: [Character: String] = [
        "⌘": "command cmd",
        "⌥": "option opt alt",
        "⌃": "control ctrl",
        "⇧": "shift",
        // "backspace" and deliberately NOT "delete", though macOS prints
        // Delete on the key.
        //
        // This is a judgment about *which rows carry ⌫*, and it is worth
        // naming as one at a shared seam. Where the ⌫ rows are destructive
        // session commands — clearing a session, compacting one — pulling
        // them into every search for "delete" is the exact opposite of
        // grouping a concept. Both hosts' ⌫ rows happen to be exactly those
        // two, so the call transfers; that is luck, not design. A host whose
        // ⌫ row means "delete the selected thing" is the case this table gets
        // wrong, and wants `CheatSheetRow.aliases` rather than a change here,
        // since one row's synonyms are not the table's business.
        "⌫": "backspace",
        "⏎": "return enter",
        "␣": "space spacebar",
        "←": "left arrow",
        "→": "right arrow",
        "↑": "up arrow",
        "↓": "down arrow",
        "/": "slash",
        ",": "comma",
        "=": "equals plus",
        "-": "minus dash hyphen",
    ]

    /// The words for whatever glyphs `keys` contains, joined — empty when it
    /// holds none, as a bare letter chord like "a d" does.
    public static func spelled(_ keys: String) -> String {
        var words = keys.compactMap { names[$0] }
        // A word rather than a glyph, so it needs its own look: the row already
        // reads "esc", and "escape" is what a reader types.
        if keys.lowercased().contains("esc") { words.append("escape") }
        return words.joined(separator: " ")
    }
}
