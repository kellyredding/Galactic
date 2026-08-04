import WebKit
import XCTest

@testable import Galactic

/// The find matcher, exercised against a real page.
///
/// Everything else about this module is checked by parsing it — `GalaxyFind` is
/// a string literal as far as the compiler is concerned, so a mistake inside it
/// survives every build and shows up as search quietly finding less than it
/// should. This runs it.
///
/// Fixtures stay small on purpose. `chunkApply` runs its first chunk
/// synchronously and only defers to `requestAnimationFrame` when there is more
/// work than `CHUNK_SIZE`, so a fixture under that many matching text nodes has
/// finished searching by the time `setQuery` returns — which is what lets these
/// assertions be ordinary reads instead of waits.
@MainActor
final class GalaxyFindBehaviorTests: XCTestCase {

    // MARK: - Harness

    /// A loaded page with the find script installed, driven the way
    /// `WebViewFindController` drives it.
    private final class Page: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private var loaded: CheckedContinuation<Void, Never>?

        init(body: String) {
            let config = WKWebViewConfiguration()
            config.installGalaxyFindUserScript()
            webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                configuration: config
            )
            super.init()
            webView.navigationDelegate = self
            webView.loadHTMLString(
                "<html><body>\(body)</body></html>", baseURL: nil
            )
        }

        func waitForLoad() async {
            await withCheckedContinuation { c in
                loaded = c
            }
        }

        func webView(
            _ webView: WKWebView, didFinish navigation: WKNavigation!
        ) {
            loaded?.resume()
            loaded = nil
        }

        /// Run the search the way Swift does, then read what it highlighted.
        ///
        /// The query goes through `FindQuery.normalized` and
        /// `JavaScriptLiteral.string` because those are the two things standing
        /// between the field and the page — a test that skipped them would be
        /// checking a call nothing makes.
        func search(_ typed: String, reverse: Bool = false) async throws
            -> [String]
        {
            let opts = reverse ? "{reverse:true}" : "{}"
            let search = FindQuery.normalized(typed)
            _ = try await webView.evaluateJavaScript(
                "GalaxyFind.setQuery("
                    + "\(JavaScriptLiteral.string(search)), \(opts))"
            )
            return try await highlights()
        }

        /// The text of every highlight, in document order. Stronger than a
        /// count: a match split across two style runs shows up here as the two
        /// pieces it really is, which a number would hide.
        func highlights() async throws -> [String] {
            try await marks(withClass: "galaxy-find-match")
        }

        /// The pieces of the match the bar is currently sitting on.
        func current() async throws -> [String] {
            try await marks(withClass: "galaxy-find-current")
        }

        private func marks(withClass name: String) async throws -> [String] {
            let result = try await webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('mark.\(name)'))"
                    + ".map(function(m) { return m.textContent; })"
            )
            return result as? [String] ?? []
        }

        func next() async throws {
            _ = try await webView.evaluateJavaScript("GalaxyFind.next()")
        }
    }

    private func page(body: String) async -> Page {
        let p = Page(body: body)
        await p.waitForLoad()
        return p
    }

    /// One scrollback line as `ScrollbackHTMLRenderer` emits it: a `div.tl`
    /// holding one absolutely-positioned span per contiguous style run.
    ///
    /// The shape is the whole point. Each run is a separate text node, so a
    /// phrase crossing a colour or bold change crosses a node boundary — which
    /// is invisible on screen and decisive to a matcher.
    private func line(_ runs: [String]) -> String {
        var col = 0
        var spans = ""
        for run in runs {
            spans +=
                "<span style=\"position:absolute;left:\(col)ch;"
                + "width:\(run.count)ch;overflow:hidden;\">\(run)</span>"
            col += run.count
        }
        return "<div class=\"tl\">\(spans)</div>"
    }

    /// A blank line, which the renderer spells with a non-breaking space.
    private var blankLine: String { "<div class=\"tl\">&nbsp;</div>" }

    // MARK: - The harness itself

    /// Proves the page runs and the script is installed before any assertion
    /// about matching means anything. Without this, a broken harness and a
    /// broken matcher look identical.
    func testTheScriptIsInstalledAndThePageRuns() async throws {
        let p = await page(body: "<p>hello</p>")

        let typeOfModule = try await p.webView.evaluateJavaScript(
            "typeof window.GalaxyFind"
        )

        XCTAssertEqual(typeOfModule as? String, "object")
    }

    func testAPlainMatchIsHighlighted() async throws {
        let p = await page(body: "<p>one stage two</p>")

        let hits = try await p.search("stage")

        XCTAssertEqual(hits, ["stage"])
    }

    // MARK: - Matching across style runs

    /// The reported bug's real cause. `Stage` and the space after it sit in
    /// different style runs, so they are different text nodes, and a phrase
    /// spanning them was unfindable — while the identical phrase in unstyled
    /// text a line below matched fine. Nothing on screen distinguishes the two.
    func testAPhraseIsFoundAcrossAStyleRun() async throws {
        let p = await page(
            body: line(["Stage", " 1 — kill the buffer"])
        )

        let hits = try await p.search("stage 1")

        XCTAssertEqual(
            hits, ["Stage", " 1"],
            "one match, highlighted as the two runs it actually spans"
        )
    }

    /// The same phrase inside a single run, which always worked. Here to keep
    /// the fix from being mistaken for the cause: the run boundary is what
    /// broke, not the space.
    func testAPhraseWithinOneRunStillMatches() async throws {
        let p = await page(
            body: line(["imagination. Stage 2 is deferrable"])
        )

        let hits = try await p.search("stage 2")

        XCTAssertEqual(hits, ["Stage 2"])
    }

    /// A phrase reaching a styled occurrence and a plain one in the same query.
    /// Before the fix only the plain one answered, which is exactly what "most
    /// of the matches disappear" looked like from the outside.
    func testOnePhraseReachesStyledAndPlainOccurrencesAlike() async throws {
        let p = await page(
            body: line(["Stage", " 1 — kill the buffer"])
                + line(["deferring stage 1 again"])
        )

        let hits = try await p.search("stage 1")

        XCTAssertEqual(hits, ["Stage", " 1", "stage 1"])
    }

    /// The reported symptom end to end, through the page rather than the rule:
    /// a trailing space finds what the same query without one finds. This is
    /// the assertion the screenshots were of.
    func testATrailingSpaceLosesNoMatches() async throws {
        let body =
            line(["Stage", " 1 — kill the buffer"])
            + line(["imagination. Stage 2 is deferrable"])
        let p = await page(body: body)

        let withSpace = try await p.search("stage ")
        let without = try await p.search("stage")

        XCTAssertEqual(withSpace, without)
        XCTAssertEqual(withSpace, ["Stage", "Stage"])
    }

    /// Inline formatting in prose is the same boundary by another name, so the
    /// readers get this fix too — every artifact, snapshot and transcript.
    func testAPhraseIsFoundAcrossInlineFormattingInProse() async throws {
        let p = await page(
            body: "<p>read the <strong>bold</strong> word</p>"
        )

        let hits = try await p.search("the bold")

        XCTAssertEqual(hits, ["the ", "bold"])
    }

    // MARK: - Where matching must stop

    /// A line break is a break. Flattening the whole document would join the
    /// end of one line to the start of the next and invent phrases that are
    /// nowhere on screen — and because terminal lines are padded to the full
    /// width, the join would usually land in blank space where a match is
    /// least explicable.
    func testAPhraseIsNotFoundAcrossALineBreak() async throws {
        let p = await page(
            body: line(["alpha end"]) + line([" start beta"])
        )

        let hits = try await p.search("end start")

        XCTAssertEqual(hits, [], "no phrase spans two lines")
    }

    /// The padding landmine. Searched literally, a lone space matches the blank
    /// cells of every line in the buffer — thousands of wrapped nodes to say
    /// nothing. It normalizes to no query at all instead.
    func testWhitespaceAloneHighlightsNothing() async throws {
        let p = await page(
            body: line(["alpha beta"]) + blankLine + line(["gamma delta"])
        )

        let hits = try await p.search("   ")

        XCTAssertEqual(hits, [])
    }

    // MARK: - Properties that must survive the rework

    func testMatchingIgnoresCase() async throws {
        let p = await page(body: line(["Stage", " 1"]))

        let hits = try await p.search("STAGE 1")

        XCTAssertEqual(hits, ["Stage", " 1"])
    }

    /// Every occurrence, not just the first, and in document order.
    func testEveryOccurrenceIsHighlightedInOrder() async throws {
        let p = await page(
            body: line(["one stage two stage three"])
                + line(["four stage five"])
        )

        let hits = try await p.search("stage")

        XCTAssertEqual(hits, ["stage", "stage", "stage"])
    }

    /// Re-querying replaces the previous highlights rather than accumulating
    /// them. `clear()` unwraps and normalizes, so a second search sees the
    /// original text nodes — the property the rework must not break, since it
    /// now has more marks per match to unwind.
    func testASecondSearchReplacesTheFirst() async throws {
        let p = await page(body: line(["Stage", " 1 and stage 2"]))

        _ = try await p.search("stage 1")
        let hits = try await p.search("stage 2")

        XCTAssertEqual(hits, ["stage 2"])
    }

    /// Clearing must restore the page, not leave it shredded into fragments.
    /// A cross-run match splits two nodes now, so this is the assertion that
    /// the unwind is complete.
    func testClosingRestoresTheText() async throws {
        let p = await page(body: line(["Stage", " 1 — kill the buffer"]))

        _ = try await p.search("stage 1")
        _ = try await p.webView.evaluateJavaScript("GalaxyFind.close()")

        let remaining = try await p.highlights()
        let text = try await p.webView.evaluateJavaScript(
            "document.body.innerText"
        )

        XCTAssertEqual(remaining, [])
        XCTAssertEqual(
            (text as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "Stage 1 — kill the buffer"
        )
    }

    func testAQueryMatchingNothingHighlightsNothing() async throws {
        let p = await page(body: line(["Stage", " 1"]))

        let hits = try await p.search("nonexistent")

        XCTAssertEqual(hits, [])
    }

    // MARK: - One match, however many marks it took

    /// A match split across style runs is drawn in pieces, and every piece has
    /// to know it is the current one. Marking only the first would leave half a
    /// highlight in the wrong colour, which reads as two separate matches.
    func testTheCurrentMatchHighlightsAllOfItsPieces() async throws {
        let p = await page(body: line(["Stage", " 1 — kill the buffer"]))

        _ = try await p.search("stage 1")
        let current = try await p.current()

        XCTAssertEqual(current, ["Stage", " 1"])
    }

    /// And it counts as one. Navigation steps over matches, not over the marks
    /// they happened to need — otherwise pressing next on a phrase that crossed
    /// a colour change would land you inside the match you were already on.
    /// And it counts as one. Navigation steps over matches, not over the marks
    /// they happened to need — otherwise pressing next on a phrase that crossed
    /// a colour change would land you inside the match you were already on.
    ///
    /// The two occurrences differ in case so the assertions can tell which one
    /// the bar is sitting on; matching folds case, so both are found.
    func testNavigationTreatsACrossRunMatchAsOne() async throws {
        let p = await page(
            body: line(["Stage", " 1 first"]) + line(["STAGE", " 1 second"])
        )

        _ = try await p.search("stage 1")
        let firstStop = try await p.current()
        try await p.next()
        let secondStop = try await p.current()

        XCTAssertEqual(
            firstStop, ["Stage", " 1"],
            "both pieces of the first match, and only that match"
        )
        XCTAssertEqual(
            secondStop, ["STAGE", " 1"],
            "one press moved a whole match, not one mark"
        )
    }
}
