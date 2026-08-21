import AppKit

/// How wide each tab in a row is, and which of its labels it can afford.
///
/// **Why this exists rather than a `ViewThatFits` per tab.** That reads well and
/// cannot answer the question: `ViewThatFits` picks the first candidate that fits
/// the width *proposed* to it, and an `HStack` derives that proposal by dividing
/// space among its children before anything knows what the leftover will be. So
/// a tab in a half-empty row is offered a fair share, chooses a label that fits
/// the share, comes out narrower than the share, and nobody reclaims the
/// difference — a row with room to spare showing squashed labels, which is the
/// exact opposite of what the tiers are for. Layout priority does not help; it
/// changes the order space is handed out in, not what each child is told it can
/// have.
///
/// Deciding the widths here also settles a second problem. The drag geometry used
/// to read widths back from the layout, which is fine while a drag stays in one
/// row and wrong the instant it does not: moving a tab between rows re-measures
/// every label in *both* rows, so the numbers the drag was reasoning with
/// described an arrangement that no longer existed. Widths computed from the
/// arrangement are available before the layout happens, so the drag and the
/// screen agree by construction rather than by a frame's luck.
public enum FileTabRowFit {

    /// One tab asking for space.
    public struct Candidate: Equatable {
        public let id: FileTab.ID
        /// Labels this tab would accept, widest first.
        public let tiers: [String]
        /// What everything that is not the label costs: padding, the close
        /// button's reserved place, a note badge when there is one.
        public let chrome: CGFloat

        public init(id: FileTab.ID, tiers: [String], chrome: CGFloat) {
            self.id = id
            self.tiers = tiers
            self.chrome = chrome
        }
    }

    /// One tab's answer.
    public struct Sized: Equatable {
        public let id: FileTab.ID
        public let label: String
        public let width: CGFloat
    }

    /// Narrower than this and a tab is a stub with no word in it, so a row too
    /// crowded to give everyone this much stops dividing and lets the labels
    /// truncate instead. Not a floor on the *tab* — the row is still the only
    /// real cap — a floor on the arithmetic, so dividing by enough tabs cannot
    /// reach zero.
    public static let hardMinimum: CGFloat = 46

    /// The font labels are drawn in. Measuring has to agree with drawing, so
    /// both come from here.
    public static func font(ofSize size: CGFloat) -> NSFont {
        .systemFont(ofSize: size)
    }

    /// Choose a label and a width for every tab in one row.
    ///
    /// - Parameters:
    ///   - candidates: the row's tabs, in order.
    ///   - available: the row's content width, padding already removed.
    ///   - spacing: the gap between two tabs.
    ///   - font: the label font, which must be the one the view draws with.
    public static func fit(
        _ candidates: [Candidate],
        available: CGFloat,
        spacing: CGFloat,
        font: NSFont
    ) -> [Sized] {
        guard !candidates.isEmpty else { return [] }

        let gaps = spacing * CGFloat(candidates.count - 1)
        let room = max(0, available - gaps)

        // Every tier's width up front: the label as drawn, plus what the tab
        // costs around it.
        let widths: [[CGFloat]] = candidates.map { candidate in
            candidate.tiers.map { width(of: $0, font: font) + candidate.chrome }
        }

        // Start everyone at their narrowest and buy upgrades with what is left.
        // Starting wide and cutting back would need a rule for whose label to
        // take first; starting narrow only ever needs a rule for whose to
        // improve, and one step each per pass spreads it evenly.
        var chosen = widths.map { max(0, $0.count - 1) }
        var total = zip(widths, chosen).reduce(CGFloat.zero) { $0 + $1.0[$1.1] }

        var improved = true
        while improved {
            improved = false
            for index in candidates.indices where chosen[index] > 0 {
                let next = chosen[index] - 1
                let delta = widths[index][next] - widths[index][chosen[index]]
                guard total + delta <= room else { continue }
                chosen[index] = next
                total += delta
                improved = true
            }
        }

        // Still over, so the narrowest labels do not all fit. Divide evenly and
        // let them truncate: a row is allowed to be crowded, and a tab pushed
        // out of the strip would be unreachable rather than merely small.
        if total > room {
            let share = max(hardMinimum, room / CGFloat(candidates.count))
            return candidates.enumerated().map { index, candidate in
                Sized(
                    id: candidate.id,
                    label: candidate.tiers.last ?? "",
                    width: min(share, widths[index][chosen[index]])
                )
            }
        }

        // **A row is left with its slack rather than filled, and that is not an
        // oversight.** Once every label is at its widest tier there is nothing
        // more to buy, so a row of short filenames stops early — which reads as
        // squashed tabs even though each is showing everything it has.
        //
        // Spreading the remainder across them was tried and hung the app.
        // MEASURED: the main thread went to 23,121 frames of recursive
        // `-[NSView _layoutSubtreeWithOldSize:]` at 80% CPU, against 955 frames
        // and idle without it. The reason is that this function is handed a
        // width derived from the strip, and the strip's width is derived from
        // what this function returns; spending the last point of it closes that
        // loop, and rounding label widths up means each pass gains a fraction
        // and the layout never settles. Filling the row needs a width that
        // provably cannot move when the fit spends it — pinning the strip to its
        // parent was not enough on its own — and that is its own change with its
        // own measurement, not a line here.
        return candidates.enumerated().map { index, candidate in
            Sized(
                id: candidate.id,
                label: candidate.tiers[chosen[index]],
                width: widths[index][chosen[index]]
            )
        }
    }

    /// A label's drawn width.
    static func width(of label: String, font: NSFont) -> CGFloat {
        // Rounded up, because a fractional point that rounds down truncates a
        // label the fit believed it had paid for.
        (label as NSString)
            .size(withAttributes: [.font: font])
            .width
            .rounded(.up)
    }
}
