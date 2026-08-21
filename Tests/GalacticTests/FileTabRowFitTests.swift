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

    /// A tab is as wide as its label needs and no wider — `min(content, row)`,
    /// with the row as the only cap.
    ///
    /// Handing the leftover out as padding was tried and is wrong twice over: it
    /// grows the pill without growing the label, so a tab claims to have more to
    /// say than it does; and spending a width that was measured from the content
    /// closes a layout loop that hangs the app. What fills a row is the labels
    /// growing into it.
    func testATabIsNoWiderThanItsLabelNeeds() {
        let sized = fit(
            [
                candidate(["TODO.md"]),
                candidate(["README.md"]),
            ],
            available: 900
        )

        let expected = [
            FileTabRowFit.width(of: "TODO.md", font: font) + 29,
            FileTabRowFit.width(of: "README.md", font: font) + 29,
        ]
        XCTAssertEqual(sized.map(\.width), expected)
        XCTAssertLessThan(total(sized), 900, "the row keeps what it did not need")
    }

    /// And the row is the cap: a label wider than the row it sits in is cut to
    /// the row rather than running off the end of the strip.
    func testTheRowCapsATabThatWantsMore() {
        let sized = fit([candidate(["a/very/long/path/to/a/file.swift"])], available: 120)

        XCTAssertLessThanOrEqual(sized[0].width, 120)
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

    // MARK: - Whether the label on screen is the whole story

    /// What the tooltip is gated on. A tab showing its full label has nothing
    /// hidden, so hovering it must reveal nothing.
    func testATabWithRoomForItsFullLabelIsNotShrunken() {
        let sized = fit(
            [candidate(["src/models/user.rb", "s/m/user.rb"])], available: 600
        )

        XCTAssertEqual(sized.first?.label, "src/models/user.rb")
        XCTAssertEqual(sized.first?.full, "src/models/user.rb")
        XCTAssertFalse(sized.first?.isShrunken ?? true)
    }

    /// And when the row could only afford a narrower tier, the full one is
    /// carried alongside it — which is what the tooltip shows.
    func testATabForcedToANarrowerTierReportsTheFullLabel() {
        let sized = fit(
            [
                candidate(["src/models/user.rb", "s/m/user.rb"]),
                candidate(["lib/workers/api.rb", "l/w/api.rb"]),
            ],
            available: 150
        )

        for entry in sized {
            XCTAssertTrue(entry.isShrunken, "\(entry.label) had to give up folders")
            XCTAssertNotEqual(entry.label, entry.full)
        }
        XCTAssertEqual(sized.first?.full, "src/models/user.rb")
    }

    /// The other way a label falls short: one tier and not enough room for it,
    /// so it is truncated rather than downgraded. `label == full` here, and the
    /// width is what says the reader cannot see all of it.
    func testASingleTierTooWideForItsRowIsStillShrunken() {
        let sized = fit(
            [candidate(["a-very-long-file-name-indeed.swift"])], available: 90
        )

        XCTAssertEqual(sized.first?.label, sized.first?.full)
        XCTAssertTrue(
            sized.first?.isShrunken ?? false,
            "the only tier there is does not fit, which the reader can see"
        )
    }

    /// The full label is the widest tier, not a path spelled independently.
    /// Spelling it separately is what let a tooltip name a file differently
    /// than the tab it belonged to.
    func testTheFullLabelIsTheWidestTierItWasOffered() {
        let sized = fit([candidate(["w/x/y/z.rb", "wide/x/y/z.rb"])], available: 40)

        XCTAssertEqual(
            sized.first?.full, "wide/x/y/z.rb",
            "widest by drawn width, whatever order the tiers arrived in"
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
