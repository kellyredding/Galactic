import XCTest

@testable import Galactic

/// How the strip arranges itself, and what it refuses to rearrange.
///
/// Most of these pin *stability* rather than behaviour: that closing a tab does
/// not reflow the rows, that a reopened tab does not push everything else
/// sideways, that opening a file twice is one tab. Those are the properties a
/// reader notices only when they break, and each one is a decision rather than
/// an emergent effect of the data structure.
final class FileTabStripModelTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/work/\(name)")
    }

    private func filled(_ count: Int) -> FileTabStripModel {
        var m = FileTabStripModel()
        for i in 0..<count { m.open(url: url("f\(i).swift")) }
        return m
    }

    // MARK: - Opening

    func testANewStripIsEmpty() {
        let m = FileTabStripModel()
        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.selected)
        XCTAssertTrue(m.tabs.isEmpty)
    }

    func testOpeningSelectsWhatWasOpened() {
        var m = FileTabStripModel()
        let tab = m.open(url: url("a.swift"))

        XCTAssertEqual(m.selectedID, tab.id)
        XCTAssertEqual(m.tabs.count, 1)
    }

    /// The same file reached two ways is one tab. Two would mean two sets of
    /// notes on one path and two answers to where the reader had scrolled.
    func testOpeningTheSameFileTwiceSelectsTheExistingTab() {
        var m = FileTabStripModel()
        let first = m.open(url: url("a.swift"))
        m.open(url: url("b.swift"))

        let again = m.open(url: url("a.swift"))

        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(m.tabs.count, 2)
        XCTAssertEqual(m.selectedID, first.id)
    }

    /// Per-file state is kept, so reopening an already-open file does not quietly
    /// reset where the reader was.
    func testReopeningAnOpenFileKeepsItsState() {
        var m = FileTabStripModel()
        let tab = m.open(url: url("a.swift"))
        m.update(id: tab.id) { $0.scrollOffset = 420 }

        m.open(url: url("a.swift"))

        XCTAssertEqual(m.selected?.scrollOffset, 420)
    }

    // MARK: - Rows

    func testTabsFillOneRowUpToTheSoftLimit() {
        let m = filled(FileTabStripModel.softRowLimit)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.rows[0].count, FileTabStripModel.softRowLimit)
    }

    func testTheTabAfterTheLimitStartsASecondRow() {
        let m = filled(FileTabStripModel.softRowLimit + 1)

        XCTAssertEqual(m.rows.count, 2)
        XCTAssertEqual(m.rows[1].count, 1)
    }

    /// The property a reader notices only when it breaks. Pulling a tab up from
    /// the row below to fill a gap would rewrite the strip under someone every
    /// time they tidied up.
    func testClosingDoesNotPullATabUpFromTheRowBelow() {
        var m = filled(FileTabStripModel.softRowLimit + 1)
        let firstRowTab = m.rows[0][3]

        m.close(id: firstRowTab.id)

        XCTAssertEqual(
            m.rows[0].count, FileTabStripModel.softRowLimit - 1,
            "the gap stays a gap"
        )
        XCTAssertEqual(m.rows[1].count, 1)
    }

    /// The one case where positions do change, and it has to: an empty row is
    /// not something to leave on screen.
    func testEmptyingARowRemovesItAndShiftsTheRestUp() {
        var m = filled(FileTabStripModel.softRowLimit + 1)
        let onlyTabInSecondRow = m.rows[1][0]

        m.close(id: onlyTabInSecondRow.id)

        XCTAssertEqual(m.rows.count, 1)
    }

    func testClosingTheLastTabLeavesAnEmptyStrip() {
        var m = FileTabStripModel()
        let tab = m.open(url: url("a.swift"))

        m.close(id: tab.id)

        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.selected)
        XCTAssertTrue(m.rows.isEmpty)
    }

    func testClosingAnUnknownTabChangesNothing() {
        var m = filled(3)
        let before = m

        XCTAssertNil(m.close(id: UUID()))
        XCTAssertEqual(m, before)
    }

    // MARK: - What is selected after a close

    func testClosingTheSelectedTabSelectsItsRightHandNeighbour() {
        var m = filled(3)
        let middle = m.rows[0][1]
        let right = m.rows[0][2]
        m.select(id: middle.id)

        m.close(id: middle.id)

        XCTAssertEqual(m.selectedID, right.id)
    }

    /// Nothing to the right, so the caret falls back rather than jumping rows.
    func testClosingTheLastTabInARowSelectsItsLeftHandNeighbour() {
        var m = filled(3)
        let last = m.rows[0][2]
        let before = m.rows[0][1]
        m.select(id: last.id)

        m.close(id: last.id)

        XCTAssertEqual(m.selectedID, before.id)
    }

    func testClosingAnUnselectedTabLeavesTheSelectionAlone() {
        var m = filled(3)
        let selected = m.rows[0][0]
        m.select(id: selected.id)

        m.close(id: m.rows[0][2].id)

        XCTAssertEqual(m.selectedID, selected.id)
    }

    // MARK: - Rearranging

    func testMovingWithinARowReordersIt() {
        var m = filled(3)
        let first = m.rows[0][0]

        m.move(id: first.id, toRow: 0, at: 2)

        XCTAssertEqual(m.rows[0].map(\.id).last, first.id)
    }

    func testMovingAcrossRowsTakesTheTabWithIt() {
        var m = filled(FileTabStripModel.softRowLimit + 1)
        let fromSecondRow = m.rows[1][0]

        m.move(id: fromSecondRow.id, toRow: 0, at: 0)

        XCTAssertEqual(m.rows.count, 1, "the emptied row goes with it")
        XCTAssertEqual(m.rows[0].first?.id, fromSecondRow.id)
    }

    /// The soft limit governs new tabs, not the reader. Someone who drags
    /// fifteen into one row keeps fifteen there.
    func testARowMayBeDraggedPastTheSoftLimit() {
        var m = filled(FileTabStripModel.softRowLimit + 2)
        let a = m.rows[1][0]
        let b = m.rows[1][1]

        m.move(id: a.id, toRow: 0, at: 0)
        m.move(id: b.id, toRow: 0, at: 0)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.rows[0].count, FileTabStripModel.softRowLimit + 2)
    }

    func testMovingToARowThatDoesNotExistIsIgnored() {
        var m = filled(2)
        let before = m

        m.move(id: m.rows[0][0].id, toRow: 9, at: 0)

        XCTAssertEqual(m, before)
    }

    // MARK: - Reopening

    func testReopeningReturnsATabToItsOriginalRow() {
        var m = filled(FileTabStripModel.softRowLimit + 2)
        let fromSecondRow = m.rows[1][1]

        m.close(id: fromSecondRow.id)
        m.reopen(url: fromSecondRow.url, preferredRow: 1)

        XCTAssertEqual(m.rows[1].count, 2)
        XCTAssertEqual(m.rows[1].last?.path, fromSecondRow.path)
    }

    /// A row that emptied took its position with it. Inserting one back into the
    /// middle would move every tab the reader has looked at since.
    func testReopeningIntoAVanishedRowAppendsToTheLast() {
        var m = filled(FileTabStripModel.softRowLimit + 1)
        let onlyTabInSecondRow = m.rows[1][0]

        m.close(id: onlyTabInSecondRow.id)
        XCTAssertEqual(m.rows.count, 1, "precondition: the row is gone")

        m.reopen(url: onlyTabInSecondRow.url, preferredRow: 1)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.rows[0].last?.path, onlyTabInSecondRow.path)
    }

    func testReopeningIntoAnEmptyStripStartsARow() {
        var m = FileTabStripModel()
        m.reopen(url: url("a.swift"), preferredRow: 3)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.tabs.count, 1)
    }

    // MARK: - Restoring

    /// The reason this is not repeated `open` calls: `open` honours the soft row
    /// limit, so a reader's three rows would come back as one.
    func testRestoringKeepsTheRowsItWasGiven() {
        var m = FileTabStripModel()

        m.restore(rows: [[url("a.swift")], [url("b.swift"), url("c.swift")]])

        XCTAssertEqual(m.rows.count, 2)
        XCTAssertEqual(m.rows[0].map(\.url.lastPathComponent), ["a.swift"])
        XCTAssertEqual(
            m.rows[1].map(\.url.lastPathComponent), ["b.swift", "c.swift"]
        )
        XCTAssertEqual(m.tabs.count, 3)
    }

    /// More tabs in one row than a new tab would ever be given, because the
    /// limit governs where new tabs land and not where old ones were.
    func testRestoringDoesNotSplitARowAtTheSoftLimit() {
        var m = FileTabStripModel()
        let many = (0..<(FileTabStripModel.softRowLimit + 4)).map {
            url("f\($0).swift")
        }

        m.restore(rows: [many])

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.rows[0].count, many.count)
    }

    func testRestoringSelectsTheFirstTab() {
        var m = FileTabStripModel()

        m.restore(rows: [[url("a.swift")], [url("b.swift")]])

        XCTAssertEqual(m.selected?.url.lastPathComponent, "a.swift")
    }

    /// An empty row is a gap no reader made and none can close.
    func testRestoringDropsEmptyRows() {
        var m = FileTabStripModel()

        m.restore(rows: [[], [url("a.swift")], []])

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.rows[0].count, 1)
    }

    func testRestoringNothingLeavesAnEmptyStrip() {
        var m = filled(3)

        m.restore(rows: [])

        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.selectedID)
    }

    /// Restoring replaces rather than merges. A strip that kept what it had
    /// would double every tab on a second restore.
    func testRestoringReplacesWhateverWasOpen() {
        var m = filled(3)

        m.restore(rows: [[url("only.swift")]])

        XCTAssertEqual(m.tabs.count, 1)
        XCTAssertEqual(m.tabs[0].url.lastPathComponent, "only.swift")
    }

    // MARK: - Navigating

    func testStepsAlongARowStopAtItsEnds() {
        var m = filled(3)
        m.select(id: m.rows[0][0].id)

        m.selectPreviousInRow()
        XCTAssertEqual(
            m.selectedID, m.rows[0][0].id, "no wrap at the left edge"
        )

        m.selectNextInRow()
        m.selectNextInRow()
        m.selectNextInRow()
        XCTAssertEqual(
            m.selectedID, m.rows[0][2].id, "and none at the right"
        )
    }

    func testStepsBetweenRowsKeepTheColumn() {
        var m = filled(FileTabStripModel.softRowLimit + 3)
        m.select(id: m.rows[0][1].id)

        m.selectNextRow()

        XCTAssertEqual(m.selectedID, m.rows[1][1].id)
    }

    /// A reader pressing down expects to arrive somewhere; the nearest tab is a
    /// better answer than refusing to move.
    func testSteppingIntoAShorterRowClampsToItsEnd() {
        var m = filled(FileTabStripModel.softRowLimit + 1)
        m.select(id: m.rows[0][7].id)

        m.selectNextRow()

        XCTAssertEqual(m.selectedID, m.rows[1][0].id)
    }

    func testSteppingPastTheLastRowStaysPut() {
        var m = filled(3)
        m.select(id: m.rows[0][1].id)
        let before = m.selectedID

        m.selectNextRow()

        XCTAssertEqual(m.selectedID, before)
    }

    // MARK: - Per-file state

    /// The reason one shared reader works: anything not recorded on the tab is
    /// gone when the page rebuilds.
    func testEachTabRemembersItsOwnStateIndependently() {
        var m = filled(2)
        let a = m.rows[0][0]
        let b = m.rows[0][1]

        m.update(id: a.id) {
            $0.scrollOffset = 100
            $0.findQuery = "activate"
            $0.composerState = #"{"textareaValue":"half written"}"#
        }
        m.update(id: b.id) { $0.scrollOffset = 900 }

        XCTAssertEqual(m.tab(forPath: a.path)?.scrollOffset, 100)
        XCTAssertEqual(m.tab(forPath: a.path)?.findQuery, "activate")
        XCTAssertEqual(
            m.tab(forPath: a.path)?.composerState,
            #"{"textareaValue":"half written"}"#
        )
        XCTAssertEqual(m.tab(forPath: b.path)?.scrollOffset, 900)
        XCTAssertEqual(
            m.tab(forPath: b.path)?.findQuery, "",
            "one tab's find does not become another's"
        )
    }

    func testATabStartsInSourceMode() {
        var m = FileTabStripModel()
        XCTAssertEqual(m.open(url: url("a.md")).viewMode, .source)
    }

    func testUpdatingAnUnknownTabIsHarmless() {
        var m = filled(1)
        let before = m

        m.update(id: UUID()) { $0.scrollOffset = 5 }

        XCTAssertEqual(m, before)
    }

    // MARK: - Tab order

    /// Rows top to bottom, tabs left to right. This is the order a review
    /// groups its files by, so it is a wire-format concern as well as a visual
    /// one.
    func testTabOrderReadsRowsThenColumns() {
        var m = filled(FileTabStripModel.softRowLimit + 2)
        let expected =
            m.rows[0].map(\.path) + m.rows[1].map(\.path)

        XCTAssertEqual(m.tabs.map(\.path), expected)
    }
}
