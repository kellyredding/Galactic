import XCTest
@testable import Galactic

/// Reading a stylesheet, declining the ones that cannot be used, and deriving
/// the two colours a highlight.js theme never carries.
final class SourceThemeStylesheetTests: XCTestCase {

    private func theme(_ css: String) -> SourceTheme? {
        try? SourceThemeStylesheet.theme(from: css).get()
    }

    private func rejection(
        _ css: String
    ) -> SourceThemeStylesheet.Rejection? {
        switch SourceThemeStylesheet.theme(from: css) {
        case .success: return nil
        case .failure(let rejection): return rejection
        }
    }

    // MARK: - Reading

    func testItReadsTheBackgroundAndForegroundOffTheHljsRule() {
        let resolved = theme(".hljs{color:#f8f8f8;background:#141414}")

        XCTAssertEqual(resolved?.background, "#141414")
        XCTAssertEqual(resolved?.foreground, "#f8f8f8")
    }

    /// Almost every stylesheet upstream ships puts a banner comment flush
    /// against this rule, so a scan that does not strip comments first reads
    /// the comment as part of the selector and matches nothing. This was true
    /// of 21 of the 256 upstream themes, `github-dark` among them.
    func testABannerCommentDoesNotHideTheHljsRule() {
        let css = """
            pre code.hljs{display:block}/*!
              Theme: Something
              Author: someone
            */.hljs{color:#c9d1d9;background:#0d1117}
            """

        XCTAssertEqual(theme(css)?.background, "#0d1117")
    }

    /// The shape a hand-written stylesheet actually takes: a banner, then
    /// pretty-printed rules with one declaration per line. Every other case
    /// here is minified, which is how upstream ships them and not how anyone
    /// writes one.
    func testItReadsAPrettyPrintedStylesheet() {
        let css = """
            pre code.hljs{display:block;overflow-x:auto;padding:1em}
            /*!
              Theme: Something Dark
              Derived from: an editor colour scheme, scope by scope
            */

            /* global: foreground / background */
            .hljs {
              color: #F8F8F8;
              background: #141414;
            }

            /* comment (italic in the source) */
            .hljs-comment,
            .hljs-quote {
              color: #5F5A60;
              font-style: italic;
            }
            """
        let resolved = theme(css)

        XCTAssertEqual(resolved?.background, "#141414")
        XCTAssertEqual(resolved?.foreground, "#f8f8f8")
    }

    /// Some stylesheets declare the palette once on `:root` and reference it
    /// from every rule.
    func testAVarReferenceResolvesAgainstTheStylesheet() {
        let css = """
            :root{--page:#101010;--text:#abb2bf}
            .hljs{color:var(--text);background:var(--page)}
            """

        XCTAssertEqual(theme(css)?.background, "#101010")
        XCTAssertEqual(theme(css)?.foreground, "#abb2bf")
    }

    /// A property whose name merely starts with another's is a different
    /// property, and the colon is what separates them.
    func testAVarReferenceIsNotConfusedByALongerName() {
        let css = """
            :root{--page-alt:#ffffff;--page:#202020}
            .hljs{background:var(--page)}
            """

        XCTAssertEqual(theme(css)?.background, "#202020")
    }

    func testItAcceptsShorthandHexAndRGB() {
        XCTAssertEqual(theme(".hljs{background:#abc}")?.background, "#aabbcc")
        XCTAssertEqual(
            theme(".hljs{background:rgb(20, 30, 40)}")?.background, "#141e28"
        )
    }

    /// `.hljs` sharing a rule with other selectors still names it.
    func testItFindsHljsInASelectorList() {
        let css = ".foo,.hljs,.bar{background:#222222}"

        XCTAssertEqual(theme(css)?.background, "#222222")
    }

    /// A rule for a descendant of `.hljs` is not the `.hljs` rule.
    func testItIgnoresRulesThatMerelyMentionHljs() {
        let css = ".hljs-string{background:#ff0000}"

        XCTAssertEqual(rejection(css), .noBackgroundDeclared)
    }

    /// Unusual but legible: the page's own contrast answers for the text,
    /// which is where an unstyled line lands anyway.
    func testAStylesheetWithNoForegroundFallsBackByContrast() {
        XCTAssertEqual(theme(".hljs{background:#101010}")?.foreground,
                       "#ffffff")
        XCTAssertEqual(theme(".hljs{background:#fafafa}")?.foreground,
                       "#000000")
    }

    // MARK: - Declining

    func testAStylesheetWithNoBackgroundIsDeclined() {
        XCTAssertEqual(
            rejection(".hljs{color:#ffffff}"), .noBackgroundDeclared
        )
    }

    /// A gradient or an image has no single colour to draw the gutter from.
    func testAGradientBackgroundIsDeclined() {
        XCTAssertEqual(
            rejection(".hljs{background:linear-gradient(#fff,#000)}"),
            .noBackgroundDeclared
        )
    }

    /// The escape that turns a stylesheet into script injection.
    func testAStylesheetThatClosesTheStyleBlockIsDeclined() {
        XCTAssertEqual(
            rejection(".hljs{background:#111}</style><script>x()</script>"),
            .closesTheStyleBlock
        )
    }

    func testTheStyleBlockCheckIgnoresCasing() {
        XCTAssertEqual(
            rejection(".hljs{background:#111}</STYLE>"),
            .closesTheStyleBlock
        )
    }

    func testAStylesheetThatReachesTheNetworkIsDeclined() {
        XCTAssertEqual(
            rejection("@import url(x);.hljs{background:#111}"),
            .reachesTheNetwork(construct: "@import")
        )
        XCTAssertEqual(
            rejection(".hljs{background:#111;border-image:url(x.png)}"),
            .reachesTheNetwork(construct: "url(")
        )
    }

    func testAnOversizeStylesheetIsDeclined() {
        let padding = String(
            repeating: "a", count: SourceThemeStylesheet.maxBytes + 1
        )

        guard case .tooLarge = rejection("/*\(padding)*/") else {
            return XCTFail("an oversize stylesheet should be declined")
        }
    }

    /// Every rejection says what is wrong, because the person who wrote the
    /// file is standing right there.
    func testEveryRejectionExplainsItself() {
        let rejections: [SourceThemeStylesheet.Rejection] = [
            .tooLarge(bytes: 1), .closesTheStyleBlock,
            .reachesTheNetwork(construct: "@import"), .noBackgroundDeclared,
        ]
        for rejection in rejections {
            XCTAssertFalse(rejection.reason.isEmpty)
        }
    }

    // MARK: - Deriving

    /// The property the sign flip would break. The gutter recedes from the
    /// page in *both* appearances, which is why it is a luminance shift rather
    /// than a step toward the text.
    func testTheGutterIsDarkerThanThePageInBothAppearances() {
        for background in ["#0d1117", "#ffffff", "#3b2f2f", "#f5f5dc"] {
            let resolved = theme(".hljs{color:#808080;background:\(background)}")
            let page = ThemeColor(background)
            let gutter = ThemeColor(resolved?.gutter ?? "")

            XCTAssertLessThan(
                gutter?.luminance ?? 1,
                page?.luminance ?? 0,
                "\(background) should sit above its gutter"
            )
        }
    }

    /// Against black there is nothing darker to reach, so it lifts instead —
    /// otherwise the strip would vanish into the page.
    func testTheGutterSeparatesFromAnAlreadyBlackPage() {
        let resolved = theme(".hljs{color:#ffffff;background:#000000}")

        XCTAssertNotEqual(resolved?.gutter, "#000000")
    }

    func testLineNumbersSitBetweenThePageAndItsText() {
        let resolved = theme(".hljs{color:#f8f8f8;background:#141414}")
        let number = ThemeColor(resolved?.lineNumber ?? "")

        XCTAssertGreaterThan(number?.luminance ?? 0, 0.05)
        XCTAssertLessThan(number?.luminance ?? 1, 0.97)
    }

    /// The divider is a hint, not a line the eye lands on: it stays nearer the
    /// page than the line numbers are.
    func testTheGutterDividerIsSubtlerThanTheLineNumbers() {
        let resolved = theme(".hljs{color:#f8f8f8;background:#141414}")
        let divider = ThemeColor(resolved?.gutterBorder ?? "")
        let number = ThemeColor(resolved?.lineNumber ?? "")

        XCTAssertLessThan(
            divider?.luminance ?? 1, number?.luminance ?? 0
        )
    }

    /// A sanity check rather than a contract: stock is answered verbatim and
    /// never derived, so this only has to show the rules land in the right
    /// neighbourhood.
    func testDerivingFromTheStockDarkStylesheetLandsNearTheStockPalette() {
        let resolved = theme(ReaderAssets.githubDarkCSS)
        let palette = ReaderTheme.standard(isDark: true)

        XCTAssertEqual(resolved?.background, palette.background)

        let derived = ThemeColor(resolved?.lineNumber ?? "")
        let actual = ThemeColor(palette.lineNumber)
        XCTAssertEqual(
            derived?.luminance ?? 0, actual?.luminance ?? 1, accuracy: 0.08,
            "derived line numbers should read like the stock ones"
        )
    }
}
