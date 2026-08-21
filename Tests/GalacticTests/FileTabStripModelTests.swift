import XCTest

@testable import Galactic

/// How the strip arranges itself, and who the arrangement belongs to.
///
/// This suite has been rewritten twice in opposite directions, and says so
/// where each reversal sits. It first pinned *stored* rows: closing left the
/// row below alone, a restore came back arranged exactly as written, a row was
/// as long as a reader made it. Then rows were derived from the strip's width
/// and every one of those assertions was inverted to assert reflow. Rows are
/// stored again — dragging between rows churned, a row could not be asked for,
/// and a named set needs its rows to mean something durable — so the original
/// assertions are back. They are recorded as settled rather than quietly
/// restored, because a decision taken this many times is worth being able to
/// find.
///
/// What is pinned now: a row exists because a reader asked for it and it holds
/// tabs; nothing moves between rows unless a reader moves it; and the
/// horizontal keystrokes read the strip as one line however it is broken up.
final class FileTabStripModelTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/work/\(name)")
    }

    /// One row of `count` tabs, which is the only shape `open` can produce.
    private func filled(_ count: Int) -> FileTabStripModel {
        var m = FileTabStripModel()
        for i in 0..<count { m.open(url: url("f\(i).swift")) }
        return m
    }

    /// A strip in the shape a reader dragged it into, `counts` tabs to a row.
    ///
    /// Built by restoring rather than by a run of moves, because the moves are
    /// themselves under test here and a fixture leaning on them would fail
    /// twice over for one defect.
    private func arranged(_ counts: [Int]) -> FileTabStripModel {
        var rows: [[URL]] = []
        var next = 0
        for count in counts {
            var row: [URL] = []
            for _ in 0..<count {
                row.append(url("f\(next).swift"))
                next += 1
            }
            rows.append(row)
        }
        var m = FileTabStripModel()
        m.restore(rows: rows)
        return m
    }

    // MARK: - Opening

    func testANewStripIsEmpty() {
        let m = FileTabStripModel()
        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.selected)
        XCTAssertTrue(m.tabs.isEmpty)
        XCTAssertTrue(m.rows.isEmpty)
    }

    func testOpeningSelectsWhatWasOpened() {
        var m = FileTabStripModel()
        let tab = m.open(url: url("a.swift"))

        XCTAssertEqual(m.selectedID, tab.id)
        XCTAssertEqual(
            m.rows.map(\.count), [1], "the first tab makes the first row"
        )
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

    /// The last row, not the first with room in it: a new file joins the work in
    /// progress at the bottom of the strip, where the reader is looking.
    func testOpeningLandsAtTheEndOfTheLastRow() {
        var m = arranged([2, 1])

        let opened = m.open(url: url("new.swift"))

        XCTAssertEqual(m.rows.map(\.count), [2, 2])
        XCTAssertEqual(m.rows[1].last?.id, opened.id)
    }

    /// **Settled: no count sends a tab to a row of its own.** A soft limit of
    /// ten used to start one, and a capacity read off the strip's width used to
    /// break one. Both were answering a legibility complaint that belongs to the
    /// label, which gives up path segments and finally the filename's tail as
    /// tabs narrow. A row is something a reader asks for, and opening a file is
    /// not that request.
    func testNoNumberOfOpenFilesStartsASecondRow() {
        let m = filled(12)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.rows[0].count, 12)
    }

    // MARK: - Closing

    /// **Settled: this asserted a pull-up while rows were derived.** Reflowing
    /// meant every close rewrote rows the reader had never touched, and it meant
    /// closing followed a different rule from arranging. A reader who put a row
    /// together is entitled to have it stay as they left it, so the gap a close
    /// leaves stays a gap.
    func testClosingLeavesTheRowBelowAlone() {
        var m = arranged([3, 2])
        let inFirstRow = m.rows[0][1]
        let secondRow = m.rows[1].map(\.id)

        m.close(id: inFirstRow.id)

        XCTAssertEqual(m.rows.map(\.count), [2, 2])
        XCTAssertEqual(
            m.rows[1].map(\.id), secondRow, "nothing came up to fill the hole"
        )
    }

    /// The one close that moves tabs the reader did not close, and it moves whole
    /// rows rather than tabs: an empty row is a gap no reader made and none can
    /// close, so it goes and the rows below come up.
    func testEmptyingARowRemovesItAndShiftsTheRestUp() {
        var m = arranged([2, 1, 2])
        let lone = m.rows[1][0]
        let lastRow = m.rows[2].map(\.id)

        m.close(id: lone.id)

        XCTAssertEqual(m.rows.map(\.count), [2, 2])
        XCTAssertEqual(m.rows[1].map(\.id), lastRow, "it moved up a row")
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

    /// **Kept from the round where rows were derived, on its own merits.** The
    /// replacement is the next tab in the whole order rather than the next in
    /// the row, because at the end of a row that is the first tab of the row
    /// below — the file the reader was working towards. Asking the row instead
    /// would send them backwards over a row they had just finished with.
    func testClosingTheLastTabInARowSelectsTheFirstTabOfTheNext() {
        var m = arranged([3, 3])
        let lastInFirstRow = m.rows[0][2]
        let firstInSecondRow = m.rows[1][0]
        m.select(id: lastInFirstRow.id)

        m.close(id: lastInFirstRow.id)

        XCTAssertEqual(m.selectedID, firstInSecondRow.id)
    }

    /// Nothing after it *at all*, so the caret falls back. The fallback is about
    /// the end of the order rather than the end of a row, since a row's end is
    /// somewhere the selection passes straight through.
    func testClosingTheVeryLastTabSelectsItsLeftHandNeighbour() {
        var m = filled(3)
        let last = m.rows[0][2]
        let before = m.rows[0][1]
        m.select(id: last.id)

        m.close(id: last.id)

        XCTAssertEqual(m.selectedID, before.id)
    }

    /// The two things a close can do arriving together: the row goes because it
    /// emptied, and the caret falls back because there was nothing after it. It
    /// lands in the row above, which is the only row left to land in.
    func testClosingTheLoneTabInTheLastRowFallsBackIntoTheRowAbove() {
        var m = arranged([2, 1])
        let lone = m.rows[1][0]
        let lastAbove = m.rows[0][1]
        m.select(id: lone.id)

        m.close(id: lone.id)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.selectedID, lastAbove.id)
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

    /// The part of a drag the reader is watching: the tab lands where it was
    /// dropped, and the row it came from keeps whatever is still in it.
    func testMovingAcrossRowsTakesTheTabWithIt() {
        var m = arranged([2, 2])
        let fromSecondRow = m.rows[1][0]
        let stayingBehind = m.rows[1][1].id

        m.move(id: fromSecondRow.id, toRow: 0, at: 0)

        XCTAssertEqual(m.rows[0].first?.id, fromSecondRow.id)
        XCTAssertEqual(m.rows.map(\.count), [3, 1])
        XCTAssertEqual(m.rows[1].map(\.id), [stayingBehind])
        XCTAssertEqual(m.tabs.count, 4)
    }

    /// **Settled: this asserted a pushed-down tail while rows were derived.** A
    /// row had to be exactly as wide as the strip then, so a drop into a full one
    /// cost that row its last tab — which meant the strip rearranged under the
    /// cursor on every vertical move of a drag. Legibility is the label's
    /// problem, not the row's, so a row is as long as the reader made it and a
    /// drop into one only ever adds.
    func testMovingIntoAFullRowJustMakesItLonger() {
        var m = arranged([3, 3])
        let full = m.rows[0].map(\.id)
        let dragged = m.rows[1][2]

        m.move(id: dragged.id, toRow: 0, at: 0)

        XCTAssertEqual(m.rows.map(\.count), [4, 2], "no row has a cap")
        XCTAssertEqual(
            m.rows[0].map(\.id), [dragged.id] + full, "and it lost nothing"
        )
    }

    /// The only way a row comes into existence. There is no add-a-row command
    /// and no empty row to fill, because a row with nothing in it is a gap no
    /// reader made and none can close — so asking for a row means dropping a tab
    /// below the last one, and the index inside a row that does not exist yet
    /// cannot mean anything.
    func testMovingToTheRowAfterTheLastMakesANewRow() {
        var m = filled(3)
        let dragged = m.rows[0][0]

        m.move(id: dragged.id, toRow: 1, at: 7)

        XCTAssertEqual(m.rows.map(\.count), [2, 1])
        XCTAssertEqual(m.rows[1].map(\.id), [dragged.id])
        XCTAssertEqual(m.tabs.last?.id, dragged.id)
    }

    /// A lone tab dropped below its own row would empty the row it came from and
    /// take that row's place: the same strip, reached by a drag that looked like
    /// it did something. Refused outright, so a reader who overshoots the bottom
    /// of the strip sees nothing move rather than seeing it flicker.
    func testMovingALoneTabToANewRowChangesNothing() {
        var m = arranged([2, 1])
        let before = m

        m.move(id: m.rows[1][0].id, toRow: 2, at: 0)

        XCTAssertEqual(m, before)

        // The same thing said of the only tab on the strip.
        var single = filled(1)
        let only = single.rows[0][0]

        single.move(id: only.id, toRow: 1, at: 0)

        XCTAssertEqual(single.rows.map(\.count), [1])
        XCTAssertEqual(single.rows[0][0].id, only.id)
    }

    /// **Settled: while rows were derived a move could not change how many rows
    /// there were**, since the count followed from the number of tabs. A row is
    /// the reader's again and exists because it holds tabs, so the last one
    /// leaving takes the row with it rather than stranding a gap.
    func testDraggingTheLastTabOutOfARowTakesTheRowWithIt() {
        var m = arranged([2, 1])
        let lone = m.rows[1][0]

        m.move(id: lone.id, toRow: 0, at: 0)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.rows[0].first?.id, lone.id)
        XCTAssertEqual(m.tabs.count, 3)
    }

    /// **Settled: while rows were derived this clamped to the end of the
    /// order**, on the reasoning that a row was only an offset and "below
    /// everything" was a legible ask. It still is, and one past the last row is
    /// how it is said — anything further is a caller working from a stale row
    /// count, and inventing the rows in between would fill the strip with gaps
    /// nobody asked for.
    func testMovingToARowPastTheEndIsIgnored() {
        var m = arranged([2, 2])
        let before = m

        m.move(id: m.rows[0][0].id, toRow: 9, at: 0)

        XCTAssertEqual(m, before)
    }

    // MARK: - Reopening

    func testReopeningReturnsATabToItsOriginalRow() {
        var m = arranged([4, 2])
        let fromSecondRow = m.rows[1][1]

        m.close(id: fromSecondRow.id)
        m.reopen(url: fromSecondRow.url, preferredRow: 1)

        XCTAssertEqual(m.rows.map(\.count), [4, 2])
        XCTAssertEqual(m.rows[1].last?.path, fromSecondRow.path)
    }

    /// A row that emptied took its position with it, and inserting one back into
    /// the middle would move every tab the reader has looked at since. So a
    /// vanished row gets the end of the strip rather than a row of its own —
    /// which is also the answer for a persisted row number that has since gone
    /// out of range.
    func testReopeningIntoAVanishedRowAppendsToTheLastRow() {
        var m = arranged([4, 1])
        let onlyTabInSecondRow = m.rows[1][0]

        m.close(id: onlyTabInSecondRow.id)
        XCTAssertEqual(m.rows.count, 1, "precondition: the row is gone")

        m.reopen(url: onlyTabInSecondRow.url, preferredRow: 1)

        XCTAssertEqual(m.rows.map(\.count), [5], "no row was recreated for it")
        XCTAssertEqual(m.tabs.last?.path, onlyTabInSecondRow.path)
    }

    func testReopeningIntoAnEmptyStripStartsARow() {
        var m = FileTabStripModel()
        m.reopen(url: url("a.swift"), preferredRow: 3)

        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.tabs.count, 1)
    }

    // MARK: - Restoring

    /// **Settled: this asserted flattening while rows were derived**, on the
    /// grounds that a persisted break described a window which might not be this
    /// size. Nothing re-breaks a row now, so the rows in the file are the
    /// reader's grouping and the only copy of it. Flattening would hand back one
    /// row and lose the arrangement — which is most of what a named set is.
    func testRestoringHonoursTheRowsItWasGiven() {
        var m = FileTabStripModel()

        m.restore(rows: [[url("a.swift")], [url("b.swift"), url("c.swift")]])

        XCTAssertEqual(
            m.rows.map { $0.map(\.url.lastPathComponent) },
            [["a.swift"], ["b.swift", "c.swift"]],
            "the break written between a and b is honoured"
        )
        XCTAssertEqual(
            m.tabs.map(\.url.lastPathComponent),
            ["a.swift", "b.swift", "c.swift"]
        )
    }

    /// **Settled twice over.** A long row survived a restore originally, because
    /// the soft limit governed only where new tabs landed; then it came back
    /// broken at whatever capacity was in force. Nothing breaks a row at all
    /// now, so ten tabs written as one row are ten tabs in one row — however
    /// narrow the strip that shows them, since narrowness is the label's problem.
    func testRestoringKeepsALongRowInOneRow() {
        var m = FileTabStripModel()
        let many = (0..<10).map { url("f\($0).swift") }

        m.restore(rows: [many])

        XCTAssertEqual(m.rows.map(\.count), [10])
        XCTAssertEqual(
            m.tabs.map(\.url.lastPathComponent),
            many.map(\.lastPathComponent),
            "and in the order they were written"
        )
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

    // MARK: - Whether a step has anywhere to go

    /// **The reported bug.** A tab alone in the last row refused to step back,
    /// because the host asked whether it had a neighbour *in its row* — one
    /// answer for both directions. A key equivalent whose menu item is disabled
    /// is a system beep, so it read as broken rather than as nothing to do.
    func testALoneTabInTheLastRowCanStillStepBack() {
        var model = arranged([3, 1])
        model.select(id: model.rows[1][0].id)

        XCTAssertTrue(
            model.canSelectPrevious,
            "the tab before it is the last one of the row above"
        )
        XCTAssertFalse(model.canSelectNext, "it is the end of the order")
    }

    /// Asked per direction, so the two ends answer differently rather than both
    /// being gated on one fact.
    func testTheTwoEndsOfTheOrderRefuseOnlyTheirOwnDirection() {
        var model = arranged([2, 2])
        model.select(id: model.rows[0][0].id)
        XCTAssertFalse(model.canSelectPrevious)
        XCTAssertTrue(model.canSelectNext)

        model.select(id: model.rows[1][1].id)
        XCTAssertTrue(model.canSelectPrevious)
        XCTAssertFalse(model.canSelectNext)
    }

    func testATabInTheMiddleCanGoBothWays() {
        var model = arranged([3, 3])
        model.select(id: model.rows[1][1].id)

        XCTAssertTrue(model.canSelectPrevious)
        XCTAssertTrue(model.canSelectNext)
    }


    // MARK: - Navigating

    /// **Kept from the round where rows were derived, though for a new reason.**
    /// The break belongs to the reader now, not to the window — but the tab
    /// visually to the left of a row's first tab is still the last tab of the row
    /// above, so a step that stopped at a row edge would refuse to go somewhere
    /// the reader can see. Staying inside a column is what the row keystrokes
    /// are for.
    func testStepsCrossARowBreakRatherThanStoppingAtIt() {
        var m = arranged([3, 3])
        m.select(id: m.rows[1][0].id)

        m.selectPrevious()
        XCTAssertEqual(
            m.selectedID, m.rows[0][2].id, "up and over to the row above"
        )

        m.selectNext()
        XCTAssertEqual(
            m.selectedID, m.rows[1][0].id, "and back down again"
        )
    }

    /// The first and last tab on the strip are the only two places a horizontal
    /// step has nothing to move to. No wrap, matching the view cyclers in both
    /// apps.
    func testStepsStopAtTheTwoRealEnds() {
        var m = arranged([3, 3])

        m.select(id: m.tabs[0].id)
        m.selectPrevious()
        XCTAssertEqual(m.selectedID, m.tabs[0].id, "no wrap at the first tab")

        m.select(id: m.tabs[5].id)
        m.selectNext()
        XCTAssertEqual(m.selectedID, m.tabs[5].id, "and none at the last")
    }

    func testStepsBetweenRowsKeepTheColumn() {
        var m = arranged([3, 3, 1])
        m.select(id: m.rows[0][1].id)

        m.selectNextRow()

        XCTAssertEqual(m.selectedID, m.rows[1][1].id)
    }

    func testSteppingUpARowKeepsTheColumn() {
        var m = arranged([3, 3, 1])
        m.select(id: m.rows[1][2].id)

        m.selectPreviousRow()

        XCTAssertEqual(m.selectedID, m.rows[0][2].id)
    }

    /// A reader pressing down expects to arrive somewhere; the nearest tab is a
    /// better answer than refusing to move, and a short row should not swallow
    /// the keystroke.
    func testSteppingIntoAShorterRowClampsToItsEnd() {
        var m = arranged([4, 1])
        m.select(id: m.rows[0][2].id)

        m.selectNextRow()

        XCTAssertEqual(m.selectedID, m.rows[1][0].id)
    }

    /// Clamping is for a row that exists and is short. There is no row past the
    /// last one, so there is nothing to clamp to and the keystroke is the one
    /// thing that does get swallowed.
    func testSteppingPastTheLastRowStaysPut() {
        var m = filled(3)
        m.select(id: m.rows[0][1].id)
        let before = m.selectedID

        m.selectNextRow()

        XCTAssertEqual(m.selectedID, before)
    }

    func testSteppingAboveTheFirstRowStaysPut() {
        var m = arranged([4, 1])
        m.select(id: m.rows[0][1].id)
        let before = m.selectedID

        m.selectPreviousRow()

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

    /// Rows top to bottom, tabs left to right. This is the order a review groups
    /// its files by and the order the rows are persisted in, so it is a
    /// wire-format concern as much as a visual one. Rows being the stored thing,
    /// they are what defines it — which is why a drag across rows is also a
    /// change to this order.
    func testTabOrderReadsRowsThenColumns() {
        var m = arranged([2, 2])
        let ids = m.tabs.map(\.id)

        m.move(id: ids[0], toRow: 1, at: 0)

        XCTAssertEqual(
            m.tabs.map(\.id), m.rows[0].map(\.id) + m.rows[1].map(\.id)
        )
        XCTAssertEqual(m.tabs.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
    }
}
