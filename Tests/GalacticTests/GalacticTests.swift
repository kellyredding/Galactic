import AppKit
import XCTest
@testable import Galactic

/// Smoke test for Galactic's public surface. Exercises the
/// chrome-facing types from outside the module to confirm
/// the visibility audit caught everything chrome consumes.
/// Add real engine-level tests here as the module grows.
final class GalacticPublicSurfaceTests: XCTestCase {
    func testColorThemeLookup() {
        let theme = TerminalColorTheme.theme(named: "galaxy-default")
        XCTAssertEqual(theme.id, "galaxy-default")
        XCTAssertFalse(theme.ansiColors.isEmpty)
        XCTAssertEqual(theme.ansiColors.count, 16)
    }

    func testColorThemeBuiltInsNonEmpty() {
        XCTAssertFalse(TerminalColorTheme.builtIn.isEmpty)
    }

    func testNsColorFromHex() {
        let color = TerminalColorTheme.nsColor(from: "#FF0000")
        XCTAssertNotNil(color)
    }

    func testShellCursorStyleAllCases() {
        XCTAssertEqual(ShellCursorStyle.allCases.count, 3)
        XCTAssertEqual(ShellCursorStyle.block.displayName, "Block")
    }

    func testScrollbackAttributesOptionSet() {
        let combined: ScrollbackAttributes = [.bold, .italic]
        XCTAssertTrue(combined.contains(.bold))
        XCTAssertTrue(combined.contains(.italic))
        XCTAssertFalse(combined.contains(.underline))
    }

    func testScrollbackColorEquality() {
        XCTAssertEqual(
            ScrollbackColor.ansi256(15), ScrollbackColor.ansi256(15)
        )
        XCTAssertNotEqual(
            ScrollbackColor.defaultColor,
            ScrollbackColor.defaultInvertedColor
        )
    }

    func testTerminalDisplayThrottleShared() {
        XCTAssertNotNil(TerminalDisplayThrottle.shared)
    }

    func testTerminalContainerInsetsContent() {
        let terminal = NSView()
        let container = GalacticTerminalContainerView(
            terminalView: terminal, inset: 4
        )
        container.frame = NSRect(x: 0, y: 0, width: 100, height: 80)

        XCTAssertTrue(container.terminalView === terminal)
        XCTAssertEqual(container.contentInsets.left, 4)
        // Content rect is the container's bounds inset on every edge —
        // the rect the terminal fills and overlays align to.
        XCTAssertEqual(
            container.contentFrame,
            NSRect(x: 4, y: 4, width: 92, height: 72)
        )
    }
}
