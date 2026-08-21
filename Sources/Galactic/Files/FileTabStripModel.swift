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
///
/// ### Rows are the reader's, and were briefly not
///
/// They were made **derived** — one order, broken wherever the strip's width
/// ran out — to stop a crowded row squeezing its labels into nonsense. That
/// was the wrong cure for the right complaint. What fixes legibility is the
/// label giving up path segments and finally the filename's tail; rows had
/// nothing to do with it. Deriving them cost three things worth more:
///
/// - **Dragging between rows churned.** Dropping into a full row *must* push
///   its tail down, so the strip rearranged under the cursor on every vertical
///   move. No amount of tuning reaches "fine" from there.
/// - **A row could not be asked for.** It existed only once the count spilled,
///   so a reader who wanted to spread files out had no way to say so.
/// - **A row meant nothing durable.** A width artifact cannot carry a reader's
///   grouping, and named sets need exactly that — each set its own rows.
///
/// So rows are stored again, and nothing moves between them unless a reader
/// moves it. A row exists because it holds tabs: dropping a tab below the last
/// one makes a row, and a row whose last tab leaves stops being one.
public struct FileTabStripModel: Equatable {

    public private(set) var rows: [[FileTab]]
    public private(set) var selectedID: FileTab.ID?

    public init() {
        rows = []
        selectedID = nil
    }

    // MARK: - Reading

    /// Every tab, rows top to bottom and tabs left to right.
    ///
    /// The order a review groups its files by, and the order the horizontal
    /// keystrokes walk — which is why they cross a row break rather than
    /// stopping at one.
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

    /// How far into `tabs` a position sits, for the walks that cross rows.
    private func flatIndex(row: Int, column: Int) -> Int {
        rows.prefix(row).reduce(0) { $0 + $1.count } + column
    }

    // MARK: - Opening and closing

    /// Open a file, or select it if it is already open.
    ///
    /// The same file reached two ways — from a subfolder of an open folder, from
    /// a search, from a review — is one tab. Two tabs on one file would mean two
    /// sets of notes on one path and two answers to what the reader scrolled to.
    ///
    /// It lands at the end of the **last** row. No count sends it to a row of
    /// its own: a row is something a reader asks for, and a new file is not a
    /// request for one. Tabs simply get narrower, which the label tiers answer.
    @discardableResult
    public mutating func open(url: URL) -> FileTab {
        if let existing = tab(forPath: url.path) {
            selectedID = existing.id
            return existing
        }

        let tab = FileTab(url: url)
        if rows.isEmpty {
            rows.append([tab])
        } else {
            rows[rows.count - 1].append(tab)
        }
        selectedID = tab.id
        return tab
    }

    /// Close a tab and return it, so a caller can stack it and drop its notes.
    ///
    /// **Rows do not reflow.** A tab from the row below is never pulled up to
    /// fill the gap, because a reader who arranged a row is entitled to have it
    /// stay arranged — the alternative rewrites the strip every time they tidy
    /// up. An emptied row disappears and the rows below move up, which is the
    /// one case where positions change on their own.
    @discardableResult
    public mutating func close(id: FileTab.ID) -> FileTab? {
        guard let (r, c) = position(of: id) else { return nil }
        let index = flatIndex(row: r, column: c)
        let closed = rows[r][c]
        rows[r].remove(at: c)
        if rows[r].isEmpty { rows.remove(at: r) }

        // The next tab in reading order, then the previous — asked of the whole
        // order rather than the row, so closing the last tab of a row selects
        // the first of the next instead of jumping backwards over a full row.
        if selectedID == id {
            let remaining = tabs
            if index < remaining.count {
                selectedID = remaining[index].id
            } else if index > 0 {
                selectedID = remaining[index - 1].id
            } else {
                selectedID = nil
            }
        }
        return closed
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
    /// **A target row one past the last makes a new row**, which is how a row
    /// comes into existence at all: there is no add-a-row command and no empty
    /// row to manage, because a row with nothing in it is a gap no reader made
    /// and none can close. Dropping a tab below the strip asks for a row and
    /// gets one; taking the last tab out of a row takes the row with it.
    public mutating func move(
        id: FileTab.ID, toRow targetRow: Int, at targetIndex: Int
    ) {
        // Both ends guarded. The upper one is the interesting bound; the lower
        // one is here because this is `public` and `FileSet.move` forwards
        // straight through, so a negative row would reach `rows[targetRow]` and
        // trap. Refusing a nonsense row is the model's job, not its callers'.
        guard let (r, c) = position(of: id), targetRow >= 0,
            targetRow <= rows.count
        else { return }

        // A lone tab dropped below its own row would leave the row it came from
        // empty and take its place, which is a move that changes nothing while
        // looking like it should.
        if targetRow == rows.count, rows[r].count == 1 { return }

        let tab = rows[r].remove(at: c)
        if targetRow == rows.count {
            rows.append([tab])
        } else {
            // Clamped after the removal, since taking the tab out may have
            // shortened the row being inserted into.
            let index = max(0, min(targetIndex, rows[targetRow].count))
            rows[targetRow].insert(tab, at: index)
        }
        if rows[r].isEmpty { rows.remove(at: r) }
    }

    /// Take a whole arrangement at once.
    ///
    /// **What a drag hands over when it ends.** A drag proposes an arrangement
    /// of every row rather than one tab's destination, because a tab crossing
    /// rows changes two rows at once and describing that as a single move meant
    /// the caller reconstructing indices against a strip that had already
    /// shifted under it. One statement of where everything ended up cannot
    /// disagree with itself.
    ///
    /// Refused outright unless the arrangement is a permutation of what is
    /// already open — every tab exactly once, nothing invented. A partial
    /// arrangement would silently close files, which is not something a drag
    /// gets to do. Existing tabs are carried over by identity, so per-file state
    /// survives being rearranged.
    ///
    /// Empty rows are dropped, same as everywhere else.
    public mutating func rearrange(to arrangement: [[FileTab.ID]]) {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let flat = arrangement.flatMap { $0 }
        guard flat.count == byID.count, Set(flat) == Set(byID.keys) else {
            return
        }
        rows = arrangement
            .map { $0.compactMap { byID[$0] } }
            .filter { !$0.isEmpty }
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
        if preferredRow >= 0, preferredRow < rows.count {
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
    /// `open` appends to the last row, so a reader who arranged four tabs into
    /// three rows would get them re-packed into one on the way back in.
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

    /// Along the whole order, crossing a row break rather than stopping at it.
    ///
    /// Going left from the first tab of a row lands on the last tab of the row
    /// above — the tab that is visually to its left, so the keystroke and the
    /// eye agree. Stops at the two real ends, matching the view cyclers in both
    /// apps.
    public mutating func selectNext() { step(by: 1) }
    public mutating func selectPrevious() { step(by: -1) }

    private mutating func step(by delta: Int) {
        guard let id = selectedID, let (r, c) = position(of: id) else { return }
        let all = tabs
        let next = flatIndex(row: r, column: c) + delta
        guard next >= 0, next < all.count else { return }
        selectedID = all[next].id
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
