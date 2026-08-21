import AppKit
import SwiftUI

/// The open files, drawn as wrapping rows above the reader.
///
/// Observes the `FileSet` directly rather than being handed values, because the
/// strip and the note counts are the live-moving parts of this feature — the
/// agent inbox learned that a count read through a presenter shows whatever it
/// said when the surface opened.
///
/// **No animation may reach this view.** Every label goes through
/// `ViewThatFits`, which re-measures constantly, and an ambient animation on the
/// transaction is the mechanism behind the sliding-tab bug fixed in `690b2ef`.
/// That is why nothing here sets one, and why a caller must not wrap it in one
/// either.
///
/// Reordering respects that rule rather than working around it. A dragged tab
/// follows the pointer by `offset`, which is geometry read from a gesture and
/// carries no curve at all; the tabs it displaces change places outright. The
/// alternative — easing the neighbours into their new slots — is a curve on the
/// transaction in a view whose frames genuinely re-measure, which is the exact
/// shape that once left rows sliding back and forth forever. It would look
/// slightly better and is not worth finding out again.
public struct FileTabStripView: View {

    @ObservedObject private var set: FileSet

    @State private var stripWidth: CGFloat = 0
    @State private var drag: FileTabDrag?

    private let onSelect: (FileTab.ID) -> Void
    private let onClose: (FileTab.ID) -> Void

    /// Read this file from disk again, replacing what was frozen at open.
    ///
    /// In the context menu rather than as a button in the strip: it is the rare
    /// one of these actions, it destroys notes, and a row of tabs has no width to
    /// spare for an affordance nobody reaches for twice a day.
    private let onReload: (FileTab.ID) -> Void

    /// Take the whole arrangement the drag ended on.
    ///
    /// One arrangement rather than one tab's destination, because a tab crossing
    /// rows changes two rows at once and a single move left the host
    /// reconstructing indices against a strip that had already shifted.
    ///
    /// Defaulted away, so a host that has not wired rearranging gets a strip that
    /// simply does not drag rather than one that drags and silently drops the
    /// result on the floor.
    private let onRearrange: (([[FileTab.ID]]) -> Void)?

    public init(
        set: FileSet,
        onSelect: @escaping (FileTab.ID) -> Void,
        onClose: @escaping (FileTab.ID) -> Void,
        onReload: @escaping (FileTab.ID) -> Void,
        onRearrange: (([[FileTab.ID]]) -> Void)? = nil
    ) {
        self.set = set
        self.onSelect = onSelect
        self.onClose = onClose
        self.onReload = onReload
        self.onRearrange = onRearrange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            let widths = sized
            ForEach(Array(displayRows.enumerated()), id: \.offset) { _, row in
                // A layout rather than a stack, because a stack's size is its
                // content and this row spends every point it is offered — see
                // `FileTabRowLayout` for the loop that closes.
                FileTabRowLayout(
                    widths: row.map {
                        widths[$0.id]?.width ?? Metrics.assumedTabWidth
                    },
                    spacing: Metrics.tabSpacing
                ) {
                    ForEach(row) { tab in tabView(tab, widths) }
                }
            }

            // Where the row would be, shown only while a drag is asking for
            // one. A drop target nobody can see is a feature nobody finds, and
            // this is the only way to make a row — so it has to announce
            // itself rather than being something a reader stumbles into.
            if isProposingNewRow {
                HStack(spacing: Metrics.tabSpacing) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            Color.accentColor.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                        .frame(width: Metrics.assumedTabWidth)
                    Spacer(minLength: 0)
                }
                .frame(height: Metrics.tabHeight)
            }

            // The strip carries no open affordance of its own. It had a `+`
            // wired to the system's file dialog while the picker did not exist
            // yet, and once it did that button was a second way to do one thing
            // — with the worse ergonomics of the two, and taking width from the
            // labels on every row to offer it. Opening is a keystroke.
            if set.tabs.rows.isEmpty {
                HStack(spacing: Metrics.tabSpacing) {
                    Text("No files open — press ⌘T")
                        .font(.system(size: Metrics.fontSize))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(height: Metrics.tabHeight)
            }
        }
        .padding(.horizontal, Metrics.stripPadding)
        .padding(.vertical, Metrics.rowSpacing)
        // **Filled to the parent before anything measures it, and that is load
        // bearing.** Left content-sized, this view's width is the sum of the
        // widths the fit just chose — so measuring it and then handing that
        // measurement back to the fit is a cycle: the fit spends every point it
        // is given, the content grows to match, the next pass measures the
        // larger content and gives it away again. With label widths rounded up,
        // each pass gains a fraction and the layout never converges. It hangs
        // the app rather than looking wrong.
        //
        // A width that comes from the container cannot be moved by what the fit
        // does with it, which is what makes spending all of it safe.
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: Self.space)
        .background(
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) {
                    stripWidth = geometry.size.width
                    // Handed over so a keystroke can ask where the tabs are.
                    // The strip is the only thing that knows this number.
                    set.stripWidth = geometry.size.width
                }
            }
        )
    }

    /// One tab, at the width the fit gave it.
    ///
    /// Broken out because the whole strip in one expression stopped
    /// type-checking in reasonable time once the fit was threaded through it.
    private func tabView(
        _ tab: FileTab, _ widths: [FileTab.ID: FileTabRowFit.Sized]
    ) -> some View {
        let entry = widths[tab.id]
        return FileTabView(
            tab: tab,
            label: entry?.label ?? FileTabLabel.floor(for: tab.url),
            width: entry?.width ?? Metrics.assumedTabWidth,
            root: set.root,
            noteCount: set.noteCount(forPath: tab.path),
            isSelected: set.tabs.selectedID == tab.id,
            onSelect: { onSelect(tab.id) },
            onClose: { onClose(tab.id) },
            onReload: { onReload(tab.id) }
        )
        // A resting tab is a tint and a border over whatever is behind it, which
        // is right until one is dragged across another and you can read both
        // through each other. The base goes on only while it moves, so nothing
        // about the strip at rest changes.
        .background(liftedBackdrop(for: tab.id))
        // Carried by the tab itself rather than by a dragged copy of it.
        .offset(x: offset(for: tab.id))
        // The curve goes on this property, never on the transaction: a
        // transaction curve is inherited by every animatable change in the same
        // pass, which is what once left rows sliding back and forth on a loop
        // with nothing to return them.
        .animation(
            drag?.id == tab.id ? nil : Metrics.slide, value: offset(for: tab.id)
        )
        // Above its neighbours while it is the one moving, so passing over them
        // does not clip it.
        .zIndex(drag?.id == tab.id ? 1 : 0)
        .gesture(dragGesture(for: tab.id))
    }

    // MARK: - Dragging a tab into place

    private func dragGesture(for id: FileTab.ID) -> some Gesture {
        // A threshold, so a click still selects. Below it nothing is a drag and
        // the tap gesture on the tab answers as it always did.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard onRearrange != nil else { return }
                let widths = sized.mapValues(\.width)

                // **Mutated as a local and assigned once.** Reading `@State`
                // back after writing it returns the value from before the write
                // until the next update, so settling the row and then the column
                // through the property meant the second half reasoned about the
                // arrangement the first half had just replaced — which is what
                // locked a tab up the moment it crossed a row. One value, one
                // assignment, no window for the two to disagree.
                var updated: FileTabDrag
                if let drag, drag.id == id {
                    updated = drag
                } else {
                    // Picking a tab up is also choosing it. Rearranging the
                    // strip while looking at a different file is a thing nobody
                    // asked for, and every other way of touching a tab selects
                    // it.
                    if set.tabs.selectedID != id { onSelect(id) }
                    updated = FileTabDrag(
                        id: id,
                        grabX: value.startLocation.x - layoutX(of: id),
                        pointer: value.location,
                        arrangement: set.tabs.rows.map { $0.map(\.id) },
                        metrics: Metrics.drag
                    )
                }
                updated.update(
                    pointer: value.location,
                    widths: widths,
                    stripWidth: stripWidth
                )
                drag = updated
            }
            .onEnded { _ in commitDrag() }
    }

    /// Hand the arrangement over, once.
    private func commitDrag() {
        defer { drag = nil }
        guard let drag, let onRearrange,
            drag.proposal != set.tabs.rows.map({ $0.map(\.id) })
        else { return }
        onRearrange(drag.proposal)
    }

    /// How far a tab is drawn from where the layout put it.
    ///
    /// **Only the dragged one is offset now, and that is the simplification the
    /// proposal bought.** Displaced tabs used to be drawn at the difference
    /// between the slot the drag proposed and the slot the model still had,
    /// because the model was what the strip was laid out from. The strip is laid
    /// out from the proposal, so a displaced tab is already where it belongs and
    /// has nothing to correct.
    ///
    /// What that gives up is the slide: displacement is a layout change again,
    /// and a curve on a layout change in this view is the mechanism behind the
    /// sliding-rows bug. Correct and discrete beat smooth and wrong; the slide
    /// can come back as an animated offset *within* the proposal if it earns it.
    private func offset(for id: FileTab.ID) -> CGFloat {
        guard let drag, drag.id == id else { return 0 }
        return leadingEdge(of: drag) - layoutX(of: id)
    }
    /// Where the dragged tab's leading edge is being asked to sit.
    private func leadingEdge(of drag: FileTabDrag) -> CGFloat {
        drag.leadingEdge(
            widths: sized.mapValues(\.width), stripWidth: stripWidth
        )
    }


    // MARK: - What is on screen, and how wide each of it is

    /// The rows being drawn: the drag's proposal while one is in progress, the
    /// model's otherwise.
    ///
    /// **Drawing the proposal is the point.** The alternative — model on screen,
    /// proposal in the drag's head — is exactly what let the two disagree about
    /// which row a tab was in, and every stuck drag came from that gap.
    private var displayRows: [[FileTab]] {
        guard let drag else { return set.tabs.rows }
        let byID = Dictionary(
            set.tabs.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
        )
        return drag.proposal
            .map { $0.compactMap { byID[$0] } }
            .filter { !$0.isEmpty }
    }

    /// Each tab's chosen label and width, for the arrangement on screen.
    ///
    /// Computed from the arrangement rather than read back from the layout. Read
    /// back, a width described the arrangement of a frame ago — fine while a
    /// drag stayed in one row, and wrong the moment it crossed, because crossing
    /// re-measures every label in both rows at once.
    private var sized: [FileTab.ID: FileTabRowFit.Sized] {
        var result: [FileTab.ID: FileTabRowFit.Sized] = [:]
        for row in displayRows {
            for entry in fit(row) { result[entry.id] = entry }
        }
        return result
    }

    private func fit(_ row: [FileTab]) -> [FileTabRowFit.Sized] {
        // The shared entry point, which navigation also calls — so the tab the
        // keystroke says is below this one is the tab drawn below this one.
        FileTabRowFit.fit(
            row: row,
            root: set.root,
            siblings: set.tabs.tabs.map(\.url),
            noteCount: { set.noteCount(forPath: $0.path) },
            stripWidth: stripWidth
        )
    }

    private func candidate(for tab: FileTab) -> FileTabRowFit.Candidate {
        var tiers = FileTabLabel.tiers(
            for: tab.url, root: set.root, siblings: siblings(excluding: tab)
        )
        // The floor last, so a tab too narrow for any tier still says which file
        // it is. Often already there, when the filename tells them apart.
        let floor = FileTabLabel.floor(for: tab.url)
        if tiers.last != floor { tiers.append(floor) }
        return FileTabRowFit.Candidate(
            id: tab.id, tiers: tiers, chrome: chrome(for: tab)
        )
    }

    /// Everything a tab spends that is not its label.
    private func chrome(for tab: FileTab) -> CGFloat {
        var total = Metrics.tabChrome
        let notes = set.noteCount(forPath: tab.path)
        if notes > 0 {
            total +=
                FileTabRowFit.width(
                    of: "\(notes)",
                    font: FileTabRowFit.font(ofSize: Metrics.badgeFontSize)
                ) + Metrics.badgeChrome
        }
        return total
    }

    private func width(of id: FileTab.ID) -> CGFloat {
        sized[id]?.width ?? Metrics.assumedTabWidth
    }

    private func displayPosition(of id: FileTab.ID) -> (row: Int, column: Int)? {
        for (r, row) in displayRows.enumerated() {
            if let c = row.firstIndex(where: { $0.id == id }) { return (r, c) }
        }
        return nil
    }

    private func geometry(ofRow row: [FileTab.ID]) -> FileTabRowGeometry {
        FileTabRowGeometry(
            widths: row.map(width(of:)),
            spacing: Metrics.tabSpacing,
            leading: Metrics.stripPadding
        )
    }

    private func position(of id: FileTab.ID) -> (row: Int, column: Int)? {
        displayPosition(of: id)
    }

    /// Where a tab's leading edge sits in the arrangement on screen.
    private func layoutX(of id: FileTab.ID) -> CGFloat {
        guard let (row, column) = displayPosition(of: id) else {
            return Metrics.stripPadding
        }
        return geometry(ofRow: displayRows[row].map(\.id)).minX(at: column)
    }
    /// Whether the drag is over the new-row band and a row would actually
    /// appear, which is what the dashed target promises.
    private var isProposingNewRow: Bool {
        drag?.isProposingNewRow(widths: sized.mapValues(\.width)) ?? false
    }


    /// An opaque base and a shadow, for the tab being carried.
    ///
    /// The shadow is what says it is above the row rather than in it, and it is
    /// the reason the base can be flat: lifted things do not need to be brighter
    /// to read as lifted.
    @ViewBuilder
    private func liftedBackdrop(for id: FileTab.ID) -> some View {
        if drag?.id == id {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 4, y: 1)
        }
    }

    private static let space = "galactic.file-tab-strip"

    /// Every other open file, which is what decides whether a bare filename or a
    /// squashed path still tells two tabs apart.
    private func siblings(excluding tab: FileTab) -> [URL] {
        set.tabs.tabs.filter { $0.id != tab.id }.map(\.url)
    }

    enum Metrics {
        static let rowSpacing: CGFloat = 3
        static let tabSpacing: CGFloat = 3
        static let stripPadding: CGFloat = 6
        static let fontSize: CGFloat = 11
        static let tabHeight: CGFloat = 20
        /// What a tab costs around its label: the horizontal padding at both
        /// ends, the gap before the close button, and the button's reserved
        /// place. Measured against the drawn tab rather than guessed, because
        /// the fit pays for it out of the row's width.
        static let tabChrome: CGFloat = 6 + 6 + 4 + 13
        static let badgeFontSize: CGFloat = 9
        /// The note badge's capsule padding and the gap before it.
        static let badgeChrome: CGFloat = 8 + 4

        /// The same numbers, handed to the drag so its arithmetic and this
        /// view's layout cannot drift apart.
        static let drag = FileTabDrag.Metrics(
            tabSpacing: tabSpacing,
            rowSpacing: rowSpacing,
            stripPadding: stripPadding,
            tabHeight: tabHeight,
            newRowMargin: newRowDropMargin
        )
        /// How far below the last row a drop still counts as asking for a new
        /// one. Generous, because the gesture is deliberate and a reader aiming
        /// at empty space below the strip should not have to be precise about
        /// it.
        static let newRowDropMargin: CGFloat = 14
        /// Stands in for a width not yet reported, which is only ever the frame
        /// before the first layout pass. Wrong by a little for one frame beats
        /// zero, which would put every midline in the same place.
        static let assumedTabWidth: CGFloat = 90
        /// Short, because it describes a tab getting out of the way rather than
        /// anything worth watching. Long enough to read as movement instead of a
        /// jump cut.
        static let slide: Animation = .easeOut(duration: 0.14)
    }
}

private struct FileTabView: View {
    let tab: FileTab
    /// What to draw, already chosen and already paid for by `FileTabRowFit`.
    ///
    /// Handed in rather than worked out here, because choosing a label needs to
    /// know what the whole row can afford and a tab can only see itself. That is
    /// the whole reason a `ViewThatFits` per tab could not do it: it picks from
    /// the width the stack proposes, which is a guess made before the leftover
    /// is known.
    let label: String
    /// The width the row's fit gave this tab.
    ///
    /// Applied **inside** the pill rather than around it. Applied outside — on
    /// the view that holds the background and the border — a tab wider than its
    /// label drew a content-sized pill sitting in a pool of dead space, which
    /// reads as a gap with a border in the middle of it rather than as a tab
    /// using its row.
    let width: CGFloat
    /// Only for the context menu's relative-path copy. The label no longer needs
    /// it, since the row's fit resolved that already.
    let root: URL
    let noteCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReload: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private typealias Metrics = FileTabStripView.Metrics

    /// The send bar's green, and deliberately not a green chosen to look like
    /// it. A tab carrying notes and the bar offering to send them are saying one
    /// thing, so they say it in one colour — see `SendBarGreen`.
    private var green: Color {
        Color(SendBarGreen.color(isLight: colorScheme != .dark))
    }

    private var hasNotes: Bool { noteCount > 0 }


    var body: some View {
        HStack(spacing: 4) {
            labelText

            if hasNotes {
                Text("\(noteCount)")
                    .font(.system(size: 9, weight: .bold))
                    // On a filled capsule of the bar's own green, so the count
                    // is white on green wherever the tab is — the grey-on-grey
                    // it replaced was legible only if you already knew it was
                    // there.
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(green))
                    .fixedSize()
            }

            // Reserved rather than conditional: a close button that appears on
            // hover must not widen the tab as it does, or every label re-measures
            // and the strip twitches under the cursor.
            // **No spacer here.** One was tried, to hold the close button
            // against the trailing edge once the pill grew past its label, and
            // it opens a corridor of empty pill between the name and the ×
            // — the wider the pill, the further the × travels from the thing it
            // closes. Every content-sized tab puts it directly after the label,
            // so a filled one does too, and the room the fit could not spend on
            // a longer label simply trails off to the right.
            closeButton
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, 6)
        .frame(width: width, alignment: .leading)
        // No floor and no cap. A tab is as wide as its label wants and as
        // narrow as the row makes it, and the row is the only cap there is.
        //
        // **A hard `minWidth` here is what broke wrapping once**: ten tabs at an
        // 88pt floor demand 907pt whatever they are offered, and an `HStack`
        // that cannot compress below its children's minimums does not wrap, it
        // overflows — so the strip measured its own overflowing content, sized
        // rows from that, and grew. Nothing here may claim a width the row
        // cannot refuse.
        .frame(height: Metrics.tabHeight)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(background))
        )
        // The green wash, under the selection treatment rather than replacing
        // it: a tab can be both selected and carrying notes, and those are two
        // different facts about it.
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(green.opacity(hasNotes ? tintOpacity : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        // The full path, on hover. A tab shows the shortest label that tells it
        // apart, which is the right default and the wrong answer to "which file
        // is this, exactly".
        .help(tab.url.path)
        .contextMenu {
            Button("Copy Path") { copy(tab.url.path) }
            Button("Copy Relative Path") { copy(relativePath) }
            Divider()
            Button("Reread from Disk") { onReload() }
            Button("Close") { onClose() }
        }
    }

    /// The label, at the width the row's fit assigned this tab.
    ///
    /// Truncated at the tail rather than the middle: the head of a filename is
    /// what a reader scans, and middle-truncating a path keeps the folders two
    /// tabs share while cutting away the name that tells them apart.
    private var labelText: some View {
        Text(label)
            .font(.system(size: Metrics.fontSize))
            .foregroundColor(isSelected ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close this file")
    }

    private var background: Double {
        if isSelected { return 0.10 }
        return isHovering ? 0.05 : 0.02
    }

    /// Enough to read as green, little enough to read the label over.
    ///
    /// Stronger on the selected tab, which already carries a grey background the
    /// wash has to survive — an equal tint on both makes the selected annotated
    /// tab the *palest* green in the row, which is backwards.
    private var tintOpacity: Double {
        isSelected ? 0.22 : 0.14
    }

    /// Selection is the border's job, and it had to get stronger once tabs could
    /// be tinted: a 1px grey hairline reads as selection against a plain tab and
    /// disappears against a green one. Green tabs take a green border, so the
    /// selected one is the *saturated* green rather than merely a filled one.
    private var borderColor: Color {
        if isSelected { return hasNotes ? green : Color.primary.opacity(0.28) }
        return hasNotes ? green.opacity(0.35) : .clear
    }

    private var relativePath: String {
        FilePaths.relativePath(of: tab.url, under: root) ?? tab.url.path
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
