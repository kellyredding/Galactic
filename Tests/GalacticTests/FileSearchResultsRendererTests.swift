import XCTest

@testable import Galactic

/// What the results page emits.
///
/// Substring assertions against the HTML, following `MarkdownHTMLVisitorTests`
/// — which names itself the place emitter behaviour goes from here. The one
/// thing in this file that would otherwise fail silently is the highlight class
/// name, so it is asserted from both directions.
final class FileSearchResultsRendererTests: XCTestCase {

    private func line(
        _ number: Int, _ segments: [(String, Bool)]
    ) -> FileSearchLine {
        FileSearchLine(
            line: number,
            segments: segments.map { .init(text: $0.0, isMatch: $0.1) }
        )
    }

    private func run(
        query: String = "needle",
        caseSensitive: Bool = false,
        files: [FileSearchFileResult] = [],
        considered: Int = 10,
        scanned: Int = 10,
        matches: Int = 0,
        truncation: FileSearchRun.Truncation? = nil,
        skipped: [String] = [],
        indexed: Bool = true
    ) -> FileSearchRun {
        FileSearchRun(
            query: FileSearchQuery(
                text: query, isCaseSensitive: caseSensitive, contextLines: 2
            ),
            root: "/root",
            files: files,
            filesConsidered: considered,
            filesScanned: scanned,
            matchCount: matches,
            truncation: truncation,
            skippedNames: skipped,
            wasRootIndexed: indexed
        )
    }

    private func oneFile(
        path: String = "/root/a.swift",
        relative: String = "a.swift",
        matchCount: Int = 1,
        truncated: Bool = false,
        blocks: [[FileSearchLine]]? = nil
    ) -> FileSearchFileResult {
        FileSearchFileResult(
            path: path,
            relativePath: relative,
            matchCount: matchCount,
            blocks: blocks
                ?? [[line(3, [("let ", false), ("needle", true), (" = 1", false)])]],
            wasTruncated: truncated
        )
    }

    private func html(
        _ r: FileSearchRun, isDark: Bool = true
    ) -> String {
        FileSearchResultsRenderer.document(run: r, isDark: isDark)
    }

    // MARK: - The header

    func testTheHeaderStatesTheCountTheQueryAndTheMode() {
        let out = html(run(query: "needle", considered: 51_971))

        XCTAssertTrue(out.contains("Searching 51,971 files"))
        XCTAssertTrue(out.contains("\"needle\""))
        XCTAssertTrue(out.contains("case insensitive"))
    }

    func testTheHeaderSaysCaseSensitiveWhenItWas() {
        let out = html(run(caseSensitive: true))
        XCTAssertTrue(out.contains("case sensitive"))
        XCTAssertFalse(out.contains("case insensitive"))
    }

    func testTheMatchCapIsStatedWithWhatWasRead() {
        let out = html(
            run(considered: 1_000, scanned: 300, truncation: .matchCap(2_000))
        )
        XCTAssertTrue(out.contains("Stopped at 2,000 matches"))
        XCTAssertTrue(out.contains("300 of 1,000 files were read"))
    }

    func testThePerFileCapIsStated() {
        let out = html(run(truncation: .fileCap(50)))
        XCTAssertTrue(out.contains("more than 50 matches"))
    }

    /// A reader whose `log/` has no matches would otherwise conclude the string
    /// is not there.
    func testTheHeaderNamesWhatWasNotSearched() {
        let out = html(run(skipped: ["log", "node_modules", "tmp"]))
        XCTAssertTrue(out.contains("Not searched: log, node_modules, tmp"))
    }

    func testNoMatchesIsSaidOutLoud() {
        XCTAssertTrue(html(run()).contains("No matches."))
    }

    func testAFileWithResultsDoesNotSayNoMatches() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertFalse(out.contains("No matches."))
    }

    /// "Not indexed" and "no matches" are different claims and the wrong one is
    /// a lie about the reader's project.
    func testAnUnindexedRootSaysSoInsteadOfClaimingNoMatches() {
        let out = html(run(indexed: false))
        XCTAssertTrue(out.contains("not indexed yet"))
        XCTAssertFalse(out.contains("No matches."))
        XCTAssertFalse(out.contains("Searching"))
    }

    func testTheQueryIsEscapedInTheHeader() {
        let out = html(run(query: "<script>x</script>"))
        XCTAssertFalse(out.contains("<script>x</script>"))
        XCTAssertTrue(out.contains("&lt;script&gt;"))
    }

    // MARK: - Highlighting

    func testAHitIsWrappedInTheSearchHitClass() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertTrue(out.contains("<mark class=\"search-hit\">needle</mark>"))
    }

    /// The trap: the find module's `clear()` unwraps every
    /// `mark.galaxy-find-match`, so borrowing that class name would make ⌘F
    /// strip the search highlighting the first time it was closed.
    func testHitsDoNotUseTheFindBarsClassName() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertFalse(
            out.contains("galaxy-find-match"),
            "Cmd+F's clear() would unwrap these"
        )
    }

    func testTheHighlightUsesTheFindBarsColour() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertTrue(
            out.contains("rgba(255, 220, 50, 0.45)"),
            "the same yellow as the find bar's match"
        )
    }

    func testFileContentIsEscaped() {
        let file = oneFile(
            blocks: [[line(1, [("if a < b && c > d", false)])]]
        )
        let out = html(run(files: [file], matches: 1))
        XCTAssertTrue(out.contains("a &lt; b &amp;&amp; c &gt; d"))
    }

    func testEscapingAppliesInsideAHitToo() {
        let file = oneFile(
            blocks: [[line(1, [("x", false), ("<b>", true)])]]
        )
        let out = html(run(files: [file], matches: 1))
        XCTAssertTrue(
            out.contains("<mark class=\"search-hit\">&lt;b&gt;</mark>")
        )
    }

    // MARK: - Lines and links

    func testAMatchingLineNumberIsALinkCarryingItsLine() throws {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertTrue(out.contains("class=\"result-line-num\""))

        let expected = try XCTUnwrap(
            SearchHitLink.url(path: "/root/a.swift", line: 3)
        )
        XCTAssertTrue(out.contains(HTMLEscape.text(expected.absoluteString)))
    }

    func testAMatchingLineNumberCarriesTheColon() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertTrue(out.contains("</a>:"))
    }

    func testAContextLineIsNeitherLinkedNorColoned() {
        let file = oneFile(
            blocks: [
                [
                    line(2, [("before", false)]),
                    line(3, [("needle", true)]),
                ]
            ]
        )
        let out = html(run(files: [file], matches: 1))

        XCTAssertTrue(out.contains("<td class=\"line-num\">2</td>"))
        XCTAssertTrue(out.contains("is-match"))
    }

    func testThePathIsALinkWithNoLine() throws {
        let out = html(run(files: [oneFile()], matches: 1))
        let expected = try XCTUnwrap(
            SearchHitLink.url(path: "/root/a.swift")
        )
        XCTAssertTrue(out.contains(HTMLEscape.text(expected.absoluteString)))
        XCTAssertTrue(out.contains("class=\"result-path\""))
    }

    func testThePathIsShownRelative() {
        let file = oneFile(
            path: "/root/deep/inner/a.swift", relative: "deep/inner/a.swift"
        )
        let out = html(run(files: [file], matches: 1))
        XCTAssertTrue(out.contains(">deep/inner/a.swift</a>"))
    }

    /// The paths that break naive escaping have to survive into a working href
    /// *and* be safe as HTML — two different escapings of the same string.
    func testAPathNeedingEscapingSurvivesIntoAWorkingHref() throws {
        let awkward = "/root/a b/100%/C#/café.md"
        let file = oneFile(path: awkward, relative: "a b/100%/C#/café.md")
        let out = html(run(files: [file], matches: 1))

        let expected = try XCTUnwrap(SearchHitLink.url(path: awkward))
        XCTAssertTrue(out.contains(HTMLEscape.text(expected.absoluteString)))
        let parsed = try XCTUnwrap(SearchHitLink.parse(expected))
        XCTAssertEqual(parsed.path, awkward)
    }

    func testTheMatchCountIsShownPerFile() {
        let out = html(run(files: [oneFile(matchCount: 12)], matches: 12))
        XCTAssertTrue(out.contains("12 matches"))
    }

    func testOneMatchIsSingular() {
        let out = html(run(files: [oneFile(matchCount: 1)], matches: 1))
        XCTAssertTrue(out.contains("1 match<"))
    }

    func testATruncatedFileIsMarked() {
        let out = html(
            run(files: [oneFile(matchCount: 50, truncated: true)], matches: 50)
        )
        XCTAssertTrue(out.contains("50 matches+"))
    }

    func testASecondBlockIsSeparatedByAGap() {
        let file = oneFile(
            blocks: [
                [line(3, [("needle", true)])],
                [line(90, [("needle", true)])],
            ]
        )
        let out = html(run(files: [file], matches: 2))
        XCTAssertTrue(out.contains("result-gap"))
    }

    func testASingleBlockHasNoGap() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertFalse(out.contains("result-gap\">"))
    }

    func testAnEmptyLineStillDrawsARow() {
        let file = oneFile(blocks: [[line(1, [])]])
        let out = html(run(files: [file], matches: 1))
        XCTAssertTrue(out.contains("&nbsp;"))
    }

    // MARK: - The page

    /// Clicking is a navigation, not a script.
    ///
    /// The page does carry the shared card scripts — it asks for
    /// `.withoutAddNote`, not `.none` — so it cannot be asserted that no
    /// JavaScript is present. What *can* be asserted is that nothing here
    /// depends on any: every clickable thing is an ordinary anchor with an
    /// href, and there is no hook for a handler to find. That is the claim the
    /// link route makes, and the reason no `// js-validate` marker or
    /// `ShippedJavaScriptTests` entry belongs to this file.
    func testEveryClickableThingIsAPlainAnchor() {
        let out = html(run(files: [oneFile()], matches: 1))

        XCTAssertTrue(
            out.contains("<a class=\"result-path\" href=\"galactic-open:")
        )
        XCTAssertTrue(
            out.contains("<a class=\"result-line-num\" href=\"galactic-open:")
        )
        XCTAssertFalse(
            out.contains("data-search"),
            "no attribute for a click handler to key off"
        )
        XCTAssertFalse(
            out.contains("onclick"),
            "and no inline handler either"
        )
    }

    func testTheLinkDragSuppressionIsPresent() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertTrue(out.contains("-webkit-user-drag: none"))
    }

    func testTheGutterIsSticky() {
        let out = html(run(files: [oneFile()], matches: 1))
        XCTAssertTrue(out.contains("position: sticky"))
    }

    func testBothAppearancesRender() {
        for isDark in [true, false] {
            let out = html(run(files: [oneFile()], matches: 1), isDark: isDark)
            XCTAssertTrue(out.contains("<!DOCTYPE html>"))
            XCTAssertTrue(out.contains("Find Results"))
        }
    }

    /// A results page has nothing to anchor a note to, and the jump machinery
    /// must agree — otherwise a line jump inside this page would try to find a
    /// numbered element and land somewhere arbitrary.
    func testTheResultsPageIsNotJumpable() {
        XCTAssertFalse(
            ReaderLineJump.supports(FileSearchResultsRenderer.anchoring)
        )
    }
}
