import Foundation
import Markdown
import XCTest
@testable import Galactic

/// First tests over the HTML emitter. It had none: 453 tests in this package
/// and not one asserted anything it produced, while its sibling emitter has a
/// file of its own. Autolinking is the occasion rather than the whole scope —
/// this file is where emitter behaviour goes from here.
///
/// Where an address ends is `MarkdownAutolink`'s question and its own tests
/// answer it. What these assert is that this emitter asks that question at all,
/// and that the markup it wraps the answer in survives escaping.
final class MarkdownHTMLVisitorTests: XCTestCase {

    // MARK: - Linking

    func testLinksABareURLInAParagraph() {
        XCTAssertEqual(
            anchors(in: "Ticket at https://example.com/1"),
            [Anchor("https://example.com/1", "https://example.com/1")]
        )
    }

    func testLinksHTTPAsWellAsHTTPS() {
        XCTAssertEqual(
            anchors(in: "http://localhost:3000/items"),
            [Anchor("http://localhost:3000/items",
                    "http://localhost:3000/items")]
        )
    }

    func testLinksEveryURLInOneParagraph() {
        XCTAssertEqual(
            anchors(in: "https://a.example and https://b.example"),
            [Anchor("https://a.example", "https://a.example"),
             Anchor("https://b.example", "https://b.example")]
        )
    }

    func testLinksInAHeadingAndInAListItem() {
        XCTAssertEqual(anchors(in: "# https://example.com").count, 1)
        XCTAssertEqual(anchors(in: "- go to https://example.com").count, 1)
    }

    // MARK: - Escaping, which is this emitter's half of the problem

    /// The attributed emitter never had to care about this: it hangs an
    /// attribute on a range. Here the address is spliced into markup, and an
    /// unescaped `&` in a query string malforms both the attribute and the
    /// text.
    func testEscapesAnAmpersandInTheHrefAndInTheLabel() {
        XCTAssertEqual(
            anchors(in: "See https://example.com/a?b=1&c=2 now"),
            [Anchor("https://example.com/a?b=1&amp;c=2",
                    "https://example.com/a?b=1&amp;c=2")]
        )
    }

    /// Escaping runs per piece, so the prose on either side of an anchor has
    /// to come out escaped too — the bug this shape exists to avoid is one
    /// escape over the whole string, which would eat the anchor's own markup.
    func testEscapesTheProseAroundAnAnchor() {
        let rendered = html("a < b & c, see https://example.com")
        XCTAssertTrue(rendered.contains("a &lt; b &amp; c,"),
                      "surrounding prose lost its escaping: \(rendered)")
        XCTAssertEqual(anchors(in: "a < b & c, see https://example.com").count, 1)
    }

    /// The href is what Foundation parsed; the label is the source slice. They
    /// legitimately differ — a non-ASCII path comes back percent-encoded — and
    /// the reader should show what the author typed while navigating to what
    /// it parses as.
    func testShowsTheSourceSliceAndLinksTheParsedURL() {
        XCTAssertEqual(
            anchors(in: "See https://example.com/ünicode here"),
            [Anchor("https://example.com/ünicode",
                    "https://example.com/%C3%BCnicode")]
        )
    }

    // MARK: - What must not link

    func testLeavesInlineCodeAlone() {
        let rendered = html("run `curl https://example.com`")
        XCTAssertEqual(anchors(in: "run `curl https://example.com`"), [])
        XCTAssertTrue(rendered.contains("<code>"),
                      "expected inline code to survive: \(rendered)")
    }

    func testLeavesAFencedBlockAlone() {
        let markdown = """
        ```
        curl https://example.com
        ```
        """
        XCTAssertEqual(anchors(in: markdown), [])
    }

    func testAnExplicitLinkKeepsItsAuthoredDestination() {
        XCTAssertEqual(
            anchors(in: "[the docs](https://example.com/docs)"),
            [Anchor("the docs", "https://example.com/docs")]
        )
    }

    func testASelfLabelledLinkStaysOneAnchor() {
        XCTAssertEqual(
            anchors(in: "[https://example.com/1](https://example.com/1)"),
            [Anchor("https://example.com/1", "https://example.com/1")]
        )
    }

    /// Emphasis nests between the text and the link, which is why the
    /// inside-a-link check walks ancestors instead of reading `parent`.
    func testAnEmphasisedURLLabelKeepsTheAuthoredDestination() {
        let found = anchors(in: "[**https://shown.example**](https://real.example)")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.href, "https://real.example")
        XCTAssertEqual(found.first?.label,
                       "<strong>https://shown.example</strong>")
    }

    /// The case where skipping a link's label actually decides the outcome.
    /// Everywhere else `visitLink` supplies the destination anyway; with an
    /// empty one there is nothing to supply, and a label that reads like a URL
    /// must not become a link to itself — the author said this goes nowhere.
    func testAnEmptyDestinationDoesNotBecomeASelfLink() {
        XCTAssertEqual(
            anchors(in: "[https://shown.example]()"),
            [Anchor("https://shown.example", "")]
        )
    }

    func testAnAngleBracketAutolinkEmitsExactlyOneAnchor() {
        XCTAssertEqual(
            anchors(in: "<https://example.com>"),
            [Anchor("https://example.com", "https://example.com")]
        )
    }

    // MARK: - Nothing else moved

    func testProseWithoutAURLIsUntouched() {
        let rendered = html("Plain **body** text")
        XCTAssertTrue(rendered.contains("<strong>body</strong>"))
        XCTAssertFalse(rendered.contains("<a "), "unexpected anchor: \(rendered)")
    }

    /// The annotation contract in one assertion. Anchors are source line
    /// numbers on the enclosing block, so an inline element added inside it
    /// must not move them — an annotation written before this change has to
    /// come back to the same block after it.
    func testLineAnchorsAreUnchangedWhenAParagraphGainsAnAnchor() {
        XCTAssertEqual(
            lineAnchors(in: html("Ticket at https://example.com/1")),
            lineAnchors(in: html("Ticket at nowhere in particular"))
        )
    }

    // MARK: - The stylesheet half of the same change

    /// Lives beside the emitter tests because it is the precondition for
    /// them, not a separate feature: linking bare URLs is only safe on an
    /// annotation surface while a drag beginning on a link cannot swallow the
    /// selection. Nothing validates embedded CSS — the JavaScript gate does
    /// not read stylesheets — so a deletion here would show up as passages
    /// that silently refuse to be annotated, and nowhere else.
    ///
    /// Presence is what gets asserted, the same judgement `ReaderAssetsTests`
    /// makes: a typo in the property name still needs looking at the page.
    func testTheStylesheetSuppressesTheLinkDrag() {
        for isDark in [true, false] {
            let page = MarkdownRenderer.document(
                markdown: "See https://example.com", isDark: isDark
            )
            XCTAssertTrue(
                page.contains("-webkit-user-drag: none"),
                "the drag suppression that makes autolinking safe is missing"
            )
        }
    }

    // MARK: - Helpers

    private func html(_ markdown: String) -> String {
        var visitor = MarkdownHTMLVisitor()
        return visitor.visit(MarkdownDocument.parse(markdown))
    }

    /// An emitted anchor, held in its escaped form: the escaping is half of
    /// what these tests are checking, so unescaping here would hide it.
    private struct Anchor: Equatable, CustomStringConvertible {
        let label: String
        let href: String

        init(_ label: String, _ href: String) {
            self.label = label
            self.href = href
        }

        var description: String { "\(label) -> \(href)" }
    }

    private func anchors(in markdown: String) -> [Anchor] {
        captures("<a href=\"([^\"]*)\">(.*?)</a>", in: html(markdown))
            .map { Anchor($0[2], $0[1]) }
    }

    private func lineAnchors(in rendered: String) -> [String] {
        captures(
            "data-line-start=\"(\\d+)\" data-line-end=\"(\\d+)\"", in: rendered
        ).map { "\($0[1])-\($0[2])" }
    }

    private func captures(
        _ pattern: String, in text: String
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ) else {
            XCTFail("bad pattern: \(pattern)")
            return []
        }
        let subject = text as NSString
        let whole = NSRange(location: 0, length: subject.length)
        return regex.matches(in: text, range: whole).map { match in
            (0 ..< match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound
                    ? "" : subject.substring(with: range)
            }
        }
    }
}
