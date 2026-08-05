import AppKit
import Foundation
import XCTest
@testable import Galactic

/// Bare URLs, and what the attributed emitter does with them.
///
/// swift-markdown does not attach the GFM autolink extension, so a pasted URL
/// reaches the emitter as ordinary text. These pin both halves of the fix: the
/// span finder's idea of where an address ends, and the fact that finding spans
/// after the parse is what keeps code and link labels out of it.
final class MarkdownAutolinkTests: XCTestCase {

    // MARK: - Where an address ends

    func testFindsABareURL() {
        XCTAssertEqual(addresses(in: "see https://example.com now"),
                       ["https://example.com"])
    }

    func testFindsHTTPAsWellAsHTTPS() {
        XCTAssertEqual(addresses(in: "http://localhost:3000/items"),
                       ["http://localhost:3000/items"])
    }

    func testFindsEveryURLInOneRun() {
        XCTAssertEqual(
            addresses(in: "https://a.example and https://b.example"),
            ["https://a.example", "https://b.example"]
        )
    }

    /// A URL at the end of a sentence: the full stop is the sentence's.
    func testDropsTrailingSentencePunctuation() {
        XCTAssertEqual(addresses(in: "Read https://example.com/docs."),
                       ["https://example.com/docs"])
        XCTAssertEqual(addresses(in: "Read https://example.com/docs, then go"),
                       ["https://example.com/docs"])
        XCTAssertEqual(addresses(in: "Really? https://example.com/a?b=1!"),
                       ["https://example.com/a?b=1"])
    }

    /// The two bracket cases the balance rule exists to tell apart.
    func testDropsAClosingBracketItDidNotOpen() {
        XCTAssertEqual(addresses(in: "(see https://example.com/docs)"),
                       ["https://example.com/docs"])
        XCTAssertEqual(addresses(in: "[see https://example.com/docs]"),
                       ["https://example.com/docs"])
    }

    func testKeepsAClosingBracketItDidOpen() {
        XCTAssertEqual(
            addresses(in: "https://en.wikipedia.org/wiki/Foo_(bar)"),
            ["https://en.wikipedia.org/wiki/Foo_(bar)"]
        )
    }

    /// Both rules together, punctuation outside the balanced pair.
    func testTrimsPunctuationAfterABalancedBracket() {
        XCTAssertEqual(
            addresses(in: "See https://en.wikipedia.org/wiki/Foo_(bar)."),
            ["https://en.wikipedia.org/wiki/Foo_(bar)"]
        )
    }

    func testRequiresAWordBoundary() {
        XCTAssertEqual(addresses(in: "nothttps://example.com"), [])
        XCTAssertEqual(addresses(in: "3https://example.com"), [])
    }

    func testRequiresAScheme() {
        XCTAssertEqual(addresses(in: "example.com"), [])
        XCTAssertEqual(addresses(in: "www.example.com"), [])
    }

    /// The false positive that ruled `NSDataDetector` out: these repos discuss
    /// their own Crystal sources by name, and `.cr` is a live TLD.
    func testLeavesFilenamesAlone() {
        XCTAssertEqual(addresses(in: "edit paths.cr and scratch.cr"), [])
        XCTAssertEqual(addresses(in: "ScratchRow.swift renders it"), [])
    }

    func testStopsAtWhitespace() {
        XCTAssertEqual(addresses(in: "https://example.com /other"),
                       ["https://example.com"])
    }

    // MARK: - What the emitter does with them

    func testLinksABareURLInAParagraph() {
        XCTAssertEqual(links(rendering: "Ticket at https://example.com/1"),
                       [Link("https://example.com/1", "https://example.com/1")])
    }

    func testLinksABareURLInAHeadingAndAListItem() {
        XCTAssertEqual(links(rendering: "# https://example.com").count, 1)
        XCTAssertEqual(links(rendering: "- go to https://example.com").count, 1)
    }

    /// The whole reason for running after the parse rather than over source.
    func testLeavesInlineCodeAlone() {
        XCTAssertEqual(links(rendering: "run `curl https://example.com`"), [])
    }

    func testLeavesAFencedBlockAlone() {
        let markdown = """
        ```
        curl https://example.com
        ```
        """
        XCTAssertEqual(links(rendering: markdown), [])
    }

    // MARK: - Links that already worked

    func testAnExplicitLinkStillPointsAtItsDestination() {
        XCTAssertEqual(
            links(rendering: "[the docs](https://example.com/docs)"),
            [Link("the docs", "https://example.com/docs")]
        )
    }

    /// What the CLI writes when it linkifies a Linear description at sync
    /// time. It must come out as one link, not a link nested in a link.
    func testASelfLabelledLinkStaysOneLink() {
        XCTAssertEqual(
            links(rendering: "[https://example.com/1](https://example.com/1)"),
            [Link("https://example.com/1", "https://example.com/1")]
        )
    }

    func testAnAngleBracketAutolinkStillWorks() {
        XCTAssertEqual(links(rendering: "<https://example.com>"),
                       [Link("https://example.com", "https://example.com")])
    }

    /// A label that is itself a URL must not become a second, nested link —
    /// the destination the author wrote is the one that counts.
    func testALabelledURLKeepsTheAuthoredDestination() {
        XCTAssertEqual(
            links(rendering: "[https://shown.example](https://real.example)"),
            [Link("https://shown.example", "https://real.example")]
        )
    }

    /// Emphasis nests between the text and the link, which is why the
    /// inside-a-link check walks ancestors instead of reading `parent`.
    func testAnEmphasisedURLLabelKeepsTheAuthoredDestination() {
        XCTAssertEqual(
            links(rendering: "[**https://shown.example**](https://real.example)"),
            [Link("https://shown.example", "https://real.example")]
        )
    }

    /// The case where skipping a link's label actually decides the outcome.
    /// Everywhere else `visitLink` overwrites the label anyway; with an empty
    /// destination there is nothing to overwrite it with, and a label that
    /// happens to read like a URL must not become a link to itself — the
    /// author said this text goes nowhere.
    func testAnEmptyDestinationLinksNothing() {
        XCTAssertEqual(links(rendering: "[https://shown.example]()"), [])
    }

    // MARK: - Nothing else moved

    func testTextWithoutAURLRendersUnchanged() {
        let rendered = MarkdownAttributedText.attributed("Plain **body** text")
        XCTAssertEqual(rendered.string, "Plain body text")
        XCTAssertEqual(links(rendering: "Plain **body** text"), [])
    }

    /// Attributes are added, never characters — the scratch feed's search
    /// highlight works in character offsets over the same body.
    func testLinkingDoesNotMoveAnyCharacters() {
        let source = "Ticket at https://example.com/1. Thanks!"
        XCTAssertEqual(MarkdownAttributedText.attributed(source).string, source)
    }

    // MARK: - Helpers

    private func addresses(in text: String) -> [String] {
        MarkdownAutolink.spans(in: text).map { $0.url.absoluteString }
    }

    private struct Link: Equatable, CustomStringConvertible {
        let text: String
        let destination: String

        init(_ text: String, _ destination: String) {
            self.text = text
            self.destination = destination
        }

        var description: String { "\(text) -> \(destination)" }
    }

    private func links(rendering markdown: String) -> [Link] {
        let rendered = MarkdownAttributedText.attributed(markdown)
        var found: [Link] = []
        rendered.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            guard let url = value as? URL else { return }
            found.append(Link(
                rendered.attributedSubstring(from: range).string,
                url.absoluteString
            ))
        }
        return found
    }
}
