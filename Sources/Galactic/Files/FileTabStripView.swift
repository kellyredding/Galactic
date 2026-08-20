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

    @State private var widths: [FileTab.ID: CGFloat] = [:]
    @State private var stripWidth: CGFloat = 0
    @State private var drag: Drag?

    private let onSelect: (FileTab.ID) -> Void
    private let onClose: (FileTab.ID) -> Void

    /// Read this file from disk again, replacing what was frozen at open.
    ///
    /// In the context menu rather than as a button in the strip: it is the rare
    /// one of these actions, it destroys notes, and a row of tabs has no width to
    /// spare for an affordance nobody reaches for twice a day.
    private let onReload: (FileTab.ID) -> Void

    /// Put a tab somewhere else in the strip.
    ///
    /// Defaulted away, so a host that has not wired reordering gets a strip that
    /// simply does not drag rather than one that drags and silently drops the
    /// result on the floor.
    private let onMove: ((FileTab.ID, Int, Int) -> Void)?

    public init(
        set: FileSet,
        onSelect: @escaping (FileTab.ID) -> Void,
        onClose: @escaping (FileTab.ID) -> Void,
        onReload: @escaping (FileTab.ID) -> Void,
        onMove: ((FileTab.ID, Int, Int) -> Void)? = nil
    ) {
        self.set = set
        self.onSelect = onSelect
        self.onClose = onClose
        self.onReload = onReload
        self.onMove = onMove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            ForEach(Array(set.tabs.rows.enumerated()), id: \.offset) {
                index, row in
                HStack(spacing: Metrics.tabSpacing) {
                    ForEach(row) { tab in
                        FileTabView(
                            tab: tab,
                            root: set.root,
                            siblings: siblings(excluding: tab),
                            noteCount: set.noteCount(forPath: tab.path),
                            isSelected: set.tabs.selectedID == tab.id,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) },
                            onReload: { onReload(tab.id) }
                        )
                        .background(frameReporter(for: tab.id))
                        // A resting tab is a tint and a border over whatever is
                        // behind it, which is right until one is dragged across
                        // another and you can read both through each other. The
                        // base goes on only while it moves, so nothing about the
                        // strip at rest changes.
                        .background(liftedBackdrop(for: tab.id))
                        // Carried by the tab itself rather than by a dragged
                        // copy of it. The offset is geometry, never an
                        // animation: the strip's labels are measured by
                        // `ViewThatFits`, and a curve on the transaction is what
                        // once left rows sliding forever.
                        .offset(x: offset(for: tab.id))
                        // Above its neighbours while it is the one moving, so
                        // passing over them does not clip it.
                        .zIndex(drag?.id == tab.id ? 1 : 0)
                        .gesture(dragGesture(for: tab.id))
                    }

                    Spacer(minLength: 0)
                }
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
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(TabWidthsKey.self) { widths = $0 }
        .background(
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) {
                    stripWidth = geometry.size.width
                }
            }
        )
    }

    // MARK: - Dragging a tab into place

    private struct Drag {
        let id: FileTab.ID
        /// Where inside the tab it was picked up, so it does not snap its
        /// leading edge to the cursor.
        let grabX: CGFloat
        var pointer: CGPoint
    }

    private func dragGesture(for id: FileTab.ID) -> some Gesture {
        // A threshold, so a click still selects. Below it nothing is a drag and
        // the tap gesture on the tab answers as it always did.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard onMove != nil else { return }
                if drag?.id != id {
                    // Picking a tab up is also choosing it. Rearranging the
                    // strip while looking at a different file is a thing nobody
                    // asked for, and every other way of touching a tab selects
                    // it.
                    if set.tabs.selectedID != id { onSelect(id) }
                    drag = Drag(
                        id: id,
                        grabX: value.startLocation.x - layoutX(of: id),
                        pointer: value.location
                    )
                } else {
                    drag?.pointer = value.location
                }
                settle()
            }
            .onEnded { _ in drag = nil }
    }

    /// How far the dragged tab is drawn from where the layout put it.
    ///
    /// Against a position computed from the current order rather than one read
    /// back from the layout. A reported frame arrives a pass late, so during the
    /// very update that reorders the strip the offset would be measured against
    /// where the tab used to be — which is a jump of one tab's width, every
    /// time, and is what made this bounce.
    private func offset(for id: FileTab.ID) -> CGFloat {
        guard let drag, drag.id == id else { return 0 }
        return leadingEdge(of: drag) - layoutX(of: id)
    }

    /// Move the dragged tab as far as the pointer has earned, one step at a time.
    ///
    /// **The test is an edge against a neighbour's midline, not a centre against
    /// it.** Dragging right, the tab's trailing edge has to pass the midline of
    /// the tab on its right; dragging left, its leading edge has to pass the
    /// midline of the tab on its left. That asymmetry is the whole point: the two
    /// conditions cannot both hold, so a tab that has just changed places is not
    /// immediately eligible to change back. Comparing a centre to a midline has
    /// no such gap, and the exchange it produces oscillates every frame the
    /// pointer holds still near a boundary.
    ///
    /// Looped, because one frame of a fast drag can earn several places.
    private func settle() {
        guard let drag, let onMove else { return }
        let rows = set.tabs.rows
        guard !rows.isEmpty else { return }

        let row = nearestRow(to: drag.pointer.y, of: rows.count)
        if let current = position(of: drag.id), current.row != row {
            // Changing rows is decided by the pointer alone. There is no
            // midline to earn vertically — the rows are one tab tall, so being
            // over one is the whole of the intent.
            onMove(drag.id, row, slot(for: drag.pointer.x, in: row))
            return
        }

        // Both the position and the widths are re-read after every step, and
        // that is not caution. Held across the loop they describe the row as it
        // was *before* the move, and the reversed condition is then evaluated
        // against the dragged tab's own width sitting in the slot it just left:
        // a wide tab passing a narrow one moved right, immediately read itself
        // as owed a move back, and stayed put. It failed only in that direction
        // and only for that width order, which is what made it look like
        // left-to-right was unimplemented.
        let edge = leadingEdge(of: drag)
        for _ in 0..<rows[row].count {
            guard let current = position(of: drag.id), current.row == row
            else { return }
            guard
                let step = geometry(ofRow: row).step(
                    draggedAt: current.column, leadingEdge: edge
                )
            else { return }
            onMove(drag.id, row, step)
        }
    }

    /// Where the dragged tab's leading edge is being asked to sit.
    ///
    /// Clamped into the strip. Nothing good happens past either end: the tab
    /// leaves the row it belongs to, there is no slot out there to earn, and the
    /// only way back is to drag it in again.
    private func leadingEdge(of drag: Drag) -> CGFloat {
        guard let position = position(of: drag.id) else { return 0 }
        return geometry(ofRow: position.row).clamped(
            leadingEdge: drag.pointer.x - drag.grabX,
            width: width(of: drag.id),
            stripWidth: stripWidth
        )
    }

    // MARK: - Geometry, computed rather than read back

    private func geometry(ofRow row: Int) -> FileTabRowGeometry {
        FileTabRowGeometry(
            widths: set.tabs.rows[row].map(width(of:)),
            spacing: Metrics.tabSpacing,
            leading: Metrics.stripPadding
        )
    }

    /// Where a tab's leading edge sits, from the order and the widths.
    ///
    /// Only the widths come from the layout, and they change when a label picks a
    /// different tier rather than when the order changes — so they are stable
    /// across exactly the thing a drag does.
    private func layoutX(of id: FileTab.ID) -> CGFloat {
        guard let position = position(of: id) else { return Metrics.stripPadding }
        return geometry(ofRow: position.row).minX(at: position.column)
    }

    private func width(of tab: FileTab) -> CGFloat { width(of: tab.id) }

    private func width(of id: FileTab.ID) -> CGFloat {
        widths[id] ?? Metrics.assumedTabWidth
    }

    private func position(of id: FileTab.ID) -> (row: Int, column: Int)? {
        for (row, tabs) in set.tabs.rows.enumerated() {
            if let column = tabs.firstIndex(where: { $0.id == id }) {
                return (row, column)
            }
        }
        return nil
    }

    /// Which row a vertical position is over, clamped.
    ///
    /// Arithmetic rather than measured: every row is one tab tall, so the bands
    /// are known. Clamping means dragging above or below the strip still means
    /// the nearest row rather than nothing.
    private func nearestRow(to y: CGFloat, of count: Int) -> Int {
        let pitch = Metrics.tabHeight + Metrics.rowSpacing
        let raw = Int(((y - Metrics.rowSpacing) / pitch).rounded(.down))
        return max(0, min(count - 1, raw))
    }

    /// Where a tab arriving from another row lands.
    ///
    /// Measured against the row without it in, which is the order
    /// `FileTabStripModel.move` inserts into — it takes the tab out first.
    private func slot(for x: CGFloat, in row: Int) -> Int {
        let others = set.tabs.rows[row].filter { $0.id != drag?.id }
        return FileTabRowGeometry(
            widths: others.map(width(of:)),
            spacing: Metrics.tabSpacing,
            leading: Metrics.stripPadding
        ).slot(forLeadingEdge: x)
    }

    private func frameReporter(for id: FileTab.ID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TabWidthsKey.self, value: [id: geometry.size.width]
            )
        }
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
        /// Stands in for a width not yet reported, which is only ever the frame
        /// before the first layout pass. Wrong by a little for one frame beats
        /// zero, which would put every midline in the same place.
        static let assumedTabWidth: CGFloat = 90
    }
}

// MARK: - Where each tab is

/// Every tab's width.
///
/// Widths and not frames, deliberately. A width is what `ViewThatFits` decided
/// and nothing outside the layout can guess it from a character count — but it
/// changes only when a label picks a different tier, so it survives a reorder.
/// A *position* read back the same way does not: it arrives a pass late, which
/// during the update that reorders the strip is the difference between a tab
/// tracking the cursor and a tab jumping its own width.
private struct TabWidthsKey: PreferenceKey {
    static let defaultValue: [FileTab.ID: CGFloat] = [:]

    static func reduce(
        value: inout [FileTab.ID: CGFloat],
        nextValue: () -> [FileTab.ID: CGFloat]
    ) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

// MARK: - One tab

private struct FileTabView: View {
    let tab: FileTab
    let root: URL
    let siblings: [URL]
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

    private var tiers: [String] {
        FileTabLabel.tiers(for: tab.url, root: root, siblings: siblings)
    }

    var body: some View {
        HStack(spacing: 4) {
            label

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
            closeButton
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, 6)
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

    /// Every tier as its own `ViewThatFits` child, widest first.
    ///
    /// Spelled out rather than looped because a `ForEach` inside `ViewThatFits`
    /// is one child, and one child is one candidate. Short tier lists repeat
    /// their narrowest entry into the spare slots — never an `EmptyView`, which
    /// fits everything and would render a blank tab.
    private var label: some View {
        let t = tiers
        return ViewThatFits(in: .horizontal) {
            tierText(t, 0)
            tierText(t, 1)
            tierText(t, 2)
            // The last slot truncates, so a tab narrower than even the filename
            // shows part of it rather than nothing.
            tierText(t, FileTabLabel.tierCount - 1)
                .truncationMode(.middle)
        }
    }

    private func tierText(_ tiers: [String], _ index: Int) -> some View {
        Text(tiers.isEmpty ? tab.url.lastPathComponent
            : tiers[min(index, tiers.count - 1)])
            .font(.system(size: Metrics.fontSize))
            .foregroundColor(isSelected ? .primary : .secondary)
            .lineLimit(1)
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
