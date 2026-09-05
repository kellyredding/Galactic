import AppKit
import SwiftUI

/// The file picker: a field and a ranked list, sized to what it is offering.
///
/// **Anchored, not floating.** Mounted by the host as a top-aligned overlay on
/// the area under its tab strip, the way an editor's go-to-file panel sits under
/// its tabs — so the field appears where the reader's eye already is and the list
/// grows downward over the document it is about to replace. A centred modal put
/// the field in a different place depending on how many results there were, which
/// is the one thing a search field must not do.
///
/// It draws no dimming. The scrim is clear and exists only to catch a click
/// outside the card, because dimming a document the reader is choosing a
/// replacement for hides the thing that tells them which one they want.
///
/// The card sizes itself: header and field are fixed, and the list is as tall as
/// its rows up to a cap, past which it scrolls. Nothing here reserves height it
/// is not using. See `FilePickerPresenter` for the mounting snippet.
public struct FilePickerView: View {
    @ObservedObject private var presenter: FilePickerPresenter
    /// Which of the card's two fields holds the caret.
    ///
    /// An enum rather than two booleans: two independent flags can both read
    /// true, and SwiftUI resolves that by focusing whichever field it laid out
    /// last — which is not a decision anyone made.
    private enum Field: Hashable { case root, query }

    @FocusState private var focus: Field?

    /// Put the caret in the query field, and again once the pass settles.
    ///
    /// Twice, because a host may be moving first responder for its own reasons
    /// in the same tab-change pass — releasing a terminal pane's claim is the
    /// one that showed this — and AppKit does not contract which of the two
    /// lands last. The second fires only if the first was undone, so a card
    /// that already holds the caret is left alone.
    private func claimField() {
        focus = .query
        DispatchQueue.main.async {
            if focus == nil { focus = .query }
        }
    }

    /// AppKit's backtab, which is what Shift-Tab is sent as.
    private static let backTab = KeyEquivalent("\u{19}")
    /// How tall the host's overlay area is, so the card can use all of it.
    @State private var available: CGFloat = 0

    /// A default argument expression is read in a nonisolated context whatever
    /// the initialiser's isolation, so `= .shared` cannot name main-actor state
    /// and reading it in the body can. Same two-initialiser shape as the cheat
    /// sheet and the inbox.
    @MainActor public init() { presenter = .shared }

    public init(presenter: FilePickerPresenter) { self.presenter = presenter }

    public var body: some View {
        ZStack(alignment: .top) {
            scrim
            // The height the host is offering, read from the overlay area rather
            // than from the card. That direction is what makes it safe: the area
            // is sized by the window, so nothing the card does can move it, and
            // the reverse — sizing a container from its content and then the
            // content from the container — is the cycle that hangs the tab strip.
            GeometryReader { geometry in
                card
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onChange(of: geometry.size.height, initial: true) {
                        available = geometry.size.height
                    }
            }
        }
        .onAppear { claimField() }
        .onDisappear {
            // Cleared *before* restoring, which the cheat sheet also has to do
            // and the inbox does not: SwiftUI clears first responder when it
            // tears down a field whose focus binding still reads true, which
            // would undo the restore a pass later.
            focus = nil
            presenter.restoreFocus()
        }
    }

    /// Clear rather than dimmed: this sits over the document a reader is
    /// choosing a replacement for, and dimming it would hide the context that
    /// tells them which file they want. It is here for the click, not the look.
    private var scrim: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            rootField
            Divider()
            FilePickerModeTabs(selected: presenter.mode) {
                presenter.selectMode($0)
            }
            Divider()
            field
            Divider()
            body(for: presenter.mode)
        }
        .frame(width: Metrics.width)
        // Sized by its content, in both directions. The height this replaced —
        // a `maxHeight` with no alignment — centred the card's content inside a
        // fixed 460pt box, so an empty list drew a tall panel with one line of
        // text floating in the middle of it.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius)
        )
        .shadow(radius: 20, y: 6)
        .padding(.top, Metrics.topInset)
    }

    enum Metrics {
        static let width: CGFloat = 640
        static let cornerRadius: CGFloat = 8
        /// A hair below the divider it hangs from, so the card reads as attached
        /// to the strip rather than dropped on top of the document.
        static let topInset: CGFloat = 6
        /// One row, fixed so the list's height is arithmetic rather than a
        /// measurement — a list that has to be laid out before it can be sized
        /// is a list that resizes after it is drawn.
        static let rowHeight: CGFloat = 26
        /// The fewest rows the list is ever given, so a narrow window still
        /// shows something to choose from rather than a sliver.
        static let minimumRows = 4
        /// Everything above the list: the header, the root field, the mode tabs,
        /// the query field, and the four dividers between them.
        ///
        /// A constant rather than a measurement, and the error it can carry is
        /// bounded and harmless — a few points out makes the list a few points
        /// shorter, which costs at most one row. Measuring it would mean reading
        /// back a height in order to decide a height.
        ///
        /// **Grown by the root field's row and one divider.** Left unchanged, the
        /// list would have been given room that is no longer there and would run
        /// off the bottom of the card by exactly that much — which is not
        /// something a constant announces when it goes stale.
        static let chromeHeight: CGFloat = 31 + 27 + 27 + 38 + 4
        /// As tall as `rows` needs, capped by what the window is offering.
        static func listHeight(rows: Int, available: CGFloat) -> CGFloat {
            let wanted = CGFloat(max(1, rows)) * rowHeight
            guard available > 0 else {
                return CGFloat(minimumRows) * rowHeight
            }
            let room = available - chromeHeight - topInset - 12
            return min(wanted, max(CGFloat(minimumRows) * rowHeight, room))
        }
        /// One level of nesting in the tree.
        static let treeIndent: CGFloat = 14
        /// The disclosure column, drawn empty for files so their names line up
        /// with the folder names rather than with the chevrons.
        static let treeGutter: CGFloat = 16
    }

    /// Which tree is being searched, said out loud so a reader wondering why a
    /// file is missing can see the answer before they go looking for it.
    private var header: some View {
        HStack(spacing: 6) {
            // The chip that used to live here typed the root into the query
            // field, because that was the only way to change it. There is a
            // field for it now, so this says how to reach that instead of
            // standing in for it.
            Text(
                focus == .root
                    ? "⇥ complete · ↩ set folder"
                    : "⇧⇥ change folder · ⌘↩ open and stay"
            )
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

            Spacer()
            if presenter.isIndexing {
                // The count, not just the verb. A walk of a large tree runs for
                // tens of seconds, and a reader watching a number climb knows it
                // is working and roughly how far in it is — where a bare
                // "indexing…" is indistinguishable from a hang.
                Text(
                    presenter.indexedCount > 0
                        ? "indexing… \(presenter.indexedCount.formatted())"
                        : "indexing…"
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            } else if presenter.corpusWasTruncated {
                // The number rather than "partial index", which said that
                // something was incomplete without saying how much or what to do
                // about it. A count is actionable: it is the ceiling the walk hit,
                // so the answers are a narrower root or a wider skip list.
                Text("first \(presenter.indexedCount.formatted()) files")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(
                        "This folder holds more files than the picker indexes, "
                            + "so some are not searched. Browse a narrower "
                            + "folder to see all of it."
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }


    /// The root, editable. What a relative path is relative to, and what the
    /// header used to be able only to name.
    private var rootField: some View {
        FileRootFieldView(
            model: presenter.rootFieldModel,
            focus: $focus,
            focusValue: Field.root,
            returnFocusTo: Field.query
        )
    }

    private var field: some View {
        TextField("Open a file", text: $presenter.query)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focused($focus, equals: .query)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onSubmit {
                // A path in the field outranks the tree's selection, in both
                // modes: the reader typed it, and the tree is showing where they
                // were rather than where they said they are going.
                if treeIsShowing {
                    presenter.activateSelectedTreeRow()
                } else {
                    presenter.commit()
                }
            }
            .onKeyPress(.downArrow) {
                move(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                move(by: -1)
                return .handled
            }
            // **The horizontal arrows are the field's, in both modes.** They
            // were briefly the tree's expand and collapse, which took ←/→,
            // ⌥←/⌥→ and ⌘←/⌘→ away from a field the reader is always able to
            // type into — so moving the caret through a path meant reaching for
            // the mouse. Return already opens and closes a folder, which is
            // what makes giving these up cost nothing.
            // **Shift-Tab reaches the root field. Plain Tab is left alone.**
            // Tab used to complete a path typed in here, because this field also
            // did that job; the field above owns paths now, and a query has
            // nothing to complete against.
            //
            // Two spellings, deliberately: AppKit sends Shift-Tab as backtab, a
            // character of its own, rather than as Tab with a modifier, and
            // which of the two SwiftUI reports is not contracted anywhere.
            .onKeyPress(keys: [.tab, Self.backTab]) { press in
                let isBackward =
                    press.key == Self.backTab
                    || press.modifiers.contains(.shift)
                guard isBackward else { return .ignored }
                focus = .root
                return .handled
            }
            // ⌘H / ⌘L, the same pair that steps between file tabs when the
            // picker is closed. It is closed-or-open that decides which, and the
            // host already stands its own pair down for a modal — see
            // `GalacticModals`.
            .onKeyPress(keys: ["h", "l", "\r"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                switch press.key {
                case "h": presenter.selectMode(.search)
                case "l": presenter.selectMode(.browse)
                default:
                    if treeIsShowing {
                        presenter.activateSelectedTreeRow(keepingOpen: true)
                    } else {
                        presenter.commit(keepingOpen: true)
                    }
                }
                return .handled
            }
    }

    /// One field above two ways of answering it.
    ///
    /// A typed path is answered the same way in both, because it is a question
    /// about the field rather than about the mode — so Browse shows the folders
    /// being chosen between rather than a tree of a root nobody has arrived at.
    @ViewBuilder
    private func body(for mode: FilePickerMode) -> some View {
        if mode == .browse {
            FileTreeView(presenter: presenter, available: available)
        } else {
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        if presenter.rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            Array(presenter.rows.enumerated()), id: \.element.id
                        ) { index, row in
                            FilePickerRow(
                                item: row,
                                isSelected: index == presenter.selectedIndex
                            )
                            .id(row.id)
                            .reportingTopRow(id: row.id, in: Self.space)
                            .onTapGesture {
                                presenter.open(
                                    row,
                                    keepingOpen: FilePickerClick.wantsToKeepOpen
                                )
                            }
                        }
                    }
                }
                .coordinateSpace(name: Self.space)
                .frame(height: listHeight)
                .onPreferenceChange(TopRowPreference.self) { top in
                    // A plain property, not published state: this fires every
                    // scroll frame and only a later reopen reads it.
                    presenter.noteScrollTop(top?.id, in: .search)
                }
                .onChange(of: presenter.selectedIndex) { _, new in
                    guard presenter.rows.indices.contains(new) else { return }
                    proxy.scrollTo(presenter.rows[new].id)
                }
                .onChange(of: presenter.scrollTarget, initial: true) { _, target in
                    guard let target, target.mode == .search else { return }
                    // Deferred, for the reason `FileTreeView` documents: a row a
                    // `LazyVStack` has not built yet cannot be scrolled to, and
                    // the attempt fails silently.
                    Task { @MainActor in
                        proxy.scrollTo(target.id, anchor: .top)
                        presenter.clearScrollTarget()
                    }
                }
            }
        }
    }

    private static let space = "galactic.file-picker-results"

    /// Whether the tree is what is on screen, which is what the arrows and
    /// Return have to follow — Browse showing a folder chooser is a list, and
    /// driving the tree behind it would move a selection nobody can see.
    private var treeIsShowing: Bool {
        presenter.mode == .browse
    }

    private func move(by delta: Int) {
        if treeIsShowing {
            presenter.moveTreeSelection(by: delta)
        } else {
            presenter.moveSelection(by: delta)
        }
    }

    /// As tall as the rows it has, up to the room there is. Arithmetic rather
    /// than a measurement, which is what `rowHeight` is fixed for.
    private var listHeight: CGFloat {
        Metrics.listHeight(rows: presenter.rows.count, available: available)
    }

    /// Says which of the several nothings this is — see `FilePickerEmptyState`,
    /// which owns the wording and the precedence between the five of them.
    private var emptyState: some View {
        Text(
            FilePickerEmptyState.message(
                hasRoot: presenter.root != nil,
                isIndexing: presenter.isIndexing,
                isRootChange: FileRootInput.isRootChange(
                    presenter.query, route: presenter.root?.path
                ),
                query: presenter.query
            )
        )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
    }
}

/// One row: the path, with the matched characters emphasised.
private struct FilePickerRow: View {
    let item: FilePickerItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 14)
            highlighted
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: FilePickerView.Metrics.rowHeight)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .contentShape(Rectangle())
    }

    private var glyph: String {
        switch item.source {
        case .closed: return "arrow.uturn.backward"
        case .recent: return "clock"
        case .matched: return "doc"
        case .folder: return "folder"
        }
    }

    /// Emphasised through `CheatSheetHighlight`, which is internal and reachable
    /// from here because this is the same module — the promotion its own doc
    /// anticipated turned out not to be needed.
    private var highlighted: Text {
        Text(
            CheatSheetHighlight.highlighted(
                item.relativePath, item.matchedOffsets
            )
        )
    }
}
