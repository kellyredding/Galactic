import XCTest

@testable import Galactic

/// Splitting the rescued composer state by what it belongs to.
///
/// One shared reader is rebuilt on every file switch, so this rescue is the only
/// thing carrying a reader's half-finished work across it. The blob mixes two
/// lifetimes — card state belongs to a file, the overall comment belongs to the
/// review — and filing it whole would make a summary reappear on one file and
/// vanish everywhere else, which reads as the app forgetting selectively.
final class ComposerStateMergeTests: XCTestCase {

    private func fields(_ json: String?) -> [String: Any] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return [:] }
        return dictionary
    }

    // MARK: - Lifting the set-wide half out

    func testTheCommentIsLiftedOutOfABlobThatHasOne() {
        let blob = #"{"textareaValue":"half","overallComment":"the summary","overallExpanded":true}"#

        let lifted = ComposerStateMerge.overallComment(from: blob)

        XCTAssertEqual(lifted?.text, "the summary")
        XCTAssertEqual(lifted?.expanded, true)
    }

    func testAnExpansionFlagDefaultsToClosed() {
        let blob = #"{"overallComment":"just text"}"#

        XCTAssertEqual(
            ComposerStateMerge.overallComment(from: blob)?.expanded, false
        )
    }

    /// A rebuild that reported no comment is not a reader deleting one, so the
    /// caller is told nothing rather than told to clear.
    func testABlobWithNoCommentLiftsNothing() {
        XCTAssertNil(
            ComposerStateMerge.overallComment(
                from: #"{"textareaValue":"half written"}"#
            )
        )
        XCTAssertNil(
            ComposerStateMerge.overallComment(
                from: #"{"overallComment":""}"#
            )
        )
    }

    /// A rescue that cannot be read costs the composer, never the file switch.
    func testUnreadableStateLiftsNothingRatherThanThrowing() {
        XCTAssertNil(ComposerStateMerge.overallComment(from: nil))
        XCTAssertNil(ComposerStateMerge.overallComment(from: "not json"))
        XCTAssertNil(ComposerStateMerge.overallComment(from: "[1,2,3]"))
        XCTAssertNil(ComposerStateMerge.overallComment(from: ""))
    }

    // MARK: - Writing it back in

    func testTheSetsCommentIsWrittenIntoTheFilesOwnState() {
        let perFile = #"{"textareaValue":"half","expandedNumber":3}"#

        let merged = ComposerStateMerge.merged(
            perFile: perFile, overallComment: "the summary", expanded: true
        )

        let out = fields(merged)
        XCTAssertEqual(out["textareaValue"] as? String, "half")
        XCTAssertEqual(out["expandedNumber"] as? Int, 3)
        XCTAssertEqual(out["overallComment"] as? String, "the summary")
        XCTAssertEqual(out["overallExpanded"] as? Bool, true)
    }

    /// Everything the page wrote survives untouched. What a half-written card
    /// consists of is the page's business, and this type interprets exactly two
    /// keys.
    func testEveryOtherFieldIsPassedThroughUnchanged() {
        let perFile = """
            {"currentBlockIndex":7,"highlightStart":7,"highlightEnd":9,\
            "formVisible":true,"selectionOnly":false,"textareaValue":"x",\
            "expandedNumber":2,"somethingAddedLater":"kept"}
            """

        let out = fields(
            ComposerStateMerge.merged(
                perFile: perFile, overallComment: "c", expanded: false
            )
        )

        XCTAssertEqual(out["currentBlockIndex"] as? Int, 7)
        XCTAssertEqual(out["highlightStart"] as? Int, 7)
        XCTAssertEqual(out["highlightEnd"] as? Int, 9)
        XCTAssertEqual(out["formVisible"] as? Bool, true)
        XCTAssertEqual(out["selectionOnly"] as? Bool, false)
        XCTAssertEqual(out["textareaValue"] as? String, "x")
        XCTAssertEqual(out["expandedNumber"] as? Int, 2)
        XCTAssertEqual(
            out["somethingAddedLater"] as? String, "kept",
            "a field this type has never heard of still arrives"
        )
    }

    /// The common case after opening a fresh file: no card state of its own, but
    /// a review-wide summary that has to survive getting there.
    func testACommentSurvivesArrivingAtAFileWithNoStateOfItsOwn() {
        let merged = ComposerStateMerge.merged(
            perFile: nil, overallComment: "the summary", expanded: false
        )

        XCTAssertEqual(fields(merged)["overallComment"] as? String, "the summary")
    }

    /// Nothing to restore is nil, not an empty object — the page tests the whole
    /// state for truthiness before doing anything with it.
    func testNothingToRestoreIsNil() {
        XCTAssertNil(
            ComposerStateMerge.merged(
                perFile: nil, overallComment: "", expanded: false
            )
        )
    }

    /// The reason the empty case removes rather than writes. A stale comment
    /// carried in from the file being left would reappear on the file being
    /// arrived at, having been deleted in between.
    func testAnEmptyCommentStripsWhateverTheBlobWasCarrying() {
        let stale = #"{"textareaValue":"keep","overallComment":"deleted","overallExpanded":true}"#

        let out = fields(
            ComposerStateMerge.merged(
                perFile: stale, overallComment: "", expanded: false
            )
        )

        XCTAssertNil(out["overallComment"])
        XCTAssertNil(out["overallExpanded"])
        XCTAssertEqual(
            out["textareaValue"] as? String, "keep",
            "and the file's own state is untouched by that"
        )
    }

    func testUnreadablePerFileStateStillCarriesTheComment() {
        let out = fields(
            ComposerStateMerge.merged(
                perFile: "not json", overallComment: "the summary",
                expanded: true
            )
        )

        XCTAssertEqual(out["overallComment"] as? String, "the summary")
    }

    // MARK: - Round trip

    /// What the two halves are for, end to end: a reader types a summary on one
    /// file, switches to another, and finds it still there.
    func testASummaryTypedOnOneFileArrivesAtTheNext() {
        // The page being left reports both halves at once.
        let rescued = #"{"textareaValue":"note in progress","overallComment":"overall","overallExpanded":true}"#

        // The host files the blob on the outgoing tab and lifts the comment to
        // the set.
        let lifted = ComposerStateMerge.overallComment(from: rescued)
        XCTAssertEqual(lifted?.text, "overall")

        // Arriving at a different file, which has its own card state.
        let incoming = #"{"textareaValue":"other file's note"}"#
        let out = fields(
            ComposerStateMerge.merged(
                perFile: incoming,
                overallComment: lifted?.text ?? "",
                expanded: lifted?.expanded ?? false
            )
        )

        XCTAssertEqual(
            out["textareaValue"] as? String, "other file's note",
            "the arriving file's own composer, not the one left behind"
        )
        XCTAssertEqual(
            out["overallComment"] as? String, "overall",
            "and the review's summary, which belongs to neither file"
        )
    }
}
