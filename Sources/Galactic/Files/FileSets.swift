import Foundation

/// Every owner's sets, keyed by whose they are.
///
/// Assist Ant has one owner and hands over a constant; Galaxy hands over a
/// session id. Each owner has a `FileSetGroup` — its default set and any others
/// it has made — created on first ask.
///
/// **Deliberately not an `ObservableObject`.** Each group and each set is one,
/// and a container publishing changes to objects that publish their own is the
/// nested observation trap: a view watching the container is told when a group
/// is created and never when a tab inside one opens. A host takes the group for
/// its owner and observes *that*.
public final class FileSets {

    /// Where an owner's default set starts browsing, resolved once when its
    /// group is created — the agent's working directory in Galaxy, which differs
    /// per session and is not known when this is built.
    private let defaultRoot: (String) -> URL

    private var groupsByOwner: [String: FileSetGroup] = [:]

    public init(defaultRoot: @escaping (String) -> URL) {
        self.defaultRoot = defaultRoot
    }

    /// An owner's sets, created holding just the default on first ask.
    public func group(forOwner ownerID: String) -> FileSetGroup {
        if let existing = groupsByOwner[ownerID] { return existing }
        let created = FileSetGroup(
            ownerID: ownerID, defaultRoot: defaultRoot(ownerID)
        )
        groupsByOwner[ownerID] = created
        return created
    }

    /// An owner's sets if it has any yet, without making them — for questions
    /// about work that might be lost, where making an empty group to find out
    /// would be the wrong shape.
    public func existingGroup(forOwner ownerID: String) -> FileSetGroup? {
        groupsByOwner[ownerID]
    }

    public var allGroups: [FileSetGroup] { Array(groupsByOwner.values) }

    /// Every set of every owner, in no particular order.
    public var allSets: [FileSet] { groupsByOwner.values.flatMap(\.sets) }

    public var hasPendingNotes: Bool {
        allSets.contains { $0.totalNoteCount > 0 }
    }

    /// What the quit prompt says: the notes, and the files holding them.
    ///
    /// Files are counted by path, so one file annotated in two sets is one file.
    public var pendingNoteTally: (notes: Int, files: Int) {
        var notes = 0
        var paths: Set<String> = []
        for set in allSets {
            notes += set.totalNoteCount
            paths.formUnion(set.notes.annotatedPaths)
        }
        return (notes, paths.count)
    }

    /// An owner has gone away and takes its sets with it. The notes go too,
    /// unwarned — whether to ask first is the host's policy.
    public func discard(ownerID: String) {
        groupsByOwner[ownerID] = nil
    }
}
