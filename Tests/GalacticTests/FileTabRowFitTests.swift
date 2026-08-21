import AppKit
import XCTest

@testable import Galactic

/// How a row's width is divided among its tabs.
final class FileTabRowFitTests: XCTestCase {

    private let font = FileTabRowFit.font(ofSize: 11)
    private let spacing: CGFloat = 3

    private func candidate(
        _ tiers: [String], chrome: CGFloat = 29
    ) -> FileTabRowFit.Candidate {
        FileTabRowFit.Candidate(id: UUID(), tiers: tiers, chrome: chrome)
    }

    private func fit(
        _ candidates: [FileTabRowFit.Candidate], available: CGFloat
    ) -> [FileTabRowFit.Sized] {
        FileTabRowFit.fit(
            candidates, available: available, spacing: spacing, font: font
        )
    }

    private func total(_ sized: [FileTabRowFit.Sized]) -> CGFloat {
        sized.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, sized.count - 1))
    }

    // MARK: - Spending the row

    /// The reported bug: a row with room to spare left it unspent, so three
    /// short filenames in a wide strip read as squashed.
    func testARowWithRoomToSpareSpendsAllOfIt() {
        let sized = fit(
            [
                candidate(["a/TODO.md", "TODO.md"]),
                candidate(["b/README.md", "README.md"]),
                candidate(["c/main.swift", "main.swift"]),
            ],
            available: 900
        )

        XCTAssertEqual(total(sized), 900, accuracy: 0.5)
    }

    /// Evenly, so a tab's width does not depend on where in the row it sits —
    /// the same file would otherwise be a different size for having been opened
    /// later.
    func testTheSpareRoomIsSharedRatherThanGivenToOneTab() {
        let sized = fit(
            [
                candidate(["TODO.md"]),
                candidate(["TODO.md"]),
                candidate(["TODO.md"]),
            ],
            available: 900
        )

        XCTAssertEqual(Set(sized.map(\.width)).count, 1)
    }

    // MARK: - Choosing labels

    func testAWideRowBuysEveryTabItsWidestLabel() {
        let sized = fit(
            [
                candidate(["src/models/user.rb", "user.rb"]),
                candidate(["src/views/index.erb", "index.erb"]),
            ],
            available: 900
        )

        XCTAssertEqual(
            sized.map(\.label), ["src/models/user.rb", "src/views/index.erb"]
        )
    }

    /// The narrowest tab that can afford an upgrade takes it, which is not the
    /// same as the first one.
    ///
    /// Walking the row in order was the obvious loop and it front-loads: the
    /// first tab buys its whole path, leaves nothing, and the rest stay at their
    /// filename — so a tab's label depended on where in the row it sat, and
    /// reordering the strip changed what the tabs said.
    func testTheNarrowestTabIsFedFirstRatherThanTheLeftmost() {
        // Both tabs offer the same two labels, so the upgrade costs the same
        // either way. The left one starts wider purely through its chrome, and
        // the row has room for exactly one upgrade — so which tab gets it is
        // the rule under test and nothing else.
        let wide = "aaaaaaaaaaaaaaaa"
        let narrow = "aa"
        let wideWidth = FileTabRowFit.width(of: wide, font: font)
        let narrowWidth = FileTabRowFit.width(of: narrow, font: font)

        let left = FileTabRowFit.Candidate(
            id: UUID(), tiers: [wide, narrow], chrome: 100
        )
        let right = FileTabRowFit.Candidate(
            id: UUID(), tiers: [wide, narrow], chrome: 20
        )
        let room =
            (narrowWidth + 100) + (narrowWidth + 20) + (wideWidth - narrowWidth)

        let sized = fit([left, right], available: room + spacing)

        XCTAssertEqual(
            sized[1].label, wide,
            "the starved tab on the right was fed"
        )
        XCTAssertEqual(
            sized[0].label, narrow,
            "walking the row in order would have spent it on this one instead"
        )
    }

    // MARK: - Crowded

    /// A crowded row divides what it has and lets the labels truncate. A tab
    /// pushed past the end of the strip would be unreachable rather than merely
    /// small.
    func testACrowdedRowDividesAndTruncatesRatherThanOverflowing() {
        let candidates = (0..<12).map { _ in candidate(["averylongname.swift"]) }

        let sized = fit(candidates, available: 400)

        XCTAssertLessThanOrEqual(total(sized), 400 + 0.5)
        XCTAssertTrue(sized.allSatisfy { $0.label == "averylongname.swift" })
    }

    func testAnEmptyRowFitsNothing() {
        XCTAssertTrue(fit([], available: 400).isEmpty)
    }

    /// Before the first measurement the strip has no width, and a row still has
    /// to answer something rather than trapping on a divide.
    func testNoWidthYetStillAnswers() {
        let sized = fit([candidate(["a.rb"]), candidate(["b.rb"])], available: 0)

        XCTAssertEqual(sized.count, 2)
        XCTAssertTrue(sized.allSatisfy { $0.width > 0 })
    }
}
