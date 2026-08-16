import Foundation
import XCTest
@testable import Galactic

/// What the two readings of a query mean, and that the offsets a caller tints
/// from actually name the characters that matched.
///
/// These were hand-rolled checks in a host's smoke executable before the
/// matcher moved here. Running them was a thing someone had to remember; the
/// checks themselves were never the hard part.
final class FuzzyMatchTests: XCTestCase {

    // MARK: - The empty query

    /// An empty query is a *successful* match, not a miss. Everything
    /// downstream leans on it: an unfiltered list is built by running the
    /// filter with no query, so nil here shows an empty sheet.
    func testAnEmptyQueryMatchesEverythingAndHighlightsNothing() {
        for scope in [FuzzyMatch.Scope.subsequence, .terms] {
            XCTAssertEqual(
                FuzzyMatch.result(
                    "Move to Icebox", query: "", scope: scope
                ),
                FuzzyMatch.Result(score: 0, matchedOffsets: []),
                "an empty query is a match with nothing to draw"
            )
        }
    }

    /// Trimming is the caller's job, and the two scopes disagree about
    /// whitespace — which is why `CheatSheetSearch` trims before it asks.
    func testWhitespaceMeansDifferentThingsToTheTwoScopes() {
        XCTAssertNotNil(
            FuzzyMatch.result("Move to Icebox", query: "   ", scope: .terms),
            "splitting on whitespace leaves no terms, so it matches"
        )
        XCTAssertNil(
            FuzzyMatch.result("Move to Icebox", query: "   "),
            "three spaces are three characters to find, and there are two"
        )
    }

    // MARK: - Subsequence

    /// Initials are the case this reading exists for.
    func testSubsequenceMatchesScatteredInitials() {
        XCTAssertTrue(FuzzyMatch.matches("Move to Icebox", query: "mti"))
    }

    func testSubsequenceNeedsTheCharactersInOrder() {
        XCTAssertFalse(FuzzyMatch.matches("Move to Icebox", query: "itm"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(FuzzyMatch.matches("Move to Icebox", query: "MTI"))
        XCTAssertTrue(
            FuzzyMatch.matches("MOVE TO ICEBOX", query: "move", scope: .terms)
        )
    }

    func testAQueryLongerThanTheCandidateCannotMatch() {
        XCTAssertNil(FuzzyMatch.result("ab", query: "abc"))
    }

    // MARK: - Terms

    /// The distinction the two scopes exist to draw, in one place: a term is
    /// contiguous, and a space is the only way to skip.
    func testATermMatchesInsideAWordButNotAcrossOne() {
        XCTAssertTrue(
            FuzzyMatch.matches("another", query: "the", scope: .terms),
            "\"the\" is one literal, and \"another\" contains it"
        )
        XCTAssertFalse(
            FuzzyMatch.matches("three", query: "the", scope: .terms),
            "\"three\" holds t, h and e but not adjacent in that order"
        )
        XCTAssertTrue(
            FuzzyMatch.matches("three", query: "th e", scope: .terms),
            "a space stands in for a gap, so \"th\" then \"e\" spans it"
        )
    }

    /// Ordering is what makes this more than a bag of substrings.
    func testTermsMustAppearInTheOrderTheQueryGivesThem() {
        XCTAssertNil(
            FuzzyMatch.result(
                "test item and this is a thing",
                query: "th e", scope: .terms
            ),
            "both fragments are present, but every e precedes the th"
        )
    }

    /// A term with several occurrences commits to the first. That cannot cost
    /// a match — an earlier start leaves at least as much room for the terms
    /// after it — but it can cost score, since the occurrence taken may not be
    /// the one at a word start. Pinned because the doc comment used to claim
    /// the stronger, false thing.
    func testAnEarlierTermCommitsToItsFirstOccurrence() {
        XCTAssertEqual(
            FuzzyMatch.result(
                "cabbage cab", query: "cab", scope: .terms
            )?.matchedOffsets,
            [0, 1, 2],
            "the first occurrence is taken, though the second is a whole word"
        )
    }

    // MARK: - Offsets

    /// The contract the highlighter reads: Character offsets into
    /// `Array(candidate.lowercased())`, ascending, one per matched character.
    /// Getting this wrong tints the wrong letters.
    func testSubsequenceOffsetsNameTheCharactersThatMatched() {
        let candidate = "Move to Icebox"
        let result = FuzzyMatch.result(candidate, query: "mti")
        let characters = Array(candidate.lowercased())

        XCTAssertEqual(result?.matchedOffsets, [0, 5, 8])
        XCTAssertEqual(
            (result?.matchedOffsets ?? []).map { characters[$0] },
            ["m", "t", "i"],
            "the offsets index the lowercased candidate, character-wise"
        )
    }

    func testTermOffsetsCoverEachTermContiguously() {
        XCTAssertEqual(
            FuzzyMatch.result(
                "three", query: "th e", scope: .terms
            )?.matchedOffsets,
            [0, 1, 3]
        )
    }

    /// Character offsets, not byte or UTF-16 offsets. A row's keys are glyphs
    /// — ⇧⌘⌫ — and every one of them is multi-byte, so a matcher counting
    /// anything else would tint the wrong half of a label.
    func testOffsetsAreCharacterOffsetsNotByteOffsets() {
        let candidate = "⇧⌘⌫ clear"
        let result = FuzzyMatch.result(candidate, query: "clear")

        XCTAssertEqual(result?.matchedOffsets, [4, 5, 6, 7, 8])
        XCTAssertEqual(
            (result?.matchedOffsets ?? []).map {
                Array(candidate.lowercased())[$0]
            },
            ["c", "l", "e", "a", "r"]
        )
    }

    // MARK: - Ranking

    /// Ranking is not what orders a cheat sheet's rows, but it is what any
    /// caller that ranks reads, so the three signals are pinned.
    func testAContiguousRunOutscoresScatteredCharacters() throws {
        let run = try XCTUnwrap(
            FuzzyMatch.score("clear session", query: "clea")
        )
        let scattered = try XCTUnwrap(
            FuzzyMatch.score("cancel later each ask", query: "clea")
        )

        XCTAssertGreaterThan(
            run, scattered,
            "a run is the strongest signal that the query is a substring"
        )
    }

    func testAnEarlierMatchOutscoresALaterOne() throws {
        let early = try XCTUnwrap(
            FuzzyMatch.score("open reader", query: "open")
        )
        let late = try XCTUnwrap(
            FuzzyMatch.score("reopen reader", query: "open")
        )

        XCTAssertGreaterThan(early, late)
    }

    /// The leading penalty is capped so a long tail cannot drive a real match
    /// negative — a negative score sorts below a miss in a caller that treats
    /// zero as a floor, which is worse than merely ranking last.
    func testTheLeadingPenaltyIsCapped() throws {
        let long = String(repeating: "x", count: 200) + " open"
        let score = try XCTUnwrap(FuzzyMatch.score(long, query: "open"))

        XCTAssertGreaterThan(score, 0)
    }

    /// A word start is what lets a space-separated chord rank as a real hit:
    /// "a i" reads as two words, so "ai" lands on two word starts.
    func testEachKeyOfASpacedChordCountsAsAWordStart() throws {
        let chord = try XCTUnwrap(FuzzyMatch.score("a i", query: "ai"))
        let buried = try XCTUnwrap(FuzzyMatch.score("mail", query: "ai"))

        XCTAssertGreaterThan(chord, buried)
    }

    // MARK: - The three entry points

    func testScoreAndMatchesAgreeWithResult() {
        XCTAssertEqual(
            FuzzyMatch.score("Move to Icebox", query: "mti"),
            FuzzyMatch.result("Move to Icebox", query: "mti")?.score
        )
        XCTAssertFalse(FuzzyMatch.matches("Move to Icebox", query: "zzz"))
    }

    // MARK: - Beyond ASCII

    /// Both scopes fold case by lowercasing, and each does it in its own order
    /// — one over the whole query, the other over each term after splitting.
    /// Nothing here left ASCII before, so nothing would have caught the two
    /// disagreeing.
    func testANonASCIIQueryFoldsCaseInBothScopes() {
        XCTAssertNotNil(
            FuzzyMatch.result("Übersicht", query: "ÜBER", scope: .terms)
        )
        XCTAssertNotNil(
            FuzzyMatch.result("Übersicht", query: "über", scope: .subsequence)
        )
        XCTAssertNotNil(
            FuzzyMatch.result("Ärger und Öl", query: "ärger öl", scope: .terms)
        )
    }

    /// Offsets index the candidate as characters, so an accented one occupies
    /// a single position however many scalars compose it.
    func testOffsetsCountAccentedCharactersAsOne() {
        XCTAssertEqual(
            FuzzyMatch.result("café", query: "É", scope: .terms)?
                .matchedOffsets,
            [3]
        )
    }
}
