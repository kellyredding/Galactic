import CoreGraphics

/// A tab being dragged, and the arrangement it is asking for.
///
/// **Extracted from the view because that is where two rounds of drag bugs hid.**
/// The row arithmetic already lives in `FileTabRowGeometry` for exactly this
/// reason — "both faults were in a `View`, where nothing could test them" — and
/// the state machine around it was still in there, so a report of "dragging
/// between rows locks up" could only be answered by reading code and guessing.
/// Everything here is a value: give it widths and pointer positions, read the
/// proposal back, assert on it.
///
/// The proposal covers **every row**, not one. A tab crossing rows changes two
/// rows at once, so a per-row proposal had to be torn down and rebuilt
/// mid-gesture, against widths the same move had just invalidated. One
/// arrangement cannot disagree with itself.
public struct FileTabDrag: Equatable {

    /// What the strip's layout costs, so this can do the same arithmetic the
    /// view does without asking it.
    public struct Metrics: Equatable {
        public let tabSpacing: CGFloat
        public let rowSpacing: CGFloat
        public let stripPadding: CGFloat
        public let tabHeight: CGFloat
        /// How far below the last row still counts as asking for a new one.
        public let newRowMargin: CGFloat

        public init(
            tabSpacing: CGFloat,
            rowSpacing: CGFloat,
            stripPadding: CGFloat,
            tabHeight: CGFloat,
            newRowMargin: CGFloat
        ) {
            self.tabSpacing = tabSpacing
            self.rowSpacing = rowSpacing
            self.stripPadding = stripPadding
            self.tabHeight = tabHeight
            self.newRowMargin = newRowMargin
        }

        var pitch: CGFloat { tabHeight + rowSpacing }
    }

    public let id: FileTab.ID
    /// Where inside the tab it was picked up, so it does not snap its leading
    /// edge to the cursor.
    public let grabX: CGFloat
    public private(set) var pointer: CGPoint

    /// The arrangement as it was when the tab was picked up.
    ///
    /// **The strip is drawn from this, not from the proposal.** Every tab is laid
    /// out where it already was and then *offset* toward where the proposal puts
    /// it, which is what makes displacement a property change rather than a
    /// layout change — and a property can carry a curve where a re-measurement in
    /// this view cannot. Drawing the proposal directly is correct and lands every
    /// tab in one frame with no movement to read.
    public let origin: [[FileTab.ID]]

    /// The whole strip as the drag is asking for it.
    public private(set) var proposal: [[FileTab.ID]]

    /// Every tab's width as of pickup, and the reason it is a snapshot.
    ///
    /// A tab crossing rows re-fits both rows: the one it left has more room, the
    /// one it joined has less, and a tab landing alone in a row can jump from a
    /// filename to a whole path — two or three times wider. Under the hand that
    /// means the tab balloons, the grab point slides because `grabX` was measured
    /// against the old width, and the clamp ceiling drops far enough to yank the
    /// tab leftward. Nothing about a strip being rearranged should change how
    /// wide its tabs are until the rearranging is done.
    public let frozen: [FileTab.ID: CGFloat]

    private let metrics: Metrics

    public init(
        id: FileTab.ID,
        grabX: CGFloat,
        pointer: CGPoint,
        arrangement: [[FileTab.ID]],
        widths: [FileTab.ID: CGFloat],
        metrics: Metrics
    ) {
        self.id = id
        self.grabX = grabX
        self.pointer = pointer
        self.origin = arrangement
        self.proposal = arrangement
        self.frozen = widths
        self.metrics = metrics
    }

    /// How far a tab is drawn from where the frozen layout put it.
    ///
    /// Zero for everything until the proposal moves something, one tab's width
    /// and a gap once it does — and a whole row's pitch vertically when a tab has
    /// been asked to change rows.
    public func offset(of tab: FileTab.ID, stripWidth: CGFloat) -> CGSize {
        guard let from = position(of: tab, in: origin),
            let to = position(of: tab, in: proposal)
        else { return .zero }

        let y = CGFloat(to.row - from.row) * metrics.pitch
        if tab == id {
            // The dragged one follows the pointer rather than its slot, or it
            // would lag the hand moving it.
            return CGSize(
                width: leadingEdge(stripWidth: stripWidth)
                    - minX(of: from.column, in: origin[from.row]),
                height: y
            )
        }
        return CGSize(
            width: minX(of: to.column, in: proposal[to.row])
                - minX(of: from.column, in: origin[from.row]),
            height: y
        )
    }

    private func position(
        of tab: FileTab.ID, in arrangement: [[FileTab.ID]]
    ) -> (row: Int, column: Int)? {
        for (r, row) in arrangement.enumerated() {
            if let c = row.firstIndex(of: tab) { return (r, c) }
        }
        return nil
    }

    private func minX(of column: Int, in row: [FileTab.ID]) -> CGFloat {
        row.prefix(column).reduce(metrics.stripPadding) {
            $0 + (frozen[$1] ?? 0) + metrics.tabSpacing
        }
    }

    // MARK: - Reading

    public func position(of id: FileTab.ID) -> (row: Int, column: Int)? {
        for (r, row) in proposal.enumerated() {
            if let c = row.firstIndex(of: id) { return (r, c) }
        }
        return nil
    }

    /// Whether the pointer is asking for a row that does not exist yet, and
    /// would get one.
    public func isProposingNewRow() -> Bool {
        guard let (row, _) = position(of: id) else { return false }
        let count = proposal.count
        guard band(of: pointer.y, rows: count) >= count else { return false }
        // A lone tab dropped below its own last row takes its row with it and
        // puts an identical one back, so the target would promise nothing.
        return !(proposal[row].count == 1 && row == count - 1)
    }

    /// Where the dragged tab's leading edge is being asked to sit, clamped into
    /// the strip.
    public func leadingEdge(stripWidth: CGFloat) -> CGFloat {
        guard let (row, _) = position(of: id) else { return 0 }
        return geometry(ofRow: row).clamped(
            leadingEdge: pointer.x - grabX,
            width: frozen[id] ?? 0,
            stripWidth: stripWidth
        )
    }

    // MARK: - Settling

    /// Take a new pointer position and settle the proposal around it.
    ///
    /// Vertical first, then horizontal **in the same call**, which is what makes
    /// a tab arriving in a row take its place in it immediately rather than
    /// sitting wherever it landed until the gesture ends.
    public mutating func update(pointer: CGPoint, stripWidth: CGFloat) {
        self.pointer = pointer
        settleRow()
        settleColumn(stripWidth: stripWidth)
    }

    /// Which row the pointer is asking for.
    ///
    /// **It has to reach the middle of the band.** A row is one tab tall, so
    /// without a dead zone a few pixels of tremor at a boundary flips the tab
    /// between two rows over and over — the vertical answer to the same problem
    /// the edge-against-midline rule solves going sideways.
    private mutating func settleRow() {
        guard let (row, column) = position(of: id) else { return }
        let target = band(of: pointer.y, rows: proposal.count)
        guard target != row, hasReachedMiddle(of: target, from: row) else {
            return
        }

        proposal[row].remove(at: column)
        if target >= proposal.count {
            proposal.append([id])
        } else {
            let slot = geometry(ofRow: target)
                .slot(forLeadingEdge: pointer.x - grabX)
            proposal[target].insert(id, at: min(slot, proposal[target].count))
        }
        // A row whose last tab just left stops being a row, now rather than on
        // release, so the strip being looked at is the strip about to be got.
        proposal.removeAll { $0.isEmpty }
    }

    /// Where in its row the tab has earned a place, one step at a time.
    ///
    /// Looped, because one frame of a fast drag can earn several places, and the
    /// geometry is rebuilt each time round — held across the loop it describes
    /// the row as it was before the step, and a wide tab passing a narrow one
    /// then reads itself as owed a move back and stays put.
    private mutating func settleColumn(stripWidth: CGFloat) {
        let edge = leadingEdge(stripWidth: stripWidth)
        guard let (row, _) = position(of: id) else { return }
        for _ in 0..<proposal[row].count {
            guard let (currentRow, currentColumn) = position(of: id) else {
                return
            }
            guard
                let step = geometry(ofRow: currentRow).step(
                    draggedAt: currentColumn, leadingEdge: edge
                )
            else { return }
            proposal[currentRow].remove(at: currentColumn)
            proposal[currentRow].insert(id, at: step)
        }
    }

    // MARK: - Arithmetic

    /// Which row band a vertical position is over.
    ///
    /// One band past the last row means a new row, which is the only way a row
    /// is created. Everything else clamps, so dragging above the strip or far
    /// below it means the nearest real row — the new-row band is a margin under
    /// the last row rather than all the space beneath the strip, or a drag that
    /// wandered downward would silently split the arrangement.
    func band(of y: CGFloat, rows count: Int) -> Int {
        let raw = Int(((y - metrics.rowSpacing) / metrics.pitch).rounded(.down))
        let bottom = CGFloat(count) * metrics.pitch + metrics.newRowMargin
        if raw >= count, y <= bottom { return count }
        return max(0, min(count - 1, raw))
    }

    private func hasReachedMiddle(of row: Int, from: Int) -> Bool {
        let count = proposal.count
        let middle: CGFloat =
            row >= count
            // The new-row band is a margin rather than a whole row, so its
            // middle is nearer: reaching into open space below the strip should
            // not need as much travel as landing on a row.
            ? CGFloat(count) * metrics.pitch + metrics.newRowMargin / 2
            : metrics.rowSpacing + CGFloat(row) * metrics.pitch
                + metrics.tabHeight / 2
        return row > from ? pointer.y >= middle : pointer.y <= middle
    }

    private func geometry(ofRow row: Int) -> FileTabRowGeometry {
        FileTabRowGeometry(
            widths: proposal.indices.contains(row)
                ? proposal[row].map { frozen[$0] ?? 0 } : [],
            spacing: metrics.tabSpacing,
            leading: metrics.stripPadding
        )
    }
}
