import XCTest

@testable import Galactic

final class PromptShortfallTests: XCTestCase {

    private let review = (1...200)
        .map { "> line \($0) of a long scrollback review" }
        .joined(separator: "\n")

    func testAPromptThatArrivedWholeHasNoShortfall() {
        XCTAssertNil(PromptShortfall.measure(sent: review + " ", received: review))
    }

    /// The shape measured on 2026-10-28: split across two paste blocks with
    /// the same id, the middle missing, and the tail outside any block.
    func testAPromptCutFromTheMiddleFallsShort() {
        let lines = review.components(separatedBy: "\n")
        let received = "\n\n<pasted_content id=\"8f77\">\n"
            + lines[0..<40].joined(separator: "\n")
            + "\n</pasted_content id=\"8f77\">\n\n\n<pasted_content id=\"8f77\">\n"
            + lines[40..<90].joined(separator: "\n")
            + "\n</pasted_content id=\"8f77\">\n\n"
            + lines[150...].joined(separator: "\n")

        let shortfall = try! XCTUnwrap(
            PromptShortfall.measure(sent: review, received: received))

        XCTAssertGreaterThan(shortfall.sentCharacters, shortfall.receivedCharacters)
        let expectedMissing = lines[90..<150].joined()
            .unicodeScalars.filter { $0 != " " }.count
        XCTAssertEqual(
            shortfall.sentCharacters - shortfall.receivedCharacters,
            expectedMissing
        )
    }

    func testSplitAcrossPasteBlocksWithNothingMissingIsWhole() {
        let lines = review.components(separatedBy: "\n")
        let received = "<pasted_content id=\"40de\">\n"
            + lines[0..<100].joined(separator: "\n")
            + "\n</pasted_content id=\"40de\">\n\n"
            + lines[100...].joined(separator: "\n")

        XCTAssertNil(PromptShortfall.measure(sent: review, received: received))
    }

    func testWhitespaceDifferencesAreNotALoss() {
        let reflowed = review
            .replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "  ", with: "\t")
        XCTAssertNil(PromptShortfall.measure(sent: review, received: reflowed))
    }

    func testASmallDifferenceIsWithinTolerance() {
        XCTAssertNil(
            PromptShortfall.measure(sent: "short prompt here", received: "short prompt"))
    }

    func testToleranceGrowsWithTheSize() {
        XCTAssertEqual(PromptShortfall.tolerance(for: 100), 16)
        XCTAssertEqual(PromptShortfall.tolerance(for: 9498), 94)
    }

    func testOnlyPasteWrappersAreStripped() {
        XCTAssertEqual(
            PromptShortfall.stripWrappers(
                "<pasted_content id=\"a1\">\nkeep <b>this</b>\n</pasted_content id=\"a1\">"),
            "\nkeep <b>this</b>\n"
        )
    }
}
