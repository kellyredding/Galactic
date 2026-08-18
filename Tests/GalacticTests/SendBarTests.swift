import XCTest
@testable import Galactic

/// The send bar, on both surfaces that draw it.
///
/// The bar is markup, CSS, and a script module that have to arrive together in
/// a page nothing downstream inspects. A missing half surfaces as a strip that
/// never appears, or one that appears and does nothing, with no build error and
/// no log line — the same failure mode the annotation layer already has a test
/// for, and for the same reason.
///
/// These pin the seams rather than the styling: that the two surfaces draw the
/// same bar from the same source, that a document which should not have one
/// does not get one, and that the chord is defined once.
final class SendBarTests: XCTestCase {

    /// Two lines of plain text, enough to render a scrollback page.
    private final class StubSnapshot: ScrollbackSnapshot {
        let cols: Int = 8
        let yDisp: Int = 0
        let lineCount: Int = 1

        func enumerateCells(
            line lineIndex: Int,
            visit: (ScrollbackCell) -> Void
        ) {
            for character in "hello" {
                visit(
                    ScrollbackCell(
                        character: String(character),
                        columnWidth: 1,
                        style: ScrollbackCellStyle(
                            foreground: .defaultColor,
                            background: .defaultColor,
                            attributes: []
                        )
                    )
                )
            }
        }
    }

    private func scrollbackHTML() -> String {
        ScrollbackHTMLRenderer.render(
            snapshot: StubSnapshot(),
            theme: TerminalColorTheme.theme(named: "galaxy-default"),
            fontFamily: "SF Mono",
            fontSize: 13,
            cellHeight: 17,
            textEntry: nil
        )
    }

    private func readerHTML(
        cardScripts: ReaderDocument.CardScripts = .full
    ) -> String {
        ReaderDocument.render(
            theme: ReaderTheme.standard(isDark: true),
            body: "<p>hello</p>",
            cardScripts: cardScripts
        )
    }

    /// The parts that have to travel together, on both surfaces.
    private let required = [
        "class=\"send-bar\"",
        "id=\"send-bar-button\"",
        "Send to Claude",
        "window.GalaxySendBar",
        "--send-bar-bg",
        ".send-bar-button[data-disabled-reason]",
    ]

    func testTheScrollbackDrawsTheBar() {
        let html = scrollbackHTML()
        for part in required {
            XCTAssertTrue(
                html.contains(part),
                "the scrollback page is missing \(part)"
            )
        }
    }

    func testAReaderDrawsTheSameBar() {
        let html = readerHTML()
        for part in required {
            XCTAssertTrue(
                html.contains(part),
                "a reader page is missing \(part)"
            )
        }
    }

    /// The colours are a token, not a literal repeated per surface.
    ///
    /// The green was inline `rgba()` inside the scrollback's own CSS for as
    /// long as it was the only bar. A second copy appearing anywhere is the
    /// drift this extraction exists to prevent.
    func testTheGreenIsDeclaredOnce() {
        for html in [scrollbackHTML(), readerHTML()] {
            XCTAssertEqual(
                html.components(
                    separatedBy: "rgba(40, 170, 80, 0.95)"
                ).count - 1,
                1,
                "the bar's dark-mode green appears more than once"
            )
        }
    }

    /// A document with no annotation machinery has nothing to send.
    func testADocumentWithoutCardsHasNoBar() {
        let html = readerHTML(cardScripts: .none)
        XCTAssertFalse(
            html.contains("class=\"send-bar\""),
            "a document with no card scripts still got a send bar"
        )
        XCTAssertFalse(
            html.contains("window.GalaxySendBar"),
            "a document with no card scripts still got the bar's module"
        )
    }

    /// The chord's glyphs and its predicate live in one place.
    ///
    /// They used to be a string typed into the button's label and a modifier
    /// test a thousand lines away, with nothing deriving one from the other.
    func testTheChordIsDefinedOnce() {
        XCTAssertTrue(
            sendBarJS.contains("CHORD_GLYPHS"),
            "the chord's glyphs are not named in the shared module"
        )
        XCTAssertTrue(
            sendBarJS.contains("matchesChord"),
            "the chord's predicate is not in the shared module"
        )
        XCTAssertTrue(
            ScrollbackHTMLRenderer.scrollbackManagerJS
                .contains("GalaxySendBar.matchesChord"),
            "the scrollback tests the chord itself instead of asking"
        )
        XCTAssertTrue(
            annotationManagerJS.contains("GalaxySendBar.matchesChord"),
            "a reader tests the chord itself instead of asking"
        )
    }

    // MARK: - Opting in

    private func initJS(
        noun: String?, count: Int, comment: Bool = false
    ) -> String {
        buildAnnotationInitJS(
            anchorType: "line_range",
            blockSelector: ".line",
            lineAttr: "data-line",
            refPrefix: "Artifact",
            itemLabel: "Artifact #1",
            annotationDicts: [],
            htmlMap: [:],
            sendBarNoun: noun,
            sendBarCount: count,
            sendBarComment: comment
        )
    }

    /// A host that says nothing about the bar gets nothing about the bar, so a
    /// reader with no review workflow behind it is unaffected by its presence
    /// in the shared substrate.
    func testOmittingTheNounEmitsNothing() {
        let js = initJS(noun: nil, count: 3)
        XCTAssertFalse(
            js.contains("GalaxySendBar"),
            "the bar was configured by a host that never asked for it"
        )
    }

    func testTheNounAndCountReachThePage() {
        let js = initJS(noun: "pending annotation", count: 3)
        XCTAssertTrue(
            js.contains("noun: 'pending annotation'"),
            "the host's noun did not reach the page"
        )
        XCTAssertTrue(
            js.contains("GalaxySendBar.update(3)"),
            "the host's count did not reach the page"
        )
        XCTAssertTrue(
            js.contains("AnnotationManager.requestReview(comment)"),
            "pressing the bar would not report anything"
        )
    }

    /// The overall comment is opt-in for the same reason the noun is: the two
    /// surfaces showing this bar are not both in a position to want it, and one
    /// of them is in another app.
    func testTheCommentStepIsOptIn() {
        XCTAssertTrue(
            initJS(noun: "pending annotation", count: 1, comment: true)
                .contains("comment: true"),
            "a host that asked for the comment did not get it"
        )
        XCTAssertTrue(
            initJS(noun: "pending annotation", count: 1)
                .contains("comment: false"),
            "a host that said nothing was opted in anyway"
        )
    }

    /// Escape on a reader is answered by the host asking the page what it was
    /// about, so a composer the host has never heard of has to be reported —
    /// otherwise the key closes the reader out from under it.
    func testAnOpenCommentClaimsEscapeFromTheReader() {
        XCTAssertTrue(
            annotationManagerJS.contains("GalaxySendBar.expanded"),
            "the escape context does not consider the overall comment"
        )
    }

    // MARK: - Surviving a rebuild
    //
    // Both surfaces throw their whole document away and build a new one on a
    // theme or font change. Nothing about the comment has a source of truth
    // outside the page, so each surface's rescue has to name it or the text is
    // gone on a gesture that had nothing to do with it. These are drift
    // detectors: they fail if a rescue stops carrying it.

    func testTheReaderRescueCarriesTheComment() {
        XCTAssertTrue(
            annotationManagerJS.contains("overallComment"),
            "a reader rebuild would drop the overall comment"
        )
        XCTAssertTrue(
            annotationManagerJS.contains("buildComment"),
            "the rescued comment is never put back on the page"
        )
    }

    func testTheScrollbackRescueCarriesTheComment() {
        let manager = ScrollbackHTMLRenderer.scrollbackManagerJS
        XCTAssertTrue(
            manager.contains("getFormState"),
            "the scrollback has nothing to rescue a composer with"
        )
        XCTAssertTrue(
            manager.contains("GalaxySendBar.commentText()"),
            "a scrollback rebuild would drop the overall comment"
        )
    }

    /// The same rebuild used to take a half-written *note* too, silently,
    /// while every other way of losing that text asks first.
    func testTheScrollbackRescueCarriesAHalfWrittenNote() {
        let manager = ScrollbackHTMLRenderer.scrollbackManagerJS
        XCTAssertTrue(
            manager.contains("showSelectionToolbar"),
            "a rescued note form has no way back to its line range"
        )
        XCTAssertTrue(
            manager.contains("startEdit"),
            "an edit in progress is not re-entered after a rebuild"
        )
    }

    /// A comment can outlive the notes it was meant to lead, and the exit that
    /// follows must not take it without asking.
    func testAWrittenCommentCountsAsUnsavedWork() {
        XCTAssertTrue(
            ScrollbackHTMLRenderer.noteManagerJS
                .contains("GalaxySendBar.commentText()"),
            "exiting the scrollback would discard a written comment silently"
        )
    }

    /// Nouns are host constants rather than user text, but the bar's label is
    /// built by interpolating one into a single-quoted literal, and an
    /// unescaped quote there is a syntax error in a page that looks fine until
    /// the bar is pressed.
    func testAQuoteInTheNounCannotBreakThePage() {
        let js = initJS(noun: "author's note", count: 1)
        XCTAssertTrue(
            js.contains("author\\'s note"),
            "an apostrophe in the noun was not escaped"
        )
        XCTAssertNil(
            JavaScriptSyntax.check(js, label: "init JS"),
            "a quote in the noun produced unparseable JavaScript"
        )
    }

    // MARK: - The green

    /// The bar's green and the tab badge's green are the same colour because
    /// they are the same value, not because two declarations agree. This is the
    /// test that fails if one is edited alone.
    func testTheCSSTokenIsBuiltFromTheSameComponentsAsTheColour() {
        for isLight in [true, false] {
            let c = SendBarGreen.components(isLight: isLight)
            let color = SendBarGreen.color(isLight: isLight)
            let css = SendBarGreen.css(isLight: isLight)

            XCTAssertEqual(Double(color.redComponent), c.red, accuracy: 0.001)
            XCTAssertEqual(
                Double(color.greenComponent), c.green, accuracy: 0.001
            )
            XCTAssertEqual(Double(color.blueComponent), c.blue, accuracy: 0.001)
            XCTAssertEqual(
                Double(color.alphaComponent), c.alpha, accuracy: 0.001
            )
            XCTAssertEqual(
                css,
                "rgba(\(Int((c.red * 255).rounded())), "
                    + "\(Int((c.green * 255).rounded())), "
                    + "\(Int((c.blue * 255).rounded())), \(c.alpha))"
            )
        }
    }

    /// Light and dark are different colours rather than one at two opacities —
    /// the light bar sits on white and needs the darker, more saturated green.
    func testLightAndDarkAreDifferentGreens() {
        XCTAssertNotEqual(
            SendBarGreen.css(isLight: true), SendBarGreen.css(isLight: false)
        )
    }

    /// The stylesheet must carry the shared token rather than a literal, or the
    /// badge and the bar can drift while both still look right in isolation.
    func testTheBarsBackgroundTokenUsesTheSharedGreen() {
        for isLight in [true, false] {
            let tokens = sendBarTokens(isLight: isLight)
            XCTAssertTrue(
                tokens.contains(
                    "--send-bar-bg: \(SendBarGreen.css(isLight: isLight))"
                ),
                "the bar stopped deriving its own green"
            )
        }
    }
}
