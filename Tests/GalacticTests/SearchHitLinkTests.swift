import XCTest

@testable import Galactic

/// The one place a path and a line become a URL and back.
///
/// This file is the whole answer to the objection that routing clicks through a
/// URL is stringly-typed, so it earns that by round-tripping the paths that
/// actually break naive escaping rather than the ones that obviously work.
final class SearchHitLinkTests: XCTestCase {

    private func roundTrip(
        _ path: String, line: Int? = nil, file: StaticString = #filePath,
        testLine: UInt = #line
    ) {
        guard let url = SearchHitLink.url(path: path, line: line) else {
            return XCTFail(
                "no URL for \(path)", file: file, line: testLine
            )
        }
        guard let parsed = SearchHitLink.parse(url) else {
            return XCTFail(
                "did not parse back: \(url)", file: file, line: testLine
            )
        }
        XCTAssertEqual(parsed.path, path, file: file, line: testLine)
        XCTAssertEqual(parsed.line, line, file: file, line: testLine)
    }

    // MARK: - Paths that break naive escaping

    func testAnOrdinaryPath() {
        roundTrip("/Users/x/projects/app/main.swift")
    }

    func testAPathWithSpaces() {
        roundTrip("/Users/x/My Documents/a file.txt")
    }

    /// A `#` would end the URL and take the rest of the path with it.
    func testAPathWithAFragmentMarker() {
        roundTrip("/Users/x/notes/C#/readme.md")
    }

    /// A literal `%` is the one that breaks double-encoding: decoded twice it
    /// becomes something else entirely.
    func testAPathWithAPercent() {
        roundTrip("/Users/x/tmp/100%/done.txt")
        roundTrip("/Users/x/tmp/%20literal.txt")
    }

    func testAPathWithAQuestionMark() {
        roundTrip("/Users/x/what?/now.txt")
    }

    func testAPathWithAnAmpersand() {
        roundTrip("/Users/x/this & that/file.txt")
    }

    func testAPathWithAnEqualsSign() {
        roundTrip("/Users/x/k=v/file.txt")
    }

    func testAPathWithAPlus() {
        roundTrip("/Users/x/c++/main.cc")
    }

    func testAPathOutsideASCII() {
        roundTrip("/Users/x/café/résumé.md")
        roundTrip("/Users/x/日本語/ファイル.txt")
        roundTrip("/Users/x/emoji 🎉/party.txt")
    }

    func testAPathWithANewline() {
        roundTrip("/Users/x/weird\nname.txt")
    }

    func testAPathWithAQuote() {
        roundTrip("/Users/x/it's here/\"quoted\".txt")
    }

    // MARK: - Lines

    func testALineTravels() {
        roundTrip("/Users/x/a.swift", line: 337)
    }

    func testLineOne() {
        roundTrip("/Users/x/a.swift", line: 1)
    }

    func testALargeLine() {
        roundTrip("/Users/x/a.swift", line: 999_999)
    }

    func testNoLineIsNil() {
        roundTrip("/Users/x/a.swift", line: nil)
    }

    /// A line that is not a line loses the line, not the link — the file still
    /// opens, which is what a reader asked for by clicking it.
    func testANonPositiveLineIsDroppedButThePathSurvives() throws {
        let url = try XCTUnwrap(
            SearchHitLink.url(path: "/Users/x/a.swift", line: 0)
        )
        let parsed = try XCTUnwrap(SearchHitLink.parse(url))
        XCTAssertEqual(parsed.path, "/Users/x/a.swift")
        XCTAssertNil(parsed.line)
    }

    func testAnUnparseableLineIsDroppedButThePathSurvives() throws {
        let url = try XCTUnwrap(
            URL(string: "\(SearchHitLink.scheme)://?path=/a.swift&line=abc")
        )
        let parsed = try XCTUnwrap(SearchHitLink.parse(url))
        XCTAssertEqual(parsed.path, "/a.swift")
        XCTAssertNil(parsed.line)
    }

    // MARK: - Refusals

    func testAnEmptyPathHasNoURL() {
        XCTAssertNil(SearchHitLink.url(path: ""))
    }

    func testAnotherSchemeIsNotOurs() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/?path=/a"))
        XCTAssertNil(SearchHitLink.parse(url))
    }

    func testHttpIsNotOurs() throws {
        // The delegate opens http externally, and it must reach that branch
        // rather than being claimed here.
        let url = try XCTUnwrap(URL(string: "http://example.com/"))
        XCTAssertNil(SearchHitLink.parse(url))
    }

    func testOurSchemeWithNoPathIsRefused() throws {
        let url = try XCTUnwrap(
            URL(string: "\(SearchHitLink.scheme)://?line=3")
        )
        XCTAssertNil(SearchHitLink.parse(url))
    }

    func testOurSchemeWithAnEmptyPathIsRefused() throws {
        let url = try XCTUnwrap(
            URL(string: "\(SearchHitLink.scheme)://?path=")
        )
        XCTAssertNil(SearchHitLink.parse(url))
    }

    // MARK: - The scheme itself

    /// Not `http`, not `https`, and not `galaxy` — the delegate branches on all
    /// three, and colliding with any of them would route reader links somewhere
    /// unintended.
    func testTheSchemeCollidesWithNothingTheDelegateAlreadyHandles() {
        XCTAssertFalse(["http", "https", "galaxy", "file"].contains(
            SearchHitLink.scheme
        ))
    }

    func testTheURLCarriesTheScheme() throws {
        let url = try XCTUnwrap(SearchHitLink.url(path: "/a.swift"))
        XCTAssertEqual(url.scheme, SearchHitLink.scheme)
    }
}
