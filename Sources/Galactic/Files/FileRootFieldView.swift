import SwiftUI

/// The root field, and the folders it is choosing between.
///
/// Mounted inside a panel's card above its search field, by both panels, so it
/// takes callbacks rather than a presenter — the two hold different presenters
/// and neither should have to know about the other's.
///
/// Row metrics come from `FilePickerView.Metrics`, which `FileTreeView` already
/// borrows the same way, so all three lists in this family are one row height.
/// Generic over the panel's focus value so the caret can be driven from
/// outside: `.focused` has to sit on the text field itself, and each panel's
/// focus enum is its own.
struct FileRootFieldView<Focus: Hashable>: View {

    private typealias Metrics = FilePickerView.Metrics

    @Binding var text: String
    @FocusState.Binding var focus: Focus?
    let focusValue: Focus
    let rows: [FilePickerItem]
    let selection: Int?

    /// Tab.
    let onComplete: () -> Void
    /// Return, or a click on a row.
    let onCommit: () -> Void
    let onMove: (Int) -> Void
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            // Only while the field has the caret. The list is guidance for
            // something being typed, and leaving it up after focus moved on
            // would leave the panel claiming to be asking a question it is not.
            if focus == focusValue, !rows.isEmpty {
                Divider()
                list
            }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(focus == focusValue ? .primary : .tertiary)
            TextField("Root folder", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .focused($focus, equals: focusValue)
                .onSubmit { onCommit() }
                .onKeyPress(.tab) {
                    onComplete()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onMove(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    onMove(-1)
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .frame(width: 14)
                            .foregroundStyle(
                                index == selection ? .primary : .secondary
                            )
                        Text(row.relativePath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: Metrics.rowHeight)
                    .background(
                        index == selection
                            ? Color.accentColor.opacity(0.18) : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onPick(index)
                        onCommit()
                    }
                }
            }
        }
        .frame(height: listHeight)
    }

    /// Six rows at most. The field is how a reader narrows, so this is a glance
    /// rather than something to scroll — and the card it sits in has a search
    /// field and a result list below it that must stay reachable.
    private var listHeight: CGFloat {
        CGFloat(min(rows.count, 6)) * Metrics.rowHeight
    }
}
