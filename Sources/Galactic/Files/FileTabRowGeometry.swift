import CoreGraphics

/// Where the tabs in one row sit, and which place a dragged one has earned.
///
/// Arithmetic over a list of widths, with no view and no layout read-back. Two
/// reasons it is not simply done in the strip: the rule it encodes was wrong
/// once in a way only moving a mouse revealed, and a position read back from the
/// layout arrives a pass late — so the strip has to compute this anyway, and
/// computing it here means it can be checked.
public struct FileTabRowGeometry {

    /// Tab widths in row order.
    public let widths: [CGFloat]
    public let spacing: CGFloat
    /// Where the first tab's leading edge sits.
    public let leading: CGFloat

    public init(widths: [CGFloat], spacing: CGFloat, leading: CGFloat) {
        self.widths = widths
        self.spacing = spacing
        self.leading = leading
    }

    public func minX(at index: Int) -> CGFloat {
        guard index > 0 else { return leading }
        let before = widths.prefix(min(index, widths.count))
        return leading + before.reduce(0) { $0 + $1 + spacing }
    }

    public func midX(at index: Int) -> CGFloat {
        guard widths.indices.contains(index) else { return minX(at: index) }
        return minX(at: index) + widths[index] / 2
    }

    /// The one place a tab being dragged has earned, or `nil` for none.
    ///
    /// **An edge against a neighbour's midline, never a centre against it.**
    /// Going right, the dragged tab's trailing edge must pass the midline of the
    /// tab on its right; going left, its leading edge must pass the midline of
    /// the tab on its left.
    ///
    /// The asymmetry is the entire point. It leaves a gap between the two
    /// conditions the width of the tab being passed, so a tab that has just
    /// changed places is not immediately eligible to change back. Comparing a
    /// centre to a midline has no gap: the condition that moved the tab is
    /// still true after it moves, so the pair oscillates on every frame the
    /// pointer holds still near a boundary — which is what "bouncing around"
    /// looks like from the outside.
    ///
    /// One place at a time, so a caller applies it until it answers `nil`. A
    /// single frame of a fast drag can earn several.
    public func step(draggedAt index: Int, leadingEdge: CGFloat) -> Int? {
        guard widths.indices.contains(index) else { return nil }
        let trailingEdge = leadingEdge + widths[index]

        if index + 1 < widths.count, trailingEdge > midX(at: index + 1) {
            return index + 1
        }
        if index > 0, leadingEdge < midX(at: index - 1) {
            return index - 1
        }
        return nil
    }

    /// Which slot a bare horizontal position names, for a tab arriving from
    /// another row where there is no neighbour to have earned anything from.
    public func slot(forLeadingEdge x: CGFloat) -> Int {
        for index in widths.indices where x < midX(at: index) { return index }
        return widths.count
    }

    /// Keep a dragged tab inside the strip.
    ///
    /// Past either end there is no slot left to earn and nothing to exchange
    /// with, so a tab allowed out there is simply lost until it is dragged back.
    /// The inset is `leading` at both ends, the strip being padded evenly.
    ///
    /// The upper bound is floored at the lower one, so a tab wider than the
    /// strip it is in pins to the left rather than inverting the range.
    public func clamped(
        leadingEdge x: CGFloat, width: CGFloat, stripWidth: CGFloat
    ) -> CGFloat {
        let upper = max(leading, stripWidth - leading - width)
        return min(max(x, leading), upper)
    }
}
