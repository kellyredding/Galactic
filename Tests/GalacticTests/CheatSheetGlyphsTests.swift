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

    /// Both return glyphs answer to the same words.
    ///
    /// The bug this prevents: a host authored seventeen rows carrying ↩ while
    /// the table held only ⏎, so every one of them was invisible to "return"
    /// and "enter" — the two words a reader is most likely to type for the key
    /// they press most often. Nothing failed; the rows simply never appeared.
    func testEitherReturnGlyphSpellsTheSameWords() {
        XCTAssertEqual(CheatSheetGlyphs.spelled("⏎"), "return enter")
        XCTAssertEqual(CheatSheetGlyphs.spelled("↩"), "return enter")
        XCTAssertEqual(
            CheatSheetGlyphs.spelled("⇧⌘↩"),
            "shift command cmd return enter",
            "a chord mixing modifiers with ↩ spells every part")
    }

    /// The page-navigation cluster, which a scrolling surface needs and a
    /// selection-moving one never mentions.
    func testTheNavigationClusterIsSpelled() {
        XCTAssertEqual(CheatSheetGlyphs.spelled("⇞"), "page up")
        XCTAssertEqual(CheatSheetGlyphs.spelled("⇟"), "page down")
        XCTAssertEqual(CheatSheetGlyphs.spelled("↖"), "home")
        XCTAssertEqual(CheatSheetGlyphs.spelled("↘"), "end")
    }

    /// Punctuation keys a host binds navigation and help to.
    ///
    /// The bug this prevents: a host's back / forward pair and its help row
    /// carried ⌘[ ⌘] ⌘?, and none of those three characters had a name — so
    /// the only route to them was whatever their authored aliases happened to
    /// say, and a reader typing "bracket" found nothing.
    func testPunctuationKeysAHostBindsNavigationToAreSpelled() {
        XCTAssertEqual(
            CheatSheetGlyphs.spelled("⌘["),
            "command cmd left bracket open bracket")
        XCTAssertEqual(
            CheatSheetGlyphs.spelled("⌘]"),
            "command cmd right bracket close bracket")
        XCTAssertEqual(
            CheatSheetGlyphs.spelled("⌘?"), "command cmd question mark")
    }

    /// A bracket is named for the character, never for what a host binds to
    /// it.
    ///
    /// Same rule the ⌫ entry states: this table answers "what is that
    /// character called", and the concept a row belongs to is the row's own
    /// business. Spelling ⌘[ as "back" would drag every host's bracket row
    /// into a search for a word only one host's binding justifies.
    func testABracketIsNotNamedForWhatItDoes() {
        let bracket = CheatSheetGlyphs.spelled("[")
        XCTAssertFalse(bracket.contains("back"))
        XCTAssertFalse(CheatSheetGlyphs.spelled("]").contains("forward"))
    }
}
