import XCTest
@testable import Galactic

/// The scrollback document, assembled.
///
/// The renderer's whole job is to splice a frozen buffer together with the
/// shared card modules and a theme into one self-contained page. Nothing
/// downstream can tell it apart from a page that is missing a script tag —
/// a dropped module surfaces as a dead button inside a WebView, with no
/// build error and no log line.
///
/// These assert the seams rather than the markup: that each module the page
/// depends on is present, that host-supplied values reach the output, and
/// that the two managers are still there after moving into this package.
final class ScrollbackRendererTests: XCTestCase {

    /// Two lines of plain text, enough to exercise the line loop.
    private final class StubSnapshot: ScrollbackSnapshot {
        let cols: Int = 8
        let yDisp: Int = 0
        let lineCount: Int = 2
        private let lines = ["hello", "world"]

        func enumerateCells(
            line lineIndex: Int,
            visit: (ScrollbackCell) -> Void
        ) {
            for character in lines[lineIndex] {
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

    private func render(
        textEntry: [String: [[String: Any]]]? = nil
    ) -> String {
        ScrollbackHTMLRenderer.render(
            snapshot: StubSnapshot(),
            theme: TerminalColorTheme.theme(named: "galaxy-default"),
            fontFamily: "SF Mono",
            fontSize: 13,
            cellHeight: 17,
            textEntry: textEntry
        )
    }

    func testBufferContentReachesTheDocument() {
        let html = render()
        XCTAssertTrue(
            html.contains("hello"),
            "the first buffer line is missing from the rendered page"
        )
        XCTAssertTrue(
            html.contains("world"),
            "the second buffer line is missing from the rendered page"
        )
    }

    /// Every shared module the page's behavior depends on.
    ///
    /// Order matters at runtime — a manager that runs before the substrate it
    /// calls into fails at first use, not at load — but presence is what a
    /// move can silently break, so that is what this pins.
    func testEverySharedModuleIsPresent() {
        let html = render()
        let required = [
            "window.GalaxyCardText",
            "window.GalaxyClipboard",
            "window.GalaxySuggestion",
            "window.GalaxyAddNote",
            "window.GalaxyTextEntry",
            "EmojiAutocomplete",
        ]
        for namespace in required {
            XCTAssertTrue(
                html.contains(namespace),
                "\(namespace) is not in the rendered page — a script tag was lost"
            )
        }
    }

    func testBothManagersAreSpliced() {
        let html = render()
        XCTAssertTrue(
            html.contains("ScrollbackManager"),
            "the scrollback manager is missing from the rendered page"
        )
        XCTAssertTrue(
            html.contains("noteCreated"),
            "the note manager is missing from the rendered page"
        )
    }

    /// Host-supplied values have to survive the trip into the document, or the
    /// page silently falls back to its own defaults.
    func testThemeAndMetricsReachTheStylesheet() {
        let theme = TerminalColorTheme.theme(named: "galaxy-default")
        let html = render()
        XCTAssertTrue(
            html.contains("--fg: \(theme.foreground)"),
            "the theme foreground did not reach the stylesheet"
        )
        XCTAssertTrue(
            html.contains("--font-size: 13.0px")
                || html.contains("--font-size: 13px"),
            "the font size did not reach the stylesheet"
        )
        XCTAssertTrue(
            html.contains("--line-height: 17.0px")
                || html.contains("--line-height: 17px"),
            "the cell height did not reach the stylesheet"
        )
    }

    /// Omitting the bindings must leave the configure call out entirely rather
    /// than emit one with an empty payload — the JS defaults are the intended
    /// behavior for a caller that has nothing to say.
    func testTextEntryConfigureIsOmittedWhenNoBindingsAreSupplied() {
        XCTAssertFalse(
            render().contains("GalaxyTextEntry.configure("),
            "a configure call was emitted for a caller that supplied nothing"
        )
    }

    func testTextEntryConfigureIsEmittedWhenBindingsAreSupplied() {
        let html = render(textEntry: TextEntryBindings.default.jsPayload)
        XCTAssertTrue(
            html.contains("GalaxyTextEntry.configure("),
            "supplied bindings never reached the page"
        )
    }

    /// The page had a `updateTheme` receiver that no host ever called, paired
    /// with a Swift method that no host ever called either. Both were dropped
    /// on the way into this package rather than published as surface nobody
    /// asked for. This fails if either comes back without a caller.
    func testTheUncalledThemeReceiverIsGone() {
        XCTAssertFalse(
            render().contains("updateTheme"),
            "the unused updateTheme receiver is back in the page"
        )
    }
}
