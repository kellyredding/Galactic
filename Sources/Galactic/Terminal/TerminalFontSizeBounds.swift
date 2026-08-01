import CoreGraphics

/// How far a terminal's font size may be zoomed, and by how much per step.
///
/// One window governs every surface that can zoom — each pane of each split, in
/// either app — and both apps previously declared their own copy of it beside
/// their own copy of the arithmetic. Held together with the operations because a
/// window without its step is only half the rule: a caller holding just the
/// bounds still has to decide how far one keypress moves, and deciding that
/// twice is how two panes come to zoom at different rates.
public struct TerminalFontSizeBounds {

    /// Smallest and largest point size a pane may be zoomed to.
    public let range: ClosedRange<CGFloat>

    /// How far one zoom gesture moves the size.
    public let step: CGFloat

    /// The window both apps use.
    public static let standard = TerminalFontSizeBounds(
        range: 10...24, step: 1
    )

    public init(range: ClosedRange<CGFloat>, step: CGFloat) {
        self.range = range
        self.step = step
    }

    /// One step larger, stopping at the ceiling.
    public func increased(from size: CGFloat) -> CGFloat {
        min(size + step, range.upperBound)
    }

    /// One step smaller, stopping at the floor.
    public func decreased(from size: CGFloat) -> CGFloat {
        max(size - step, range.lowerBound)
    }

    /// Whether there is room to grow — drives the enabled state of a menu item,
    /// so it has to agree with `increased(from:)` about where the ceiling is.
    public func canIncrease(from size: CGFloat) -> Bool {
        size < range.upperBound
    }

    /// Whether there is room to shrink.
    public func canDecrease(from size: CGFloat) -> Bool {
        size > range.lowerBound
    }

    /// A size held inside the window.
    ///
    /// For sizes arriving from outside the zoom gestures — a persisted setting,
    /// or one seeded from a sibling pane — which have never been through
    /// `increased`/`decreased` and so were never clamped by them.
    public func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, range.lowerBound), range.upperBound)
    }
}
