import AppKit
import SwiftUI

/// The set switcher's card, dropped from the set bar's leading edge.
///
/// A clear scrim catches the click outside the card, as the picker's does. The
/// card is sized to its rows, up to the room the pane offers.
struct FileSetSwitcherView: View {
    @ObservedObject private var presenter: FileSetSwitcherPresenter

    private enum Field: Hashable { case filter, name }

    @FocusState private var focus: Field?
    @State private var available: CGFloat = 0
    @State private var hoveredRowID: String?
    @Environment(\.colorScheme) private var colorScheme

    @MainActor init() { presenter = .shared }

    init(presenter: FileSetSwitcherPresenter) { self.presenter = presenter }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { presenter.dismiss() }
            GeometryReader { geometry in
                card
                    .padding(.leading, Metrics.leadingInset)
                    .padding(.top, Metrics.topInset)
                    .onChange(of: geometry.size.height, initial: true) {
                        available = geometry.size.height
                    }
            }
        }
        .onAppear { claimField() }
        .onChange(of: presenter.mode) { _, _ in claimField() }
        .onDisappear {
            // Cleared before restoring, for the reason `FilePickerView` gives.
            focus = nil
            presenter.restoreFocus()
        }
    }

    enum Metrics {
        static let width: CGFloat = 380
        static let cornerRadius: CGFloat = 8
        static let topInset: CGFloat = 4
        static let leadingInset: CGFloat = 8
        static let rowHeight: CGFloat = 26
        static let minimumRows = 3
        /// The filter field and the divider under it.
        static let chromeHeight: CGFloat = 37

        static func listHeight(rows: Int, available: CGFloat) -> CGFloat {
            let wanted = CGFloat(max(1, rows)) * rowHeight
            guard available > 0 else {
                return CGFloat(minimumRows) * rowHeight
            }
            let room = available - chromeHeight - topInset - 12
            return min(wanted, max(CGFloat(minimumRows) * rowHeight, room))
        }
    }

    private var wantedField: Field {
        presenter.mode == .list ? .filter : .name
    }

    /// Twice, for the reason `FilePickerView.claimField` gives.
    private func claimField() {
        focus = wantedField
        DispatchQueue.main.async {
            if focus != wantedField { focus = wantedField }
        }
    }

    private var green: Color {
        Color(SendBarGreen.color(isLight: colorScheme != .dark))
    }

    private var card: some View {
        Group {
            if presenter.mode == .list {
                listCard
            } else {
                namingCard
            }
        }
        .frame(width: Metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .shadow(radius: 20, y: 6)
    }

    // MARK: - The list

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Switch to a set", text: $presenter.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .filter)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onSubmit { presenter.commit() }
                .onKeyPress(.downArrow) {
                    presenter.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    presenter.moveSelection(by: -1)
                    return .handled
                }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            Array(presenter.rows.enumerated()), id: \.element.id
                        ) { index, row in
                            rowView(row, at: index)
                        }
                    }
                }
                .frame(
                    height: Metrics.listHeight(
                        rows: presenter.rows.count, available: available
                    )
                )
                .onChange(of: presenter.selectedIndex) { _, new in
                    guard presenter.rows.indices.contains(new) else { return }
                    proxy.scrollTo(presenter.rows[new].id)
                }
            }
        }
    }

    private func rowView(
        _ row: FileSetSwitcherPresenter.Row, at index: Int
    ) -> some View {
        let isSelected = index == presenter.selectedIndex
        return FileSetSwitcherRow(
            row: row,
            isSelected: isSelected,
            showsActions: isSelected || hoveredRowID == row.id,
            green: green,
            onActivate: { presenter.activate(row) },
            onRename: {
                if let id = row.setID { presenter.beginRename(setID: id) }
            },
            onDelete: {
                if let id = row.setID { presenter.delete(setID: id) }
            }
        )
        .id(row.id)
        .onHover { inside in
            if inside {
                hoveredRowID = row.id
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
    }

    // MARK: - Naming

    private var namingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(presenter.namingTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            TextField("Name", text: $presenter.nameText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .name)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .onSubmit { presenter.submitName() }
            Divider()
            Group {
                if let problem = presenter.nameProblem {
                    Text(problem.message).foregroundStyle(.orange)
                } else {
                    Text(hint).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var hint: String {
        if case .rename = presenter.mode { return "↩ rename · esc back" }
        return "↩ create · esc back"
    }
}

/// One set, or the row that makes one.
private struct FileSetSwitcherRow: View {
    let row: FileSetSwitcherPresenter.Row
    let isSelected: Bool
    let showsActions: Bool
    let green: Color
    let onActivate: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The tap is on this half only, so the buttons beside it keep their
            // own clicks.
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11))
                    .foregroundStyle(row.isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 14)
                Text(CheatSheetHighlight.highlighted(row.name, row.matchedOffsets))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.isAgentMade {
                    Text("✦")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Made by the agent")
                }
                Spacer(minLength: 0)
                if row.setID != nil {
                    Text(files)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if row.noteCount > 0 {
                        Text("\(row.noteCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(green))
                            .fixedSize()
                            .help("Notes not yet sent")
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onActivate)

            if row.setID != nil, !row.isDefault, showsActions {
                Button(action: onRename) {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rename")
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: FileSetSwitcherView.Metrics.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var glyph: String {
        guard row.setID != nil else { return "plus" }
        return row.isCurrent ? "checkmark" : "square.stack"
    }

    private var files: String {
        row.fileCount == 1 ? "1 file" : "\(row.fileCount) files"
    }
}
