import Foundation
import XCTest
@testable import Galactic

/// Spelling a chord's glyphs out, so a query can reach a modifier no keyboard
/// puts into a search field.
final class CheatSheetGlyphsTests: XCTestCase {

    func testEveryModifierGlyphHasWords() {
        XCTAssertEqual(CheatSheetGlyphs.spelled("⌘"), "command cmd")
        XCTAssertEqual(CheatSheetGlyphs.spelled("⌥"), "option opt alt")
        XCTAssertEqual(CheatSheetGlyphs.spelled("⌃"), "control ctrl")
        XCTAssertEqual(CheatSheetGlyphs.spelled("⇧"), "shift")
    }

    /// Spelled in the order the chord writes them, so the words read the way a
    /// person would say the chord.
    func testAChordSpellsItsGlyphsInOrder() {
        XCTAssertEqual(
            CheatSheetGlyphs.spelled("⇧⌘⌫"),
            "shift command cmd backspace"
        )
    }

    /// The one judgment in the table, and the reason it is worth pinning at a
    /// shared seam. macOS prints "Delete" on the key; this deliberately does
    /// not say so, because where the ⌫ rows are destructive session commands,
    /// answering every search for "delete" with them is the opposite of
    /// grouping a concept. A host whose ⌫ row means "delete the selected
    /// thing" wants `CheatSheetRow.aliases`, not a change here.
    func testBackspaceIsNotSpelledDelete() {
        XCTAssertEqual(CheatSheetGlyphs.spelled("⌫"), "backspace")
        XCTAssertFalse(CheatSheetGlyphs.spelled("⌫").contains("delete"))
    }

    /// "esc" is already a word on the row rather than a glyph, so it needs its
    /// own look: the row reads "esc" and "escape" is what a reader types.
    func testEscIsSpelledOutEvenThoughItIsAlreadyAWord() {
        XCTAssertEqual(CheatSheetGlyphs.spelled("esc"), "escape")
        XCTAssertEqual(CheatSheetGlyphs.spelled("⇧esc"), "shift escape")
    }

    /// Punctuation is in the table for the same reason a modifier is: ⌘/ and
    /// ⌘, are chords a reader would search for by name.
    func testPunctuationKeysAreSpelledToo() {
        XCTAssertEqual(CheatSheetGlyphs.spelled("⌘/"), "command cmd slash")
        XCTAssertEqual(CheatSheetGlyphs.spelled("⌘,"), "command cmd comma")
    }

    /// A bare letter chord holds no glyphs, and empty is the right answer — an
    /// alias field padded with noise words would match everything.
    func testALetterChordSpellsNothing() {
        XCTAssertEqual(CheatSheetGlyphs.spelled("a d"), "")
        XCTAssertEqual(CheatSheetGlyphs.spelled(""), "")
    }
}
