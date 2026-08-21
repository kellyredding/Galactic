import Foundation

/// Whether a hovered tab has earned a tooltip yet.
///
/// ### Why this is not just a `@State var hovered`
///
/// A tooltip is three rules about *time and order*, and all three are invisible
/// in view code. It must wait before appearing, so that sweeping the pointer
/// across a strip on the way somewhere else does not strobe every tab it
/// crosses. It must **not** wait again once one is already up, or reading along
/// a row costs a pause per tab. And it must survive the order SwiftUI actually
/// delivers hover in.
///
/// ### The ordering trap, which is the reason this is a type
///
/// `onHover` does not pair enter and exit the way the pointer does. Moving from
/// one tab to its neighbour delivers the **new tab's enter before the old tab's
/// exit** — so a hide that trusts "I got an exit" turns the tooltip off
/// immediately after turning it on, and the tooltip flickers exactly while the
/// reader is doing the thing it exists for. Every exit here is therefore
/// checked against who is current, and a stale one is ignored.
///
/// ### No clock
///
/// The delay is the caller's to wait out: `enter` answers `.arm`, the caller
/// sleeps, and `elapsed` decides whether that wait still means anything. So
/// every rule above is reachable from a test as a sequence of calls, with no
/// clock to stub and no timing to be flaky about — which is the same bargain
/// `FileTabDrag` made after two rounds of drag defects hid in view code.
public struct FileTabHoverIntent: Equatable {

    /// Long enough that crossing a strip on the way elsewhere shows nothing,
    /// short enough to read as an answer rather than a wait.
    ///
    /// Not zero, which is what was originally asked for. A tooltip with no
    /// delay fires on tabs the pointer is only passing over, and the strip
    /// wraps to several rows — so a diagonal trip across it would raise and
    /// drop a panel per tab. `.help()`'s own delay is the opposite failure and
    /// is not reachable from SwiftUI, which is why this exists at all.
    public static let delay: Duration = .milliseconds(150)

    /// What the caller should do about an event.
    public enum Action: Equatable {
        /// Wait `FileTabHoverIntent.delay`, then call `elapsed(for:)`.
        case arm(FileTab.ID)
        case show(FileTab.ID)
        case hide
        case ignore
    }

    /// The tab the pointer is on, whether or not its tooltip is up yet.
    private var current: FileTab.ID?
    /// The tab whose tooltip is up.
    public private(set) var shown: FileTab.ID?
    /// Set while a drag owns the pointer.
    private var suppressed = false

    public init() {}

    public var isShowing: Bool { shown != nil }

    /// The pointer arrived on a tab.
    public mutating func enter(_ id: FileTab.ID) -> Action {
        guard !suppressed else { return .ignore }
        current = id

        // Already up: swap the content rather than waiting again. The wait is
        // the price of the first tooltip, not of every one.
        if shown != nil {
            shown = id
            return .show(id)
        }
        return .arm(id)
    }

    /// The pointer left a tab.
    ///
    /// Ignored unless `id` is the tab the pointer is actually on — see the
    /// ordering note above. This is the single rule that keeps a tooltip
    /// steady while the pointer moves along a row.
    public mutating func exit(_ id: FileTab.ID) -> Action {
        guard current == id else { return .ignore }
        current = nil
        guard shown != nil else { return .ignore }
        shown = nil
        return .hide
    }

    /// The wait armed by `enter` is over.
    public mutating func elapsed(for id: FileTab.ID) -> Action {
        // The pointer moved on, or left, while this was waiting. A tooltip for
        // a tab nobody is pointing at is the flicker the delay exists to stop.
        guard !suppressed, current == id else { return .ignore }
        shown = id
        return .show(id)
    }

    /// A drag has taken the pointer, so no tooltip until it lets go.
    ///
    /// Dragging a tab means the pointer is held down and travelling across
    /// every other tab in the strip, which is the worst possible case for
    /// anything that appears on hover — and the one time the reader is
    /// certainly not asking which file this is.
    public mutating func suppress() -> Action {
        suppressed = true
        current = nil
        guard shown != nil else { return .ignore }
        shown = nil
        return .hide
    }

    /// The drag ended. Nothing is shown until the pointer arrives somewhere
    /// again, so a drop does not leave a tooltip under the cursor.
    public mutating func resume() {
        suppressed = false
    }
}
