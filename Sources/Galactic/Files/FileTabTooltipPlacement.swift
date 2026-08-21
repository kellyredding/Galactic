import Foundation

/// Where the strip's tooltip sits.
///
/// Arithmetic over numbers the strip already has, with no view and no layout
/// read-back — the same division `FileTabRowGeometry` draws, and for the same
/// two reasons. The rule was wrong once in a way only moving a mouse revealed:
/// a tooltip on a tab near the right edge ran off the window and was invisible,
/// which is the one outcome it must never have. And a position read back from
/// the layout arrives a pass late *and* would mean measuring inside a view whose
/// measurements close a cycle that hangs the app.
///
/// So both coordinates are computed, and both are checkable.
public enum FileTabTooltipPlacement {

    /// The panel's leading edge.
    ///
    /// ### Clamped, not flipped
    ///
    /// The alternative considered was to decide by which half of the window the
    /// tab sits in — right-hand tabs anchor their tooltip's trailing edge to the
    /// tab's. It is worse on three counts. A short path on a right-hand tab does
    /// not need to move and would be moved anyway. A long path on a *left*-hand
    /// tab still overflows, because the rule reads the tab's position and the
    /// overflow comes from the content's width. And anchoring right means a
    /// panel longer than the tab's own offset runs off the **left** edge
    /// instead, trading one invisible tooltip for another.
    ///
    /// Clamping moves it exactly as far as the edge demands and no further, so
    /// it stays beside the tab it belongs to rather than jumping sides.
    ///
    /// - Parameters:
    ///   - tabLeadingEdge: where the hovered tab starts, in the strip's space.
    ///   - tooltipWidth: the panel's drawn width, including its padding.
    ///   - stripWidth: the strip's full width.
    ///   - inset: how far right of the tab the panel would ideally sit, so its
    ///     leading edge does not trace the tab's and read as the same object.
    ///   - padding: the strip's own inset at both ends.
    public static func x(
        tabLeadingEdge: CGFloat,
        tooltipWidth: CGFloat,
        stripWidth: CGFloat,
        inset: CGFloat,
        padding: CGFloat
    ) -> CGFloat {
        let ideal = tabLeadingEdge + inset
        // Nothing to clamp against until the strip has been given a width. Its
        // first pass has none, and clamping to a width of zero would pin every
        // tooltip to the left edge for a frame.
        guard stripWidth > 0 else { return ideal }

        let rightmost = stripWidth - padding - tooltipWidth
        // A path wider than the window cannot be placed so that all of it
        // shows. Pinned to the leading edge, which puts the part a reader scans
        // first — the folders nearest the root — on screen.
        guard rightmost > padding else { return padding }
        return min(ideal, rightmost)
    }

    /// The panel's offset from the strip's **bottom** edge, so that it sits just
    /// above `row`.
    ///
    /// Measured from the bottom because that is what lets the panel's own height
    /// go unasked: anchored to the bottom, it grows upward from this point.
    /// Asking how tall it is would mean measuring it, and measuring inside this
    /// view is what hangs the app.
    ///
    /// Above rather than below, because below is where it cannot be seen — the
    /// reader beneath the strip is a web view, and an AppKit-hosted view draws
    /// over whatever a SwiftUI sibling puts into its area. A tooltip under the
    /// last row was simply invisible, and the last row is where the deepest
    /// paths tend to sit.
    public static func offsetFromBottom(
        aboveRow row: Int,
        rowCount: Int,
        tabHeight: CGFloat,
        rowSpacing: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        let rows = max(1, rowCount)
        let pitch = tabHeight + rowSpacing
        let rowTop = rowSpacing + CGFloat(row) * pitch
        let stripHeight =
            2 * rowSpacing + CGFloat(rows) * tabHeight
            + CGFloat(rows - 1) * rowSpacing
        return rowTop - gap - stripHeight
    }
}
