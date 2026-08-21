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

        // Every tier's width up front: the label as drawn, plus what the tab
        // costs around it — and **sorted by that width**, not trusted to arrive
        // in order. The upgrade loop below assumes the tier before is the wider
        // one, and a proportional font does not rank by character count:
        // `p/kajabi/w/api.rb` and `p/k/workers/api.rb` have the same length and
        // different widths. Sorting here means the caller can offer its tiers in
        // whatever order says something, and only this has to know which is
        // bigger.
        let tiers: [[(label: String, width: CGFloat)]] = candidates.map {
            candidate in
            candidate.tiers
                .map { (label: $0, width: width(of: $0, font: font) + candidate.chrome) }
                .sorted { $0.width > $1.width }
        }
        let widths: [[CGFloat]] = tiers.map { $0.map(\.width) }

        // **No width yet means unmeasured, not zero room.** The strip has no
        // size until its first layout pass, and dividing that among the tabs
        // gives every one of them nothing — a strip of invisible tabs for a
        // frame. Their narrowest label is the honest answer to a question that
        // has not been asked yet.
        guard available > 0 else {
            return candidates.enumerated().map { index, candidate in
                Sized(
                    id: candidate.id,
                    label: tiers[index].last?.label ?? "",
                    width: widths[index][widths[index].count - 1]
                )
            }
        }

        let gaps = spacing * CGFloat(candidates.count - 1)
        let room = max(0, available - gaps)

        // Start everyone at their narrowest and buy upgrades with what is left.
        // Starting wide and cutting back would need a rule for whose label to
        // take away; starting narrow only needs a rule for whose to improve.
        var chosen = widths.map { max(0, $0.count - 1) }
        var total = zip(widths, chosen).reduce(CGFloat.zero) { $0 + $1.0[$1.1] }

        // **The narrowest tab that can afford an upgrade takes it**, rather than
        // walking the row in order. Order was the obvious loop and it front-loads:
        // the first tab buys its whole path, leaves nothing, and the rest stay at
        // their filename — so a tab's label depended on where in the row it sat,
        // and reordering the strip changed what the tabs said. Feeding the most
        // starved one first cannot do that.
        while true {
            var pick: Int?
            var starvest = CGFloat.greatestFiniteMagnitude
            for index in candidates.indices where chosen[index] > 0 {
                let delta =
                    widths[index][chosen[index] - 1] - widths[index][chosen[index]]
                guard total + delta <= room else { continue }
                let current = widths[index][chosen[index]]
                if current < starvest {
                    starvest = current
                    pick = index
                }
            }
            guard let index = pick else { break }
            let next = chosen[index] - 1
            total += widths[index][next] - widths[index][chosen[index]]
            chosen[index] = next
        }

        // Still over, so even the narrowest labels do not all fit. Divide what
        // there is and let them truncate. **No floor**: a floor is what makes a
        // row overflow, and a tab pushed off the end of the strip is unreachable
        // rather than merely small. Shrinking has no bottom for the same reason
        // the row is the only cap — the reader adds a row or closes a tab.
        if total > room {
            let share = room / CGFloat(candidates.count)
            return candidates.enumerated().map { index, candidate in
                Sized(
                    id: candidate.id,
                    label: tiers[index].last?.label ?? "",
                    width: min(share, widths[index][chosen[index]])
                )
            }
        }

        // Whatever is unspent goes out evenly, so the row is used rather than
        // ending early. Once every label is at its widest tier — the whole path,
        // relative to the root — there is nothing further to *show*, and the
        // extra goes into the pills themselves rather than beside them: a wider
        // pill is the strip using its row, dead space around a content-sized
        // pill is just a gap with a border drawn in the middle of it.
        //
        // Evenly, not to the last tab: growing one of them would make a width
        // depend on its position, so the same file would be a different size for
        // having been opened later.
        //
        // **Only safe because the row reports the width it was offered rather
        // than the width its tabs add up to** — see `FileTabRowLayout`. Spending
        // the last point of a width measured *from* the content closes a layout
        // loop, and it hangs rather than misbehaves: 23,121 frames of recursive
        // `-[NSView _layoutSubtreeWithOldSize:]` at ~80% CPU when this row was a
        // stack.
        let spare = max(0, room - total) / CGFloat(candidates.count)

        return candidates.enumerated().map { index, candidate in
            Sized(
                id: candidate.id,
                label: tiers[index][chosen[index]].label,
                width: widths[index][chosen[index]] + spare
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
