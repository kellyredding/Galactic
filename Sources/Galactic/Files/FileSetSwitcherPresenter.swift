import Combine
import Foundation

/// The set switcher: a card dropped from the set bar that lists an owner's
/// sets, switches between them, and makes, renames and deletes them.
///
/// Wired once per process by `FilesSurface.connectPresenters()` through a group
/// provider and four callbacks, the way the picker and the searcher are.
@MainActor
final class FileSetSwitcherPresenter: ObservableObject {

    static let shared = FileSetSwitcherPresenter()

    enum Mode: Equatable {
        case list
        case create
        case rename(setID: String)
    }

    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case set(String)
            case newSet
        }

        let kind: Kind
        let name: String
        let matchedOffsets: [Int]
        let fileCount: Int
        let noteCount: Int
        let isDefault: Bool
        let isAgentMade: Bool
        let isCurrent: Bool

        var id: String {
            switch kind {
            case .set(let id): return id
            case .newSet: return "galactic.new-file-set"
            }
        }

        var setID: String? {
            if case .set(let id) = kind { return id }
            return nil
        }
    }

    @Published private(set) var isPresented = false

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshRows()
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var mode: Mode = .list

    @Published var nameText = "" {
        didSet {
            if nameText != oldValue { nameProblem = nil }
        }
    }

    @Published private(set) var nameProblem: FileSetNameProblem?

    /// Bumped once the card's view has gone and its focus handback has run —
    /// the moment a pane behind it can tell whether the window was left with
    /// nobody holding the keyboard.
    @Published private(set) var focusHandbacks = 0

    // MARK: - What the surface supplies

    var groupProvider: () -> FileSetGroup? = { nil }
    var onSelect: (String) -> Void = { _ in }
    var onCreate: (String) -> FileSetNameProblem? = { _ in nil }
    var onRename: (String, String) -> FileSetNameProblem? = { _, _ in nil }
    var onDelete: (String) -> Void = { _ in }

    let focus = ModalFocusCapture()

    /// The group the card was opened for. Every action checks it is still the
    /// current one, so a host that changes owner under an open card cannot have
    /// a click land in another session's sets.
    private var group: FileSetGroup?
    private var groupObservation: AnyCancellable?

    /// Internal so the package's tests can drive an instance without mutating
    /// the singleton every other test shares. Hosts reach it through the
    /// surface.
    init() {}

    static var isClaimingKeyboard: Bool { shared.isPresented }

    // MARK: - Opening and closing

    func toggle() {
        isPresented ? dismiss() : present()
    }

    func present() {
        guard !isPresented else { return }
        // One card in the Files surface at a time.
        FilePickerPresenter.shared.dismiss()
        FileSearchPresenter.shared.dismiss()
        LineJumpPresenter.shared.dismiss()

        group = groupProvider()
        // Received a turn later: `objectWillChange` fires before the property
        // is written, and a refresh then would read the old value.
        groupObservation = group?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRows() }
        mode = .list
        nameText = ""
        nameProblem = nil
        query = ""
        refreshRows()

        focus.arm(
            isActive: { [weak self] in self?.isPresented ?? false },
            onEscape: { [weak self] in self?.escape() }
        )
        focus.adopt(from: FilePickerPresenter.shared.focus)
        focus.adopt(from: FileSearchPresenter.shared.focus)
        focus.adopt(from: LineJumpPresenter.shared.focus)
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        focus.disarm()
        groupObservation = nil
    }

    /// Called by the view as it disappears, never by `dismiss` — see
    /// `ModalFocusCapture.restore` for why that ordering is the whole argument.
    func restoreFocus() {
        focus.restore()
        focusHandbacks &+= 1
    }

    /// Escape unwinds one layer: naming back to the list, the list to closed.
    func escape() {
        if mode == .list {
            dismiss()
        } else {
            backToList()
        }
    }

    // MARK: - The list

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = max(0, min(rows.count - 1, selectedIndex + delta))
    }

    func commit() {
        if mode == .list {
            guard rows.indices.contains(selectedIndex) else { return }
            activate(rows[selectedIndex])
        } else {
            submitName()
        }
    }

    /// What a row does, in one place, so a click and Return cannot diverge.
    func activate(_ row: Row) {
        guard isStillCurrent else { return }
        switch row.kind {
        case .set(let id):
            // Choosing another set hides the page this card was opened over,
            // so the keyboard must not be handed back to it.
            if !row.isCurrent { focus.forget() }
            dismiss()
            onSelect(id)
        case .newSet:
            beginCreate()
        }
    }

    func delete(setID: String) {
        guard isStillCurrent else { return }
        onDelete(setID)
    }

    // MARK: - Naming

    /// Ask for a name — or use the one typed in the filter, when it is free.
    func beginCreate() {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        mode = .create
        nameText = typed
        nameProblem = nil
        if !typed.isEmpty, group?.set(named: typed) == nil { submitName() }
    }

    func beginRename(setID: String) {
        guard let set = group?.set(withID: setID), !set.isDefault else {
            return
        }
        mode = .rename(setID: setID)
        nameText = set.name
        nameProblem = nil
    }

    func backToList() {
        mode = .list
        nameText = ""
        nameProblem = nil
    }

    func submitName() {
        guard isStillCurrent, let group else { return }
        switch mode {
        case .list:
            return
        case .create:
            if case .failure(let problem) = group.validateName(nameText) {
                nameProblem = problem
                return
            }
            // The new set is shown and the picker offered over it, so the page
            // this card was opened over is not where the keyboard goes back to.
            focus.forget()
            if let problem = onCreate(nameText) {
                nameProblem = problem
                return
            }
            dismiss()
        case .rename(let id):
            if let problem = onRename(id, nameText) {
                nameProblem = problem
                return
            }
            backToList()
            refreshRows()
        }
    }

    var namingTitle: String {
        switch mode {
        case .list:
            return ""
        case .create:
            return "New set"
        case .rename(let id):
            return "Rename “\(group?.set(withID: id)?.name ?? "")”"
        }
    }

    // MARK: - Rows

    private var isStillCurrent: Bool {
        guard let group, groupProvider() === group else {
            dismiss()
            return false
        }
        return true
    }

    /// The sets, then a row for making one.
    ///
    /// Unfiltered, the group's own order and the first set not on screen
    /// highlighted, so ⌘P then Return goes back to where the reader just was.
    /// Filtered, best match first.
    func refreshRows() {
        guard let group else {
            rows = []
            selectedIndex = 0
            return
        }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var matches: [(set: FileSet, offsets: [Int], score: Int)] = []
        for set in group.sets {
            if typed.isEmpty {
                matches.append((set, [], 0))
            } else if let match = FuzzyMatch.result(set.name, query: typed) {
                matches.append((set, match.matchedOffsets, match.score))
            }
        }
        if !typed.isEmpty {
            matches = matches.enumerated()
                .sorted {
                    ($0.element.score, -$0.offset)
                        > ($1.element.score, -$1.offset)
                }
                .map(\.element)
        }

        var built = matches.map { entry in
            Row(
                kind: .set(entry.set.id),
                name: entry.set.name,
                matchedOffsets: entry.offsets,
                fileCount: entry.set.fileCount,
                noteCount: entry.set.totalNoteCount,
                isDefault: entry.set.isDefault,
                isAgentMade: entry.set.origin == .agent,
                isCurrent: entry.set.id == group.selectedID
            )
        }
        let offersTypedName = !typed.isEmpty && group.set(named: typed) == nil
        built.append(
            Row(
                kind: .newSet,
                name: offersTypedName ? "New set “\(typed)”" : "New set…",
                matchedOffsets: [],
                fileCount: 0,
                noteCount: 0,
                isDefault: false,
                isAgentMade: false,
                isCurrent: false
            )
        )

        rows = built
        selectedIndex =
            typed.isEmpty ? (built.firstIndex { !$0.isCurrent } ?? 0) : 0
    }
}
