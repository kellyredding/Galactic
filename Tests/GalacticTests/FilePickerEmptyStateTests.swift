import XCTest

@testable import Galactic

/// Which nothing the picker is showing, and in which order it decides.
///
/// The precedence is the part worth pinning: five branches, each true in
/// overlapping conditions, and a wrong one does not fail — it tells a reader
/// something untrue about why they are looking at an empty list.
final class FilePickerEmptyStateTests: XCTestCase {

    private func message(
        hasRoot: Bool = true,
        isIndexing: Bool = false,
        isRootChange: Bool = false,
        query: String = ""
    ) -> String {
        FilePickerEmptyState.message(
            hasRoot: hasRoot,
            isIndexing: isIndexing,
            isRootChange: isRootChange,
            query: query
        )
    }

    /// Nothing below it can be true, so it wins outright — including over a
    /// query, which would otherwise promise a search of nowhere.
    func testNoRootBeatsEverythingElse() {
        XCTAssertEqual(
            message(
                hasRoot: false, isIndexing: true, isRootChange: true,
                query: "user"
            ),
            "No folder to browse"
        )
    }

    /// A walk in progress is *why* there are no rows, which is more use than
    /// instructions for something possible a moment later anyway.
    func testIndexingBeatsTheRootChangeHintAndTheQuery() {
        XCTAssertEqual(
            message(isIndexing: true, isRootChange: true, query: "~/pro"),
            "Reading the folder…"
        )
        XCTAssertEqual(
            message(isIndexing: true, query: "user"), "Reading the folder…"
        )
    }

    /// The other mode reports a path naming nowhere, and no longer explains its
    /// keys.
    ///
    /// It used to, because the rows were emptied the moment a path was typed
    /// and instructions were the only thing left to show. The rows are now the
    /// matching folders, so this message is reached only when there are none —
    /// and teaching Return and Tab here would describe a list the reader sees
    /// every other time.
    func testARootChangeReportsThatNothingIsThere() {
        let text = message(isRootChange: true, query: "~/zzz")

        XCTAssertEqual(text, "No folder here by that name")
        XCTAssertFalse(
            text.contains("Tab"),
            "the keys are no longer taught by the empty state"
        )
    }

    /// The first thing anyone sees. Leads with the action, then says what the
    /// space is for — and mentions neither of the two lists behind it, which the
    /// wording it replaced described to a reader who had never heard of them.
    func testTheEmptyQueryStateAsksForTypingRatherThanReportingAHistory() {
        let text = message(query: "")

        XCTAssertEqual(text, FilePickerEmptyState.emptyQuery)
        XCTAssertTrue(
            text.hasPrefix("Type to search"), "the action comes first"
        )
        for word in ["Nothing", "closed", "yet"] {
            XCTAssertFalse(
                text.contains(word),
                "\(word) describes the implementation, not the reader"
            )
        }

        // The space is fed by closed tabs and by recents-minus-open, so a file
        // open right now is in neither. The wording must not promise otherwise:
        // it did, and a reader with two files open watched them not appear.
        XCTAssertTrue(
            text.contains("previously opened"),
            "the copy has to say when a file shows up, not just that it will"
        )
    }

    func testATypedQueryWithNoMatchesSaysSo() {
        XCTAssertEqual(message(query: "zzz"), "No file matches")
    }
}
