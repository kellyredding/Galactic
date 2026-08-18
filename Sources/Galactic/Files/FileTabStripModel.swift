import Foundation

/// The open files, arranged in rows, and which one is showing.
///
/// Rows rather than one scrolling strip because a reader working across a
/// feature keeps eight or ten files open and a horizontal strip hides most of
/// them behind an overflow they have to go looking in. Wrapping trades vertical
/// room the reader can see for a control they would otherwise have to operate.
///
/// In Galactic because neither app has anything like it: Assist Ant has no
/// inner-tab mechanism at all, and Galaxy's is a fixed enum of five known
/// sub-tabs — the wrong shape for a collection that changes as someone works.
public struct FileTabStripModel: Equatable {

    /// Where a new tab stops going and starts a row of its own.
    ///
    /// Soft: it governs only where *new* tabs land. A reader who drags fifteen
    /// into one row keeps fifteen in one row, because the arrangement is theirs
    /// once they have touched it.
    public static let softRowLimit = 10

    public private(set) var rows: [[FileTab]]
    public private(set) var selectedID: FileTab.ID?

    public init() {
        rows = []
        selectedID = nil
    }

    // MARK: - Reading

    /// Every tab, in tab order: rows top to bottom, tabs left to right. This is
    /// the order a review groups its files by.
    public var tabs: [FileTab] { rows.flatMap { $0 } }

    public var isEmpty: Bool { rows.allSatisfy(\.isEmpty) }

    public var selected: FileTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    public func tab(forPath path: String) -> FileTab? {
        tabs.first { $0.path == path }
    }

    /// Row and column of a tab, or nil when it is not open.
    public func position(of id: FileTab.ID) -> (row: Int, column: Int)? {
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(where: { $0.id == id }) {
                return (r, c)
            }
        }
        return nil
    }

    // MARK: - Opening and closing

    /// Open a file, or select it if it is already open.
    ///
    /// The same file reached two ways — from a subfolder of an open folder, from
    /// a search, from a review — is one tab. Two tabs on one file would mean two
    /// sets of notes on one path and two answers to what the reader scrolled to.
    @discardableResult
    public mutating func open(url: URL) -> FileTab {
        if let existing = tab(forPath: url.path) {
            selectedID = existing.id
            return existing
        }

        let tab = FileTab(url: url)
        if let last = rows.indices.last, rows[last].count < Self.softRowLimit {
            rows[last].append(tab)
        } else {
            rows.append([tab])
        }
        selectedID = tab.id
        return tab
    }

    /// Close a tab and return it, so a caller can stack it and drop its notes.
    ///
    /// Rows do not reflow. A tab from the row below is never pulled up to fill
    /// the gap, because a reader who arranged a row is entitled to have it stay
    /// arranged — the alternative rewrites the strip under them every time they
    /// tidy up. An emptied row disappears and the rows below move up, which is
    /// the one case where positions do change.
    @discardableResult
    public mutating func close(id: FileTab.ID) -> FileTab? {
        guard let (r, c) = position(of: id) else { return nil }
        let closed = rows[r][c]
        rows[r].remove(at: c)

        if selectedID == id { selectedID = neighbour(ofRow: r, column: c) }
        if rows[r].isEmpty { rows.remove(at: r) }
        if selectedID == nil { selectedID = tabs.first?.id }
        return closed
    }

    /// What to show once the tab at this position has gone: its right-hand
    /// neighbour, then its left-hand one, then whatever the next row offers.
    private func neighbour(ofRow r: Int, column c: Int) -> FileTab.ID? {
        if c < rows[r].count { return rows[r][c].id }
        if c > 0, c - 1 < rows[r].count { return rows[r][c - 1].id }
        if let next = rows.dropFirst(r + 1).first(where: { !$0.isEmpty }) {
            return next.first?.id
        }
        return rows.prefix(r).last(where: { !$0.isEmpty })?.last?.id
    }

    public mutating func select(id: FileTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Change one tab in place, for the per-file state a rebuild depends on.
    public mutating func update(
        id: FileTab.ID, _ mutate: (inout FileTab) -> Void
    ) {
        guard let (r, c) = position(of: id) else { return }
        mutate(&rows[r][c])
    }

    // MARK: - Rearranging

    /// Move a tab to a row and index, within a row or across rows.
    ///
    /// The only way a tab changes rows, which is what makes the soft limit a
    /// default rather than a rule.
    public mutating func move(
        id: FileTab.ID, toRow targetRow: Int, at targetIndex: Int
    ) {
        guard let (r, c) = position(of: id), targetRow < rows.count else {
            return
        }
        let tab = rows[r].remove(at: c)
        // Clamp after the removal, since taking the tab out may have shortened
        // the row being inserted into.
        let index = max(0, min(targetIndex, rows[targetRow].count))
        rows[targetRow].insert(tab, at: index)
        if rows[r].isEmpty, r != targetRow { rows.remove(at: r) }
    }

    /// Put a reopened tab back where it was, or at the end if that row is gone.
    ///
    /// Appending rather than recreating the row: a row that has since been
    /// emptied and removed took its position with it, and inserting a row back
    /// into the middle would move every tab the reader has looked at since.
    @discardableResult
    public mutating func reopen(
        url: URL, preferredRow: Int
    ) -> FileTab {
        if let existing = tab(forPath: url.path) {
            selectedID = existing.id
            return existing
        }
        let tab = FileTab(url: url)
        if preferredRow < rows.count {
            rows[preferredRow].append(tab)
        } else if rows.isEmpty {
            rows.append([tab])
        } else {
            rows[rows.count - 1].append(tab)
        }
        selectedID = tab.id
        return tab
    }

    // MARK: - Restoring

    /// Rebuild the strip from persisted rows, arrangement intact.
    ///
    /// Not expressible as repeated `open` calls, and that is why it exists:
    /// `open` honours the soft row limit and appends to the last row, so a
    /// reader who arranged four tabs into three rows would get them re-packed
    /// into one on the way back in. The soft limit governs where *new* tabs
    /// land; it has no business deciding where old ones were.
    ///
    /// Empty rows are dropped rather than preserved. A row with nothing in it
    /// is a gap in the strip that no reader made and none can close.
    public mutating func restore(rows persisted: [[URL]]) {
        rows = persisted
            .filter { !$0.isEmpty }
            .map { $0.map { FileTab(url: $0) } }
        selectedID = rows.first?.first?.id
    }

    // MARK: - Navigating

    /// Along the current row. Stops at the end rather than wrapping, matching
    /// the view cyclers in both apps.
    public mutating func selectNextInRow() { stepColumn(by: 1) }
    public mutating func selectPreviousInRow() { stepColumn(by: -1) }

    private mutating func stepColumn(by delta: Int) {
        guard let id = selectedID, let (r, c) = position(of: id) else { return }
        let next = c + delta
        guard next >= 0, next < rows[r].count else { return }
        selectedID = rows[r][next].id
    }

    /// Between rows, keeping the horizontal position where it can.
    ///
    /// Clamped to the shorter row's end rather than refusing to move: a reader
    /// pressing down expects to arrive somewhere, and the nearest tab is a
    /// better answer than no answer.
    public mutating func selectNextRow() { stepRow(by: 1) }
    public mutating func selectPreviousRow() { stepRow(by: -1) }

    private mutating func stepRow(by delta: Int) {
        guard let id = selectedID, let (r, c) = position(of: id) else { return }
        let next = r + delta
        guard next >= 0, next < rows.count, !rows[next].isEmpty else { return }
        selectedID = rows[next][min(c, rows[next].count - 1)].id
    }
}
