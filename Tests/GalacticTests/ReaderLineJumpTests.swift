import XCTest

@testable import Galactic

/// Going to a line by its number.
///
/// The number is the one in the gutter, and the markup already carries it — so
/// most of what is worth testing is that the script is built against the
/// anchoring the renderer declared rather than against a hardcoded guess, and
/// that a typed string becomes a line only when it really is one.
final class ReaderLineJumpTests: XCTestCase {

    // MARK: - What a typed string means

    func testAPlainNumberIsALine() {
        XCTAssertEqual(LineJumpPresenter.line(from: "42"), 42)
    }

    func testSurroundingSpaceIsIgnored() {
        XCTAssertEqual(LineJumpPresenter.line(from: "  7 "), 7)
    }

    /// Rejected rather than clamped to one. Lines are one-based everywhere they
    /// are shown, so a zero is a misunderstanding rather than a request, and
    /// moving the reader would teach the wrong thing about the number.
    func testZeroIsNotALine() {
        XCTAssertNil(LineJumpPresenter.line(from: "0"))
    }

    func testNegativeIsNotALine() {
        XCTAssertNil(LineJumpPresenter.line(from: "-3"))
    }

    func testEmptyIsNotALine() {
        XCTAssertNil(LineJumpPresenter.line(from: ""))
        XCTAssertNil(LineJumpPresenter.line(from: "   "))
    }

    func testSomethingThatIsNotANumberIsNotALine() {
        for text in ["abc", "12a", "1.5", "1 2", "٤٢"] {
            XCTAssertNil(
                LineJumpPresenter.line(from: text),
                "\"\(text)\" was accepted as a line number"
            )
        }
    }

    // MARK: - Which readers can be jumped in

    func testAReaderThatNumbersItsLinesCanBeJumpedIn() {
        XCTAssertTrue(ReaderLineJump.supports(SourceRenderer.anchoring))
    }

    func testAnAnchoringWithNoSelectorCannotBe() {
        let anchoring = ReaderAnchoring(
            anchorType: "whole",
            blockSelector: "",
            lineAttr: "data-line",
            endLineAttr: nil,
            refPrefix: "Line",
            accepting: []
        )
        XCTAssertFalse(ReaderLineJump.supports(anchoring))
    }

    // MARK: - The script

    /// Built from the anchoring rather than from a literal, so a renderer that
    /// changes how it marks lines does not leave a jump script quietly looking
    /// for markup nobody emits any more.
    func testTheScriptAsksForTheMarkupTheRendererDeclared() {
        let js = ReaderLineJump.javaScript(
            line: 12, anchoring: SourceRenderer.anchoring
        )
        XCTAssertTrue(
            js.contains(SourceRenderer.anchoring.blockSelector),
            "the script does not use the selector the renderer declared"
        )
        XCTAssertTrue(js.contains(SourceRenderer.anchoring.lineAttr))
        XCTAssertTrue(js.contains("var wanted = 12;"))
    }

    func testTheScriptScrollsTheDocumentRatherThanAContainer() {
        let js = ReaderLineJump.javaScript(
            line: 1, anchoring: SourceRenderer.anchoring
        )
        // A reader's body is the scrolling element. The scrollback's own version
        // sets `container.scrollTop`, and using that shape here would silently
        // do nothing — which is why the two are not shared.
        XCTAssertTrue(js.contains("window.scrollTo"))
        XCTAssertFalse(js.contains("scrollTop ="))
    }

    // MARK: - Arriving marked

    /// Nothing selected, and that is the point. A selection over the target is
    /// the one marker that fights the reason for going there: selection grey
    /// over a dimmed comment leaves the line unreadable. The row highlight the
    /// toolbar brings is the marker instead.
    func testTheScriptLeavesNothingSelected() {
        let js = ReaderLineJump.javaScript(
            line: 5, anchoring: SourceRenderer.anchoring
        )
        XCTAssertTrue(
            js.contains("removeAllRanges"),
            "a selection left over from before would still be copyable"
        )
        XCTAssertFalse(
            js.contains("addRange"),
            "the line is being selected, which is what made it illegible"
        )
        XCTAssertFalse(js.contains("selectNodeContents"))
    }

    func testTheScriptRaisesTheToolbarThroughTheSharedEntryPoint() {
        let js = ReaderLineJump.javaScript(
            line: 5, anchoring: SourceRenderer.anchoring
        )
        // The same call the drag path makes, so both ways of arriving at a line
        // end in one state rather than two that merely look alike.
        XCTAssertTrue(js.contains("AnnotationManager.showSelectionToolbar"))
        XCTAssertTrue(
            js.contains("typeof AnnotationManager !== 'undefined'"),
            "a reader with no annotation layer would throw rather than scroll"
        )
    }

    /// The toolbar inserts a spacer, so measuring before it opens reads a
    /// geometry that is about to change and scrolls to where the line was.
    func testTheScriptMeasuresAfterTheToolbarHasBeenLaidOut() {
        let js = ReaderLineJump.javaScript(
            line: 5, anchoring: SourceRenderer.anchoring
        )
        XCTAssertTrue(js.contains("requestAnimationFrame"))
        let toolbar = try? XCTUnwrap(js.range(of: "showSelectionToolbar"))
        let frame = try? XCTUnwrap(js.range(of: "requestAnimationFrame"))
        guard let toolbar, let frame else { return XCTFail("markers absent") }
        XCTAssertTrue(
            toolbar.lowerBound < frame.lowerBound,
            "the scroll is measured before the toolbar moves the page"
        )
    }

    /// The reason the target does not rest at the top, asserted so the two
    /// halves of that decision cannot drift apart: the offset is only defensible
    /// while the line arrives marked.
    func testTheTargetRestsBelowTheTopOfTheViewport() {
        XCTAssertGreaterThan(ReaderLineJump.restPosition, 0)
        XCTAssertLessThan(ReaderLineJump.restPosition, 0.5)
        let js = ReaderLineJump.javaScript(
            line: 5, anchoring: SourceRenderer.anchoring
        )
        XCTAssertTrue(js.contains("window.innerHeight * 0.3"))
    }

    /// A line past the end lands on the last one. The number came from
    /// somewhere — a stack trace against a file since edited — and the end of
    /// the file is the honest answer to "as far as that".
    func testTheScriptFallsBackToTheLastLineRatherThanRefusing() {
        let js = ReaderLineJump.javaScript(
            line: 9_999, anchoring: SourceRenderer.anchoring
        )
        XCTAssertTrue(js.contains("wanted > lastNumber"))
    }

    func testTheScriptReportsWhereItLanded() {
        let js = ReaderLineJump.javaScript(
            line: 3, anchoring: SourceRenderer.anchoring
        )
        // A caller with no answer cannot tell a miss from a hit, and a number
        // past the end is the ordinary mistake.
        XCTAssertTrue(js.contains("return -1;"))
        XCTAssertTrue(js.contains("return parseInt("))
    }

    /// The one thing a jump needs from the markup, asserted against the renderer
    /// that produces it — so a change to either side fails here rather than in a
    /// reader that scrolls nowhere.
    func testSourceMarkupCarriesTheAttributeTheJumpLooksFor() {
        let document = SourceRenderer.document(
            content: "one\ntwo\nthree", language: nil, isDark: false
        )
        XCTAssertTrue(document.contains("data-line=\"1\""))
        XCTAssertTrue(document.contains("data-line=\"3\""))
        XCTAssertTrue(
            document.contains("class=\"code-line\""),
            "the selector the jump script uses is not in the markup"
        )
    }
}
