import XCTest
@testable import Galactic

/// Reading a theme pair off disk, and the fallbacks around it.
final class SourceThemeLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("source-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(
        _ css: String, _ name: String = "theme-dark.css"
    ) throws {
        try css.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private var loader: SourceThemeLoader {
        SourceThemeLoader(directory: directory)
    }

    func testAnAbsentDirectoryLeavesBothAppearancesStock() {
        let missing = SourceThemeLoader(
            directory: directory.appendingPathComponent("nope")
        )

        XCTAssertNil(missing.theme(isDark: true))
        XCTAssertNil(missing.theme(isDark: false))
    }

    /// The immediate case: a dark theme and no light counterpart.
    func testOnlyADarkStylesheetLeavesLightStock() throws {
        try write(".hljs{color:#f8f8f8;background:#141414}")

        XCTAssertEqual(loader.theme(isDark: true)?.background, "#141414")
        XCTAssertNil(loader.theme(isDark: false))
    }

    func testEachAppearanceReadsItsOwnFile() throws {
        try write(".hljs{color:#f8f8f8;background:#141414}", "theme-dark.css")
        try write(".hljs{color:#202020;background:#fdfdfd}", "theme-light.css")

        XCTAssertEqual(loader.theme(isDark: true)?.background, "#141414")
        XCTAssertEqual(loader.theme(isDark: false)?.background, "#fdfdfd")
    }

    /// A declined stylesheet costs its own appearance and nothing else.
    func testADeclinedStylesheetDoesNotDisturbTheOtherAppearance() throws {
        try write(".hljs{color:#fff}", "theme-dark.css")
        try write(".hljs{color:#202020;background:#fdfdfd}", "theme-light.css")

        XCTAssertNil(loader.theme(isDark: true))
        XCTAssertEqual(loader.theme(isDark: false)?.background, "#fdfdfd")
    }

    /// The point of reading from disk rather than a bundle: editing a
    /// stylesheet shows up without rebuilding or restarting anything.
    func testAnEditedStylesheetIsRereadOnceItChanges() throws {
        try write(".hljs{color:#f8f8f8;background:#141414}")
        XCTAssertEqual(loader.theme(isDark: true)?.background, "#141414")

        // The cache is keyed on modification date and size, and a filesystem
        // timestamp is coarse enough that an immediate rewrite of the same
        // length can land inside the same tick.
        Thread.sleep(forTimeInterval: 1.05)
        try write(".hljs{color:#f8f8f8;background:#2b2b2b}")

        XCTAssertEqual(loader.theme(isDark: true)?.background, "#2b2b2b")
    }

    /// Deleting a stylesheet returns the reader to stock rather than leaving
    /// the last good one cached forever.
    func testARemovedStylesheetReturnsToStock() throws {
        try write(".hljs{color:#f8f8f8;background:#141414}")
        XCTAssertNotNil(loader.theme(isDark: true))

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("theme-dark.css")
        )

        XCTAssertNil(loader.theme(isDark: true))
    }
}
