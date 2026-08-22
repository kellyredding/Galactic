import SwiftUI

/// The picker's Browse tab: a folder tree from the current root.
///
/// Rows come from `FileTreeOutline`, already flattened, so this draws a list and
/// nothing more — no recursion, no nested `ForEach`, no per-row disclosure state.
/// A tree drawn as nested views owns its expansion in the view hierarchy, which
/// is where the drag and hover defects in the file tab strip both hid.
struct FileTreeView: View {
    @ObservedObject var presenter: FilePickerPresenter
    /// The overlay area's height, handed down so both tabs cap themselves the
    /// same way and the card does not resize when you switch between them.
    let available: CGFloat

    private typealias Metrics = FilePickerView.Metrics

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(presenter.treeRows.enumerated()), id: \.element.id
                    ) { index, row in
                        FileTreeRow(
                            row: row,
                            isSelected: index == presenter.treeSelectedIndex
                        )
                        .id(row.id)
                        .onTapGesture {
                            presenter.selectTreeRow(row)
                            presenter.activateSelectedTreeRow()
                        }
                    }
                }
            }
            .frame(height: height)
            .onChange(of: presenter.treeSelectedIndex) { _, new in
                guard presenter.treeRows.indices.contains(new) else { return }
                proxy.scrollTo(presenter.treeRows[new].id)
            }
        }
    }

    /// As tall as the rows it has, up to the room the window is offering.
    ///
    /// **The cap is on the panel, not on the rows.** The ranked list stops at a
    /// hundred results because past the first screenful the ordering stops being
    /// read; a tree is navigated rather than ranked, so a cap there would hide
    /// files whose only fault is being further down.
    private var height: CGFloat {
        Metrics.listHeight(rows: presenter.treeRows.count, available: available)
    }
}

/// One row: an indent, a disclosure gutter, and a name.
private struct FileTreeRow: View {
    let row: FileTreeOutline.Row
    let isSelected: Bool

    private typealias Metrics = FilePickerView.Metrics

    var body: some View {
        HStack(spacing: 0) {
            // The gutter is drawn for files too, empty. That is what aligns a
            // filename with the folder names above it rather than with their
            // chevrons — the indentation says the depth, and a name that starts
            // where a chevron does reads as a level shallower than it is.
            gutter
                .frame(width: Metrics.treeGutter)
            // Through the same helper the ranked rows use, so a match reads the
            // same in both tabs. A folder shows whichever part of the query
            // landed on *its* name — `FileTreeOutline` cuts the match up by
            // segment so each row highlights its own letters rather than all of
            // them highlighting from the front.
            Text(
                CheatSheetHighlight.highlighted(row.name, row.matchedOffsets)
            )
            .font(.system(size: 12))
            .foregroundStyle(nameStyle)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12 + CGFloat(row.depth) * Metrics.treeIndent)
        .padding(.trailing, 12)
        .frame(height: Metrics.rowHeight)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var gutter: some View {
        if row.isDirectory {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }

    /// Three tiers, which is most of what makes a deep tree readable: the root
    /// brightest, folders plain, filenames dimmed. Reading a tree is mostly
    /// skipping the folders you are not looking for.
    private var nameStyle: HierarchicalShapeStyle {
        if row.depth == 0 { return .primary }
        return row.isDirectory ? .primary : .secondary
    }
}
