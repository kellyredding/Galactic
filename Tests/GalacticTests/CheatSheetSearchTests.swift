import Foundation
import XCTest
@testable import Galactic

/// What the cheat sheet's filter keeps, and where it says the match landed.
///
/// The rule lived inline in a view before it moved here, which is how it came
/// to read a whole row as one gap-anywhere subsequence without anyone noticing:
/// nothing could reach it to check.
final class CheatSheetSearchTests: XCTestCase {

    private func candidate(
        label: String = "Clear session",
        keys: String = "⇧⌘⌫",
        section: String = "Terminal & Agent",
        condition: String = "while a terminal pane is focused",
        aliases: String = ""
    ) -> CheatSheetSearch.Candidate {
        CheatSheetSearch.Candidate(
            label: label, keys: keys, section: section,
            condition: condition, aliases: aliases
        )
    }

    // MARK: - What comes back

    /// Index-aligned with the input, nil where a row is filtered out. The view
    /// zips the two together, so a shorter or reordered result would hang every
    /// hit on the wrong row.
    func testHitsAreIndexAlignedWithTheCandidates() {
        let hits = CheatSheetSearch.hits(
            [
                candidate(label: "Clear session"),
                candidate(
                    label: "Open the reader", keys: "⏎",
                    section: "Lists", condition: ""),
                candidate(label: "Compact session"),
            ],
            query: "session")

        XCTAssertEqual(hits.count, 3)
        XCTAssertNotNil(hits[0])
        XCTAssertNil(hits[1], "nothing in that row says \"session\"")
        XCTAssertNotNil(hits[2])
    }

    func testAnEmptyQueryKeepsEveryRowAndMarksNothing() {
        let hits = CheatSheetSearch.hits(
            [candidate(), candidate(label: "Compact session")], query: "  ")

        XCTAssertEqual(hits.compactMap { $0 }.count, 2)
        XCTAssertEqual(
            hits[0], CheatSheetSearch.Hit(),
            "matched, with nothing for the row to draw"
        )
    }

    func testNoCandidatesYieldNoHits() {
        XCTAssertTrue(CheatSheetSearch.hits([], query: "clear").isEmpty)
    }

    // MARK: - Where the match landed

    /// Per field, because each is drawn separately. One offset list for the
    /// whole row would tint the label using positions counted through the keys.
    func testOffsetsAreReportedPerRenderedField() throws {
        let hits = CheatSheetSearch.hits(
            [candidate(label: "Clear session", condition: "in a terminal")],
            query: "clear")
        let hit = try XCTUnwrap(hits[0])

        XCTAssertEqual(hit.labelOffsets, [0, 1, 2, 3, 4])
        XCTAssertEqual(hit.keysOffsets, [], "the keys do not say \"clear\"")
        XCTAssertEqual(hit.conditionOffsets, [])
    }

    /// A space stands in for a gap, which is what makes a two-word query
    /// narrow rather than broad.
    func testASpaceStandsInForAGapWithinOneField() throws {
        let hits = CheatSheetSearch.hits(
            [candidate(
                label: "Move to Icebox", keys: "⌘I",
                section: "Lists", condition: "")],
            query: "mo ice")
        let hit = try XCTUnwrap(hits[0])

        XCTAssertEqual(hit.labelOffsets, [0, 1, 8, 9, 10])
    }

    /// Trimmed before it reaches the matcher, so a trailing space left by
    /// typing does not become a term nothing can satisfy.
    func testTheQueryIsTrimmedBeforeItIsRead() throws {
        let hits = CheatSheetSearch.hits(
            [candidate(label: "Clear session")], query: "  clear  ")
        let hit = try XCTUnwrap(hits[0])

        XCTAssertEqual(hit.labelOffsets, [0, 1, 2, 3, 4])
    }

    // MARK: - Matched, and nowhere to say so

    /// A row kept for its section title shows no highlight. The section is
    /// drawn once above a run of rows, so there is nowhere on the row to put
    /// one — and no highlight is the honest answer, not a bug.
    func testASectionOnlyMatchIsKeptButNotHighlighted() throws {
        let hits = CheatSheetSearch.hits(
            [candidate(
                label: "Clear session", section: "Terminal & Agent",
                condition: "")],
            query: "agent")
        let hit = try XCTUnwrap(hits[0], "the section title is searched")

        XCTAssertEqual(
            hit, CheatSheetSearch.Hit(),
            "matched, and nothing on the row can say why"
        )
    }

    /// Same for the aliases, which are not drawn at all. This is what lets a
    /// query reach a glyph no keyboard can type into the field.
    func testAnAliasOnlyMatchIsKeptButNotHighlighted() throws {
        let hits = CheatSheetSearch.hits(
            [candidate(
                label: "Clear session", section: "Terminal", condition: "",
                aliases: "wipe reset "
                    + CheatSheetGlyphs.spelled("⇧⌘⌫"))],
            query: "backspace")
        let hit = try XCTUnwrap(hits[0], "spelled glyphs are searched")

        XCTAssertEqual(hit, CheatSheetSearch.Hit())
    }

    // MARK: - The one rule

    /// No second, looser pass. Gap-anywhere subsequence matching answered
    /// "scrat" with "Leave input mode (discards the draft)" — five characters
    /// scattered over three words — and a search that answers a typo with a
    /// wrong row is worse than one that answers nothing.
    func testAQueryDoesNotMatchThroughScatteredCharacters() {
        let hits = CheatSheetSearch.hits(
            [candidate(
                label: "Leave input mode (discards the draft)",
                keys: "esc", section: "Text Entry", condition: "")],
            query: "scrat")

        XCTAssertNil(hits[0], "initials are not worth an unpredictable rule")
    }

    func testAQueryMatchesInsideAWord() {
        let hits = CheatSheetSearch.hits(
            [candidate(label: "Compact session")], query: "pact")

        XCTAssertNotNil(hits[0])
    }

    /// Any one field is enough. Checked on the keys because they are the field
    /// a reader is most likely to search and the one no other test covers.
    func testAKeysOnlyMatchKeepsTheRow() throws {
        let hits = CheatSheetSearch.hits(
            [candidate(
                label: "Clear session", keys: "⌥⌘H",
                section: "Lists", condition: "")],
            query: "h")
        let hit = try XCTUnwrap(hits[0])

        XCTAssertEqual(hit.keysOffsets, [2])
        XCTAssertEqual(hit.labelOffsets, [])
    }
}
