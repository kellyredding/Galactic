import Combine
import Foundation

/// Why a set's name was refused.
public enum FileSetNameProblem: Error, Equatable {
    case empty
    /// Carries the existing set's name as it is spelled.
    case taken(String)
    case unchangeable

    public var message: String {
        switch self {
        case .empty: return "A set needs a name."
        case .taken(let name): return "“\(name)” is already a set here."
        case .unchangeable: return "The default set keeps its name."
        }
    }
}

/// Every set one owner has, and which of them is on screen.
///
/// Publishes membership and selection only. Each `FileSet` publishes its own
/// changes, so a view watches the group to learn which set to show and the set
/// for what is in it.
public final class FileSetGroup: ObservableObject {

    public let ownerID: String

    /// The default first, then the rest by name.
    @Published public private(set) var sets: [FileSet]

    @Published public private(set) var selectedID: String

    /// The set shown before the one on screen — what the switcher offers first,
    /// so choosing again goes back to it. In memory only.
    public private(set) var previousID: String?

    public init(ownerID: String, defaultRoot: URL) {
        self.ownerID = ownerID
        let base = FileSet(
            ownerID: ownerID,
            id: Self.defaultSetID(forOwner: ownerID),
            isDefault: true,
            root: defaultRoot
        )
        sets = [base]
        selectedID = base.id
    }

    /// Stable across launches, and distinct across owners so no two sessions'
    /// defaults share a key.
    public static func defaultSetID(forOwner ownerID: String) -> String {
        "default-\(ownerID)"
    }

    public var defaultSet: FileSet { sets[0] }

    // `self.` is required: a computed body opening with `set(` parses as a
    // setter.
    public var selected: FileSet { self.set(withID: selectedID) ?? defaultSet }

    public func set(withID id: String) -> FileSet? {
        sets.first { $0.id == id }
    }

    public func set(named name: String) -> FileSet? {
        let key = Self.comparable(name)
        return sets.first { Self.comparable($0.name) == key }
    }

    // MARK: - Choosing

    /// Show a set, remembering the one it replaces.
    @discardableResult
    public func select(id: String) -> Bool {
        guard sets.contains(where: { $0.id == id }) else { return false }
        guard selectedID != id else { return true }
        previousID = selectedID
        selectedID = id
        return true
    }

    // MARK: - Naming

    public func validateName(
        _ raw: String, excluding id: String? = nil
    ) -> Result<String, FileSetNameProblem> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.empty) }
        if let clash = set(named: name), clash.id != id {
            return .failure(.taken(clash.name))
        }
        return .success(name)
    }

    /// Add a set without showing it — whether it comes forward is the caller's
    /// decision.
    public func create(
        name raw: String, root: URL, origin: FileSet.Origin = .user
    ) -> Result<FileSet, FileSetNameProblem> {
        validateName(raw).map { name in
            let created = FileSet(
                ownerID: ownerID, name: name, origin: origin, root: root
            )
            sets = Self.ordered(sets + [created])
            return created
        }
    }

    public func rename(id: String, to raw: String) -> FileSetNameProblem? {
        guard let target = set(withID: id) else { return nil }
        guard !target.isDefault else { return .unchangeable }
        switch validateName(raw, excluding: id) {
        case .failure(let problem):
            return problem
        case .success(let name):
            target.rename(to: name)
            // A new name can move the set. Reassigning is also what tells the
            // bar and the switcher's rows, which observe this object rather
            // than the set.
            sets = Self.ordered(sets)
            return nil
        }
    }

    /// Take a set away. The default refuses; removing the one on screen shows
    /// the default.
    @discardableResult
    public func remove(id: String) -> FileSet? {
        guard let index = sets.firstIndex(where: { $0.id == id }),
            !sets[index].isDefault
        else { return nil }
        let removed = sets.remove(at: index)
        if previousID == id { previousID = nil }
        if selectedID == id {
            selectedID = defaultSet.id
            if previousID == selectedID { previousID = nil }
        }
        return removed
    }

    // MARK: - Notes

    public var pendingNoteCount: Int {
        sets.reduce(0) { $0 + $1.totalNoteCount }
    }

    /// Whether a set other than the one on screen is holding notes.
    public var otherSetsHoldNotes: Bool {
        sets.contains { $0.id != selectedID && $0.totalNoteCount > 0 }
    }

    // MARK: - Restoring

    /// Rebuild from what a host saved. Returns the paths that did not open.
    ///
    /// The default is restored into the set that already exists, because a view
    /// may be observing it before this runs.
    @discardableResult
    public func restore(from saved: PersistedFileSetGroup) -> [String] {
        var dropped: [String] = []
        var rebuilt: [FileSet] = [defaultSet]
        var restoredDefault = false

        for record in saved.sets {
            if record.isDefault {
                guard !restoredDefault else { continue }
                restoredDefault = true
                if !record.root.isEmpty {
                    defaultSet.changeRoot(to: URL(fileURLWithPath: record.root))
                }
                dropped += defaultSet.restore(
                    openPathRows: record.openPathRows,
                    selectedPath: record.selectedPath
                )
                continue
            }

            let name = record.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let key = Self.comparable(name)
            guard !record.id.isEmpty, !name.isEmpty,
                !rebuilt.contains(where: {
                    $0.id == record.id || Self.comparable($0.name) == key
                })
            else { continue }

            let set = FileSet(
                ownerID: ownerID,
                id: record.id,
                name: name,
                origin: record.origin,
                root: record.root.isEmpty
                    ? defaultSet.root : URL(fileURLWithPath: record.root)
            )
            dropped += set.restore(
                openPathRows: record.openPathRows,
                selectedPath: record.selectedPath
            )
            rebuilt.append(set)
        }

        sets = Self.ordered(rebuilt)
        let wanted = saved.selectedID.flatMap { id in
            rebuilt.first { $0.id == id }?.id
        }
        selectedID = wanted ?? defaultSet.id
        previousID = nil
        return dropped
    }

    /// The default first, then the rest by name the way Finder sorts them, so
    /// `test2` comes before `test10`.
    private static func ordered(_ sets: [FileSet]) -> [FileSet] {
        let rest = sets.filter { !$0.isDefault }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return sets.filter(\.isDefault) + rest
    }

    private static func comparable(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
