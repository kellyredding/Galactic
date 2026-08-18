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
public struct FileTabStripView: View {

    @ObservedObject private var set: FileSet

    private let onSelect: (FileTab.ID) -> Void
    private let onClose: (FileTab.ID) -> Void

    /// Read this file from disk again, replacing what was frozen at open.
    ///
    /// In the context menu rather than as a button in the strip: it is the rare
    /// one of these actions, it destroys notes, and a row of tabs has no width to
    /// spare for an affordance nobody reaches for twice a day.
    private let onReload: (FileTab.ID) -> Void

    /// What the trailing affordance does. The host decides what opening means —
    /// a fuzzy picker, or the system's own dialog — because only it knows which
    /// of those it has.
    private let onRequestOpen: () -> Void

    public init(
        set: FileSet,
        onSelect: @escaping (FileTab.ID) -> Void,
        onClose: @escaping (FileTab.ID) -> Void,
        onReload: @escaping (FileTab.ID) -> Void,
        onRequestOpen: @escaping () -> Void
    ) {
        self.set = set
        self.onSelect = onSelect
        self.onClose = onClose
        self.onReload = onReload
        self.onRequestOpen = onRequestOpen
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
                    }

                    // On the last row only, so the affordance stays at the end
                    // of the strip rather than appearing once per row.
                    if index == set.tabs.rows.count - 1 {
                        OpenAffordance(action: onRequestOpen)
                        Spacer(minLength: 0)
                    }
                }
            }

            if set.tabs.rows.isEmpty {
                HStack(spacing: Metrics.tabSpacing) {
                    OpenAffordance(action: onRequestOpen)
                    Text("No files open")
                        .font(.system(size: Metrics.fontSize))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Metrics.stripPadding)
        .padding(.vertical, Metrics.rowSpacing)
    }

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

// MARK: - Opening

/// The trailing `+`. Says nothing about what opening means; the host answers.
private struct OpenAffordance: View {
    let action: () -> Void

    @State private var isHovering = false

    private typealias Metrics = FileTabStripView.Metrics

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: Metrics.tabHeight, height: Metrics.tabHeight)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0.02))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open a file")
    }
}
