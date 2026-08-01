import AppKit
import XCTest
@testable import Galactic

/// Which window a confirmation sheet hangs from.
///
/// The whole point is one negative: never a panel. A floating panel can hold
/// key while declining to be main, so asking for the key window returns the
/// panel whenever one is up — and a sheet attached to a small borderless panel
/// renders in its corner, laid out against a frame that cannot hold it. The
/// symptom looks like a broken alert rather than a wrong window, which is why
/// the rule is pinned here instead of trusted.
final class SheetAlertHostTests: XCTestCase {

    /// Stands in for the find bar: key-capable, main-incapable.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Visible on purpose: `canBecomeMain`'s default implementation is false
    /// until a window is on screen, so a hidden window is indistinguishable
    /// from a panel as far as the rule below is concerned.
    private func window() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        w.setIsVisible(true)
        return w
    }

    private func panel() -> Panel {
        Panel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }

    func testTheMainWindowWins() {
        let main = window()

        XCTAssertTrue(
            SheetAlert.host(
                mainWindow: main, keyWindow: panel(), windows: []
            ) === main
        )
    }

    /// The reported bug, in one assertion.
    func testAPanelHoldingKeyIsNotChosen() {
        let real = window()
        let findBar = panel()

        let host = SheetAlert.host(
            mainWindow: nil, keyWindow: findBar, windows: [real]
        )

        XCTAssertFalse(
            host === findBar,
            "a sheet on a borderless floating panel renders in its corner "
                + "against a frame that cannot hold it"
        )
        XCTAssertTrue(host === real)
    }

    func testAKeyWindowThatCouldBeMainIsAccepted() {
        let key = window()

        XCTAssertTrue(
            SheetAlert.host(
                mainWindow: nil, keyWindow: key, windows: []
            ) === key
        )
    }

    func testTheLastResortSkipsPanelsToo() {
        let real = window()
        let findBar = panel()
        findBar.setIsVisible(true)

        let host = SheetAlert.host(
            mainWindow: nil, keyWindow: nil, windows: [findBar, real]
        )

        XCTAssertTrue(
            host === real,
            "scanning for a host must apply the same rule as preferring one"
        )
    }

    func testTheLastResortSkipsHiddenWindows() {
        let hidden = window()
        hidden.setIsVisible(false)

        XCTAssertNil(
            SheetAlert.host(
                mainWindow: nil, keyWindow: nil, windows: [hidden]
            ),
            "an offscreen window cannot show the user a question"
        )
    }

    /// Worth pinning because it is the reason the tests above show their
    /// windows, and the reason the scan checks visibility as well as capability
    /// — a subclass is free to claim main while hidden, and a sheet on an
    /// offscreen window asks a question nobody can answer.
    func testAHiddenWindowCannotBeMainByDefault() {
        let hidden = window()
        hidden.setIsVisible(false)

        XCTAssertFalse(hidden.canBecomeMain)
    }

    func testNoWindowAtAllResolvesToNothing() {
        XCTAssertNil(
            SheetAlert.host(mainWindow: nil, keyWindow: nil, windows: [])
        )
    }
}
