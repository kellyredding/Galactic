import XCTest

@testable import Galactic

/// What the find bar searches for, given what was typed.
///
/// The matcher searches literally, so every character in the query is a
/// character the document must contain — which makes the difference between the
/// field's text and the search a correctness question rather than a tidiness
/// one. These pin both directions: what gets cleaned off, and what must survive
/// untouched.
final class FindQueryTests: XCTestCase {

    /// The reported bug, in one assertion. A trailing space is a keystroke on
    /// the way to a second word, not a character to hunt for.
    func testATrailingSpaceSearchesForTheSameThing() {
        XCTAssertEqual(
            FindQuery.normalized("stage "),
            FindQuery.normalized("stage"),
            "typing a space after a word must not change what is searched for"
        )
    }

    func testTheEndsAreCleaned() {
        XCTAssertEqual(FindQuery.normalized("  stage"), "stage")
        XCTAssertEqual(FindQuery.normalized("stage  "), "stage")
        XCTAssertEqual(FindQuery.normalized("  stage  "), "stage")
    }

    /// The half that must not be over-corrected. Trimming a query is safe;
    /// collapsing one is not — two words with a space between them is a search
    /// the page should attempt exactly as asked.
    func testTheMiddleIsLeftAlone() {
        XCTAssertEqual(FindQuery.normalized("Stage 1"), "Stage 1")
        XCTAssertEqual(
            FindQuery.normalized("  send   bar  "),
            "send   bar",
            "interior spacing is intent, however odd it looks"
        )
    }

    /// Whitespace alone is nothing to search for. Worth pinning because the
    /// alternative is not a quiet no-op: searched literally, a lone space
    /// matches the blank padding of every line in a terminal buffer.
    func testWhitespaceAloneIsNothingToSearchFor() {
        XCTAssertEqual(FindQuery.normalized(" "), "")
        XCTAssertEqual(FindQuery.normalized("    "), "")
        XCTAssertEqual(FindQuery.normalized("\t\n "), "")
    }

    /// Tabs and newlines arrive by paste rather than by typing, and mean the
    /// same nothing at the ends of a query that a space does.
    func testTabsAndNewlinesAreTrimmedToo() {
        XCTAssertEqual(FindQuery.normalized("\tstage\n"), "stage")
    }

    func testAnAlreadyCleanQueryIsUnchanged() {
        XCTAssertEqual(FindQuery.normalized("stage"), "stage")
        XCTAssertEqual(FindQuery.normalized(""), "")
    }

    /// Case is the matcher's business, not this one's — it folds case itself,
    /// and a query that arrived here pre-folded would strip the field of the
    /// capitals someone typed.
    func testCaseIsNotThisRulesJob() {
        XCTAssertEqual(FindQuery.normalized("Stage"), "Stage")
    }
}
