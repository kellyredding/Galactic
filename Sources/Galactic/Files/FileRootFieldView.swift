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

    /// **The model, not a pile of values.**
    ///
    /// It arrived here as eight separate arguments, and a panel then had to wire
    /// the caret to `beginEditing` itself — which the picker was shipped without,
    /// so its folder list silently never populated: the refresh guards on being
    /// in edit mode, and nothing had ever said it was. Taking the model means a
    /// panel cannot forget wiring it does not do.
    @ObservedObject var model: FileRootFieldModel

    @FocusState.Binding var focus: Focus?

    /// This field's own focus value, and where the caret goes when the field is
    /// finished with — the panel's query field.
    let focusValue: Focus
    let returnFocusTo: Focus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            // Only while the field has the caret. The list is guidance for
            // something being typed, and leaving it up after focus moved on
            // would leave the panel claiming to be asking a question it is not.
            if focus == focusValue, !model.rows.isEmpty {
                Divider()
                list
            }
        }
        // The caret arriving is what starts an edit, and the model needs telling
        // because it cannot see focus.
        .onChange(of: focus) { _, now in
            if now == focusValue {
                model.beginEditing()
            } else if model.isEditing {
                model.endEditing()
            }
        }
        // Committing or reverting finishes with the field, and says so by
        // leaving edit mode. Handing the caret back here rather than in each
        // panel keeps the two from answering it differently.
        .onChange(of: model.isEditing) { _, editing in
            if !editing, focus == focusValue { focus = returnFocusTo }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(focus == focusValue ? .primary : .tertiary)
            TextField(
                "Root folder",
                text: Binding(
                    get: { model.field.text },
                    set: { model.edit($0) }
                )
            )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .focused($focus, equals: focusValue)
                .onSubmit { model.commit() }
                .onKeyPress(.tab) {
                    model.complete()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .frame(width: 14)
                            .foregroundStyle(
                                index == model.field.selection ? .primary : .secondary
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
                        index == model.field.selection
                            ? Color.accentColor.opacity(0.18) : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.pick(index)
                        model.commit()
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
        CGFloat(min(model.rows.count, 6)) * Metrics.rowHeight
    }
}
