import CoreGraphics

/// Which tab is above or below the one selected.
///
/// **By where the tabs are, not by how many there are.** Keeping the column
/// index answers "the second tab of the row below", which is the wrong question:
/// a row of long paths and a row of short filenames put their second tabs
/// nowhere near each other, so pressing down moved the selection sideways as
/// well. Rows are only as regular as the labels in them, and labels are not
/// regular at all.
///
/// Pure, and given widths rather than measuring them, so the rule can be tested
/// without a strip and so it uses the same numbers the strip was drawn with.
public enum FileTabRowNavigation {

    /// The column in `target` that lies under the horizontal centre of the tab
    /// at `column` in `current`.
    ///
    /// The centre rather than the leading edge, because a wide tab's edge can sit
    /// under a different tab than its bulk does — dropping down from a long path
    /// should land on whatever is under the middle of it, which is where the eye
    /// is.
    ///
    /// Past the end of a shorter row it clamps to that row's last tab. A reader
    /// pressing down expects to arrive somewhere, and refusing to move because
    /// the row below is shorter reads as a broken keystroke.
    public static func column(
        movingFrom column: Int,
        in current: [CGFloat],
        to target: [CGFloat],
        spacing: CGFloat,
        leading: CGFloat
    ) -> Int {
        guard !target.isEmpty else { return 0 }
        guard current.indices.contains(column) else {
            return min(column, target.count - 1)
        }

        let centre =
            minX(of: column, in: current, spacing: spacing, leading: leading)
            + current[column] / 2

        var x = leading
        for index in target.indices {
            if centre < x + target[index] { return index }
            x += target[index] + spacing
        }
        return target.count - 1
    }

    private static func minX(
        of column: Int, in widths: [CGFloat], spacing: CGFloat, leading: CGFloat
    ) -> CGFloat {
        widths.prefix(column).reduce(leading) { $0 + $1 + spacing }
    }
}
