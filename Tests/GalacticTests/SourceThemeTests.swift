import XCTest
@testable import Galactic

/// The seam a host installs a theme through, and the stock value behind it.
final class SourceThemeTests: XCTestCase {

    override func tearDown() {
        // A mutable static that leaks between tests produces order-dependent
        // failures, which is the one real hazard of this design.
        SourceTheme.provider = { SourceTheme.stock(isDark: $0) }
        super.tearDown()
    }

    /// Stock is the current rendering, not an approximation of it. Everything
    /// downstream leans on this: derivation is only ever applied to a supplied
    /// stylesheet, so it never has to reproduce these values.
    func testStockIsTheExistingPalette() {
        for isDark in [true, false] {
            let stock = SourceTheme.stock(isDark: isDark)
            let palette = ReaderTheme.standard(isDark: isDark)

            XCTAssertEqual(stock.background, palette.background)
            XCTAssertEqual(stock.foreground, palette.foreground)
            XCTAssertEqual(stock.gutter, palette.gutter)
            XCTAssertEqual(stock.lineNumber, palette.lineNumber)
            XCTAssertEqual(
                stock.highlightCSS,
                ReaderAssets.highlightThemeCSS(isDark: isDark)
            )
        }
    }

    /// The gutter's divider was a literal in `SourceRenderer` before it was a
    /// field, and stock has to keep answering what that literal said.
    func testStockKeepsTheGutterDividerItAlwaysHad() {
        XCTAssertEqual(
            SourceTheme.stock(isDark: true).gutterBorder, "#21262d"
        )
        XCTAssertEqual(
            SourceTheme.stock(isDark: false).gutterBorder, "#d0d7de"
        )
    }

    func testTheDefaultProviderAnswersStock() {
        for isDark in [true, false] {
            XCTAssertEqual(
                SourceTheme.active(isDark: isDark),
                SourceTheme.stock(isDark: isDark)
            )
        }
    }

    func testAnInstalledProviderIsAsked() {
        let installed = SourceTheme(
            highlightCSS: ".hljs{color:#fff;background:#123456}",
            background: "#123456",
            foreground: "#ffffff",
            gutter: "#0c2c4c",
            lineNumber: "#8899aa",
            gutterBorder: "#2a4a6a"
        )
        SourceTheme.provider = { _ in installed }

        XCTAssertEqual(SourceTheme.active(isDark: true), installed)
        XCTAssertEqual(SourceTheme.active(isDark: false), installed)
    }

    /// A host answering for one appearance only is the ordinary case — a
    /// dark-only theme leaves light alone.
    func testAProviderCanOverrideOneAppearanceAndLeaveTheOther() {
        let dark = SourceTheme(
            highlightCSS: "", background: "#141414", foreground: "#f8f8f8",
            gutter: "#0a0a0a", lineNumber: "#7c7c7c", gutterBorder: "#2b2b2b"
        )
        SourceTheme.provider = { $0 ? dark : SourceTheme.stock(isDark: false) }

        XCTAssertEqual(SourceTheme.active(isDark: true), dark)
        XCTAssertEqual(
            SourceTheme.active(isDark: false),
            SourceTheme.stock(isDark: false)
        )
    }
}
