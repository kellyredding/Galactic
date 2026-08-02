import XCTest
@testable import Galactic

/// Guards the vendored reader assets against silently leaving the bundle.
///
/// `ReaderAssets` degrades a missing resource to an empty string rather than
/// trapping, so that losing highlight.js costs a reader its colours instead of
/// its page. That is the right behaviour and it is also why the loss is hard to
/// notice: nothing throws, nothing logs, and unhighlighted source still looks
/// like source to anyone not comparing it against yesterday.
///
/// These are deliberately **not** in `ShippedJavaScriptTests`. That gate parses
/// its entries as JavaScript, and half of these are stylesheets. The other half
/// are minified third-party bundles that arrived valid and are never edited
/// here — parsing three megabytes of vendored mermaid on every test run would
/// buy nothing, which is the same judgement the apps' own gates make when they
/// skip `.min.js`. What can actually go wrong is the resource declaration in
/// `Package.swift`, so presence is what gets asserted.
final class ReaderAssetsTests: XCTestCase {

    /// Name → contents, for every asset shipped to a reader document.
    private var readerAssets: [(String, String)] {
        [
            ("highlight.min.js", ReaderAssets.highlightJS),
            ("mermaid.min.js", ReaderAssets.mermaidJS),
            ("github.min.css", ReaderAssets.githubLightCSS),
            ("github-dark.min.css", ReaderAssets.githubDarkCSS),
        ]
    }

    func testEveryReaderAssetIsPresent() {
        for (name, contents) in readerAssets {
            XCTAssertFalse(
                contents.isEmpty,
                "\(name) is missing from the package bundle — check the "
                    + "resources declaration in Package.swift"
            )
        }
    }

    /// Both themes resolve, and to different stylesheets.
    ///
    /// A single wrong resource name would leave one appearance falling back to
    /// the other's palette, which reads as a theme bug rather than a missing
    /// file.
    func testHighlightThemeAnswersADistinctStylesheetPerAppearance() {
        let light = ReaderAssets.highlightThemeCSS(isDark: false)
        let dark = ReaderAssets.highlightThemeCSS(isDark: true)

        XCTAssertFalse(light.isEmpty)
        XCTAssertFalse(dark.isEmpty)
        XCTAssertNotEqual(light, dark)
    }

    /// Coverage floor, mirroring `ShippedJavaScriptTests`.
    ///
    /// The list above is hand-maintained, so the failure mode is forgetting to
    /// add an asset rather than an entry going stale.
    func testCoverageHasNotShrunk() {
        XCTAssertGreaterThanOrEqual(readerAssets.count, 4)
    }
}
