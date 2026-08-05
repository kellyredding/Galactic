import AppKit
import SwiftUI

/// The ⌘/ cheat sheet: every keystroke a host answers to, grouped by context,
/// filtered by a fuzzy search field.
///
/// An in-window overlay rather than a panel — see `CheatSheetPresenter` for
/// why, and for how a host mounts this.
///
/// Rows that are not usable right now are dimmed, never hidden or filtered
/// out: the sheet is a reference first, so its job is to show what exists and
/// let the dimming say what is live. Availability comes from the snapshot the
/// presenter took as the sheet opened, not from live state.
public struct CheatSheetView: View {
    @ObservedObject private var presenter: CheatSheetPresenter
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    @State private var listContentHeight: CGFloat = 0

    private static let cardWidth: CGFloat = 660
    private static let inactiveOpacity: CGFloat = 0.45
    /// How tall the rows may get before they scroll instead.
    private static let listMaxHeight: CGFloat = 560

    /// The sheet a host mounts: the shared presenter, which is the one the
    /// chord and the menu item toggle.
    ///
    /// Two initialisers rather than one with a default, and the reason is a
    /// language rule rather than a design choice: a default argument
    /// expression is read in a nonisolated context whatever the initialiser's
    /// own isolation, so `= .shared` cannot name main-actor state. Reading it
    /// in the body can. `@MainActor` costs a caller nothing — a host builds
    /// this inside a view body, which is already there.
    @MainActor
    public init() {
        self.presenter = .shared
    }

    /// Injected, for a preview or a test that wants a presenter of its own —
    /// the same arrangement `FindBarView` uses for its controller.
    public init(presenter: CheatSheetPresenter) {
        self.presenter = presenter
    }

    public var body: some View {
        ZStack {
            scrim
            card
        }
        .onAppear { searchFocused = true }
        .onDisappear {
            // Drop this sheet's own claim before handing the keyboard on.
            // While the binding reads true SwiftUI believes focus belongs to
            // the field it is tearing down, and clears first responder to be
            // rid of it — which is what undid an earlier restore that ran
            // inside `dismiss`, a pass too soon.
            searchFocused = false
            presenter.restoreFocus()
        }
    }

    /// Click-anywhere-to-dismiss backdrop.
    private var scrim: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
    }

    private var card: some View {
        // Resolved once. Every read runs the whole filter over every row, and
        // the header needs the counts the same pass produces, so asking twice
        // per body pass searched the sheet twice for one frame.
        let listing = self.listing
        return VStack(spacing: 0) {
            header(matched: listing.matched, total: listing.total)
            Divider()
            if listing.sections.isEmpty {
                emptyState
            } else {
                list(listing.sections)
            }
        }
        .frame(width: Self.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 30, y: 10)
    }

    private func header(matched: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search shortcuts", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                // Enter should not beep or submit anything — the field only
                // filters.
                .onSubmit {}
            if !query.isEmpty {
                // The matched count against the whole sheet, so a short list
                // reads as "the query is narrow" rather than "the sheet is
                // broken".
                Text("\(matched) of \(total)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                clearButton
            }
            Text("esc")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Clears the query.
    ///
    /// A plain button with its own cursor tracking rather than a host's
    /// icon-button component: the sheet is the only thing here that needs one,
    /// and borrowing a host's would make this package depend on chrome it does
    /// not own. The one visible difference from what the host drew: no hover
    /// circle behind the glyph.
    private var clearButton: some View {
        Button { query = "" } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear the search")
        .onHover { inside in
            // The affordance is mostly the cursor — the same reason
            // `KeystrokeRecorder` sets this inline rather than styling a
            // button that looks like one.
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private var emptyState: some View {
        // Two sentences because the seam makes two things possible. An
        // unwired `sectionsProvider` yields no rows at all, and reporting
        // that as "nothing matches ''" would send a host looking at its
        // query handling instead of its wiring.
        Text(query.isEmpty
            ? "No shortcuts to show"
            : "No shortcuts match “\(query)”")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    /// A plain `VStack`, deliberately not lazy. A sheet is a fixed few dozen
    /// rows, so laziness buys nothing measurable, and it costs the whole class
    /// of recycling bug that a duplicated row identity produces — rows landing
    /// under the wrong header and blank gaps where the list believed it had
    /// already built something.
    private func list(_ sections: [MatchedSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { group in
                        sectionHeader(id: group.id, title: group.title)
                        ForEach(group.rows) { matched in
                            self.row(matched)
                        }
                    }
                }
                .padding(.bottom, 12)
                // A scroll view takes whatever height it is offered, so the
                // card stood at its cap however few rows were in it — and a
                // stack with nothing flexible in it centres, which slid the
                // search field to the middle of a mostly empty card.
                // Measuring the rows lets the card end where they do, up to
                // the cap.
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ContentHeightKey.self,
                            value: geometry.size.height)
                    }
                )
            }
            .frame(height: listHeight)
            .onPreferenceChange(ContentHeightKey.self) {
                listContentHeight = $0
            }
            .onAppear {
                // Open where the user already is, if the host marked a
                // section. Only on first appear — doing it as the query
                // changes would yank the list around mid-search. First match
                // wins, so several marked sections degrade to the earliest
                // rather than fighting.
                if let opening = presenter.sections.first(
                    where: \.isOpening
                ) {
                    proxy.scrollTo(opening.id, anchor: .top)
                }
            }
        }
    }

    /// The rows' own height, capped — and the cap itself until they have been
    /// measured, so the first frame opens full-size rather than collapsed.
    private var listHeight: CGFloat {
        listContentHeight <= 0
            ? Self.listMaxHeight
            : min(listContentHeight, Self.listMaxHeight)
    }

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func sectionHeader(id: String, title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 16).padding(.bottom, 6)
            .id(id)
    }

    private func row(_ matched: MatchedRow) -> some View {
        let row = matched.row
        let hit = matched.hit
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CheatSheetHighlight.highlighted(row.keys, hit.keysOffsets))
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.08))
                )
                .frame(minWidth: 74, alignment: .leading)

            Text(CheatSheetHighlight.highlighted(row.label, hit.labelOffsets))
                .font(.system(size: 13))

            Spacer(minLength: 8)

            if !row.condition.isEmpty {
                Text(CheatSheetHighlight.highlighted(
                    row.condition, hit.conditionOffsets))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .opacity(row.isActive ? 1 : Self.inactiveOpacity)
    }

    // MARK: - Filtering

    /// One row paired with where the query landed in it. The row itself is the
    /// host's value and carries its own identity; this only adds the hit.
    private struct MatchedRow: Identifiable {
        var id: String { row.id }
        let row: CheatSheetRow
        let hit: CheatSheetSearch.Hit
    }

    private struct MatchedSection: Identifiable {
        let id: String
        let title: String
        let rows: [MatchedRow]
    }

    /// The whole sheet for the current query: its sections, how many rows the
    /// query kept, and how many exist at all — so the count can say "N of M"
    /// without searching a second time to find M.
    private struct Listing {
        let sections: [MatchedSection]
        let matched: Int
        let total: Int
    }

    /// Sections in the order the host supplied them, each holding its matching
    /// rows. A section with no matches is dropped so the sheet never shows a
    /// bare header.
    ///
    /// Within a section, rows keep the order the host gave them rather than
    /// sorting by score: a host groups related chords together on purpose, and
    /// reshuffling them by match quality would scatter that grouping the moment
    /// a query touched it. Highlighting is what tells the reader why a row is
    /// in the list, which is the job ranking would otherwise do.
    ///
    /// What a query may match is `CheatSheetSearch`'s to decide. Note the one
    /// thing added here: the row's own glyphs, spelled out, because none of
    /// "⇧⌘⌫" can be typed into the field. Derived rather than asked of the
    /// host, so a spelling cannot fall out of step with the keys on the row.
    private var listing: Listing {
        var groups: [MatchedSection] = []
        var matched = 0
        var total = 0

        // Searched per section rather than over one flattened list. The
        // matcher carries no state between rows, so the two are equivalent —
        // and rows arrive already grouped now, so flattening only to regroup
        // afterwards would be work with nothing behind it.
        for section in presenter.sections {
            total += section.rows.count

            let hits = CheatSheetSearch.hits(
                section.rows.map { row in
                    CheatSheetSearch.Candidate(
                        label: row.label,
                        keys: row.keys,
                        section: section.title,
                        condition: row.condition,
                        aliases: row.aliases + " "
                            + CheatSheetGlyphs.spelled(row.keys))
                },
                query: query)

            let kept = zip(section.rows, hits).compactMap {
                row, hit -> MatchedRow? in
                guard let hit else { return nil }
                return MatchedRow(row: row, hit: hit)
            }
            matched += kept.count
            guard !kept.isEmpty else { continue }
            groups.append(MatchedSection(
                id: section.id, title: section.title, rows: kept))
        }

        return Listing(sections: groups, matched: matched, total: total)
    }
}
