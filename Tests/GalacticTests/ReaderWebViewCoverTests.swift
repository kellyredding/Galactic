import AppKit
import WebKit
import XCTest

@testable import Galactic

/// The page's pointer tracking, set aside while a panel covers it.
///
/// The first test pins the premise: if WebKit ever moves its tracking onto the
/// view itself, setting areas aside stops being the fix and overriding the
/// view's event methods starts being one.
@MainActor
final class ReaderWebViewCoverTests: XCTestCase {

    /// In a window, because WebKit adds its pointer tracking on joining one.
    private func makeView() -> (NSWindow, ReaderWebView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let view = ReaderWebView(
            frame: window.contentView!.bounds,
            configuration: WKWebViewConfiguration()
        )
        window.contentView!.addSubview(view)
        return (window, view)
    }

    private func webKitAreas(_ view: ReaderWebView) -> [NSTrackingArea] {
        view.trackingAreas.filter { ($0.owner as AnyObject?) !== view }
    }

    private func ownAreas(_ view: ReaderWebView) -> [NSTrackingArea] {
        view.trackingAreas.filter { ($0.owner as AnyObject?) === view }
    }

    func testWebKitTracksThePointerThroughAnObjectOfItsOwn() {
        let (window, view) = makeView()
        defer { _ = window }

        XCTAssertTrue(
            webKitAreas(view).contains {
                $0.options.contains(.mouseMoved)
                    && $0.options.contains(.cursorUpdate)
            }
        )
        XCTAssertFalse(
            ownAreas(view).contains { $0.options.contains(.mouseMoved) }
        )
    }

    func testCoveringSetsWebKitsTrackingAsideAndUncoveringPutsItBack() {
        let (window, view) = makeView()
        defer { _ = window }
        let before = webKitAreas(view)
        XCTAssertFalse(before.isEmpty)

        view.isCovered = true

        XCTAssertTrue(webKitAreas(view).isEmpty)

        view.isCovered = false

        XCTAssertEqual(webKitAreas(view).count, before.count)
        for area in before {
            XCTAssertTrue(view.trackingAreas.contains { $0 === area })
        }
    }

    func testTheViewsOwnTrackingIsLeftAlone() {
        let (window, view) = makeView()
        defer { _ = window }
        let own = ownAreas(view).count

        view.isCovered = true

        XCTAssertEqual(ownAreas(view).count, own)
    }

    /// Assigning the same value twice must not set aside nothing and then put
    /// back nothing, losing the areas set aside the first time.
    func testCoveringTwiceKeepsWhatWasSetAside() {
        let (window, view) = makeView()
        defer { _ = window }
        let before = webKitAreas(view).count

        view.isCovered = true
        view.isCovered = true
        view.isCovered = false

        XCTAssertEqual(webKitAreas(view).count, before)
    }
}
