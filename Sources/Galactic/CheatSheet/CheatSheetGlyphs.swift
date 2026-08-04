import Foundation

/// Spelling a keystroke's glyphs out in words, so they can be searched.
///
/// A row's keys render as "⇧⌘⌫" or "⌥⌘H", and none of those characters can be
/// typed into a search field — so before this, no query could reach a modifier
/// at all. The names are derived from the glyphs rather than written per row:
/// a host has a hundred rows and this table has twenty entries, and a derived
/// spelling cannot fall out of step with what the row displays.
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
        // Two glyphs for one key, and both are here rather than one being
        // declared correct. Hosts disagree — a menu-derived row tends to
        // carry ⏎ while a row quoting a chord the app prints on itself
        // carries ↩ — and a reader typing "return" cannot be expected to
        // know which. Spelling both is a smaller thing than making every
        // host normalise its authored rows to a house glyph.
        "⏎": "return enter",
        "↩": "return enter",
        "␣": "space spacebar",
        "←": "left arrow",
        "→": "right arrow",
        "↑": "up arrow",
        "↓": "down arrow",
        // The navigation cluster. Reachable only from a surface that scrolls
        // a page rather than moving a selection, which is why the first host
        // to need them was the one with a scrollback.
        "⇞": "page up",
        "⇟": "page down",
        "↖": "home",
        "↘": "end",
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
