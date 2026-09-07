import XCTest
@testable import Galactic

/// What a collapsed inbox row shows, and whether it hid anything.
///
/// The second question is the one worth pinning: it decides whether the expand
/// affordance appears at all, and it is true for two unrelated reasons. A check
/// that only knew about the character cap would leave a short, structured
/// message looking complete while its line breaks had been flattened away.
final class AgentInboxPreviewTests: XCTestCase {

    private let cap = AgentInboxPreview.characterCap

    // MARK: - Nothing hidden

    func testAShortSingleLineMessageIsShownWhole() {
        let body = "Sync my calendar."

        XCTAssertEqual(AgentInboxPreview.collapsed(body), body)
        XCTAssertFalse(AgentInboxPreview.isTruncated(body))
    }

    /// The cap is a ceiling, not a threshold — a message exactly at it is whole.
    func testAMessageExactlyAtTheCapIsShownWhole() {
        let body = String(repeating: "a", count: cap)

        XCTAssertEqual(AgentInboxPreview.collapsed(body), body)
        XCTAssertFalse(AgentInboxPreview.isTruncated(body))
    }

    /// Surrounding blank space is not content, so trimming it alone does not
    /// count as hiding something.
    func testSurroundingWhitespaceIsTrimmedWithoutCountingAsTruncation() {
        let body = "\n  Sync my calendar.  \n"

        XCTAssertEqual(AgentInboxPreview.collapsed(body), "Sync my calendar.")
        XCTAssertFalse(AgentInboxPreview.isTruncated(body))
    }

    // MARK: - Hidden by the cap

    func testAMessagePastTheCapIsCutAndMarked() {
        let body = String(repeating: "a", count: cap + 1)
        let collapsed = AgentInboxPreview.collapsed(body)

        XCTAssertTrue(collapsed.hasSuffix("…"))
        XCTAssertEqual(collapsed.count, cap + 1)
        XCTAssertTrue(AgentInboxPreview.isTruncated(body))
    }

    // MARK: - Hidden by flattening

    /// The case a length check misses. Every automated task prompt is shaped
    /// like this: short enough to fit, and unreadable once its lines run
    /// together.
    func testAShortMultiLineMessageCountsAsTruncated() {
        let body = "Automated task.\n\nThe task:\nSync my calendar."

        XCTAssertLessThan(body.count, cap)
        XCTAssertTrue(AgentInboxPreview.isTruncated(body))
        XCTAssertFalse(AgentInboxPreview.collapsed(body).contains("\n"))
    }

    /// Expanding restores the line breaks the collapsed row spent on width.
    func testExpandingKeepsTheMessageStructure() {
        let body = "Automated task.\n\nThe task:\nSync my calendar."

        XCTAssertEqual(AgentInboxPreview.full(body), body)
        XCTAssertNotEqual(
            AgentInboxPreview.full(body), AgentInboxPreview.collapsed(body)
        )
    }

    // MARK: - The two agree

    /// Whatever the collapsed form does, the affordance follows it. Asked of
    /// the strings rather than of the body's length, so the two cannot drift.
    func testTheAffordanceAppearsExactlyWhenTheFormsDiffer() {
        let bodies = [
            "short",
            String(repeating: "a", count: cap),
            String(repeating: "a", count: cap + 1),
            "two\nlines",
            "   ",
            "",
        ]
        for body in bodies {
            XCTAssertEqual(
                AgentInboxPreview.isTruncated(body),
                AgentInboxPreview.collapsed(body)
                    != AgentInboxPreview.full(body),
                "disagreed about \(body.debugDescription)"
            )
        }
    }
}
