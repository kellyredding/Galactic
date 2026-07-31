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

    /// The note form asks the shared builder for its composer.
    ///
    /// Deliberately not an end-to-end check, because there is no end to reach
    /// from here: the textarea is constructed at runtime inside the page, so it
    /// never appears in the rendered document. What the document carries is the
    /// manager's source, and this asserts the form delegates rather than
    /// spelling the attributes out again — which is the drift the shared
    /// builder exists to prevent. The markup itself is covered where it is
    /// produced.
    func testTheNoteFormAsksTheSharedBuilderForItsComposer() {
        let html = render()
        XCTAssertTrue(
            html.contains("composerTextareaHTML("),
            "the note form no longer asks the shared builder for its textarea"
        )
        XCTAssertTrue(
            html.contains("'note-textarea'"),
            "the composer class name is missing from the builder call"
        )
    }

    /// This surface prompts for a note, not an annotation.
    ///
    /// It asked for an annotation for a long time — the wording was copied
    /// across from the reader surface and nothing pointed at it, because the
    /// two composers are otherwise identical and neither app's tests looked at
    /// the prompt. Worth pinning now that the builder is shared, since a
    /// future caller reaching for the nearest example would copy it again.
    func testTheNoteFormPromptsForANoteRatherThanAnAnnotation() {
        let html = render()
        XCTAssertTrue(
            html.contains("Add note"),
            "the note composer should prompt for a note"
        )
        XCTAssertFalse(
            html.contains("Add annotation"),
            "the note composer is prompting for an annotation again"
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
