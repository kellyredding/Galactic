import Foundation

/// Every browsing context an application has, keyed by whose it is.
///
/// Assist Ant has one owner and hands over a constant; Galaxy will hand over a
/// session id. Both go through here from the first commit rather than the
/// constant case being wired directly and the keyed case arriving as a
/// redesign — the difference between the two apps is then the string they pass.
///
/// **Deliberately not an `ObservableObject`.** Each `FileSet` is one, and a
/// container publishing changes to objects that publish their own is the nested
/// observation trap: a view watching the container is told when a set is created
/// and never when a tab inside one opens. A host takes the set for its owner and
/// observes *that* — which is the rule the agent inbox learned the hard way, and
/// the same reason a count read through a presenter showed whatever it said when
/// the modal opened.
public final class FileSets {

    /// Where a set starts browsing when it is created.
    ///
    /// A closure rather than a value: the answer is the agent's working
    /// directory, which is not known when this is built and is different for
    /// each of Galaxy's sessions. Resolved once per set, at creation, so a
    /// reader who changes their root keeps it.
    private let defaultRoot: (String) -> URL

    private var setsByOwner: [String: FileSet] = [:]

    public init(defaultRoot: @escaping (String) -> URL) {
        self.defaultRoot = defaultRoot
    }

    /// The set for an owner, created on first ask.
    ///
    /// Created rather than optional, because every caller wants one: a reader
    /// arriving at an empty Files tab is the ordinary case, not an error. The
    /// set is empty, which is a state the strip and the picker both answer.
    public func set(forOwner ownerID: String) -> FileSet {
        if let existing = setsByOwner[ownerID] { return existing }
        let created = FileSet(ownerID: ownerID, root: defaultRoot(ownerID))
        setsByOwner[ownerID] = created
        return created
    }

    /// Whether an owner has a set yet, without making one.
    ///
    /// For the questions a host asks about work it might lose — is there
    /// anything to warn about at quit — where creating a set to find out it is
    /// empty would be the wrong shape.
    public func existingSet(forOwner ownerID: String) -> FileSet? {
        setsByOwner[ownerID]
    }

    /// Every set that exists, in no particular order.
    ///
    /// The quit-time check reads this: notes live in memory, so quitting is the
    /// one moment every set has to be asked at once.
    public var allSets: [FileSet] { Array(setsByOwner.values) }

    /// Whether any set anywhere is holding notes.
    public var hasPendingNotes: Bool {
        setsByOwner.values.contains { $0.totalNoteCount > 0 }
    }

    /// How many notes there are altogether, and across how many files.
    ///
    /// What the quit prompt says. Both numbers come from here rather than the
    /// caller adding them up, because "how many files" means files carrying
    /// notes rather than files open — a distinction a host would have to know
    /// the store's shape to get right.
    public var pendingNoteTally: (notes: Int, files: Int) {
        var notes = 0
        var files = 0
        for set in setsByOwner.values {
            notes += set.totalNoteCount
            files += set.notes.annotatedPaths.count
        }
        return (notes, files)
    }

    /// An owner has gone away — a session closed — and takes its set with it.
    ///
    /// The notes go with it, unwarned, and the warning is the caller's job. This
    /// is the mechanism; whether a reader is asked first is a policy each host
    /// answers, because only the host knows whether the owner going away was
    /// something the reader chose.
    public func discard(ownerID: String) {
        setsByOwner[ownerID] = nil
    }
}
