import AppKit
import SwiftUI

/// The file picker: a field, a ranked list, and a scrim.
///
/// Mounted as an overlay at the host's window root, above every column, so ⌘T
/// reaches it from any surface. See `FilePickerPresenter` for the snippet.
public struct FilePickerView: View {
    @ObservedObject private var presenter: FilePickerPresenter
    @FocusState private var fieldFocused: Bool

    /// A default argument expression is read in a nonisolated context whatever
    /// the initialiser's isolation, so `= .shared` cannot name main-actor state
    /// and reading it in the body can. Same two-initialiser shape as the cheat
    /// sheet and the inbox.
    @MainActor public init() { presenter = .shared }

    public init(presenter: FilePickerPresenter) { self.presenter = presenter }

    public var body: some View {
        ZStack {
            scrim
            card
        }
        .onAppear { fieldFocused = true }
        .onDisappear {
            // Cleared *before* restoring, which the cheat sheet also has to do
            // and the inbox does not: SwiftUI clears first responder when it
            // tears down a field whose focus binding still reads true, which
            // would undo the restore a pass later.
            fieldFocused = false
            presenter.restoreFocus()
        }
    }

    private var scrim: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            field
            Divider()
            results
        }
        .frame(width: 640)
        .frame(maxHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 24, y: 8)
    }

    /// Which tree is being searched, said out loud so a reader wondering why a
    /// file is missing can see the answer before they go looking for it.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(rootLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if presenter.isIndexing {
                Text("indexing…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if presenter.corpusWasTruncated {
                // Surfaced rather than swallowed: ranking over part of a tree
                // is a thing to know, not a thing to discover.
                Text("partial index")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var rootLabel: String {
        guard let root = presenter.root else { return "no folder" }
        let home = NSHomeDirectory()
        return root.path.hasPrefix(home)
            ? "~" + root.path.dropFirst(home.count)
            : root.path
    }

    private var field: some View {
        TextField("Open a file, or type a path", text: $presenter.query)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focused($fieldFocused)
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
            .onKeyPress(.tab) {
                presenter.completePath()
                return .handled
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
                            .onTapGesture { presenter.open(row) }
                        }
                    }
                }
                .onChange(of: presenter.selectedIndex) { _, new in
                    guard presenter.rows.indices.contains(new) else { return }
                    proxy.scrollTo(presenter.rows[new].id)
                }
            }
        }
    }

    /// Says which of the several nothings this is. "No agent running" and
    /// "nothing matched" are different answers and a reader acts on them
    /// differently — the same distinction `AgentInboxView` draws.
    @ViewBuilder
    private var emptyState: some View {
        let message: String = {
            if presenter.root == nil { return "No folder to browse" }
            if presenter.isIndexing { return "Reading the folder…" }
            if FilePickerRootInput.isRootChange(presenter.query) {
                return "Return to browse here, Tab to complete"
            }
            if presenter.query.isEmpty {
                return "Nothing open or closed yet — type to search"
            }
            return "No file matches"
        }()

        Text(message)
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
        .padding(.vertical, 5)
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
