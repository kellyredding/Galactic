import Foundation

/// What a restore needs to rebuild a set.
///
/// What `FileSet` exposes as its persistable surface, and no more:
/// `restore(openPathRows:selectedPath:)` takes two of these and
/// `noteFollowedAgentRoot` the last. **Notes are absent by construction** —
/// they live in memory and have no representation here to be tempted by.
///
/// The shape lives in the package rather than in each host because it had
/// already been spelled out once per application before there was a second one,
/// and a third spelling was about to be written.
public struct PersistedFileSet: Codable, Equatable {
    public var root: String
    public var openPathRows: [[String]]
    public var selectedPath: String?

    /// Carried across a relaunch so the first visit to a restored set does not
    /// read a nil memory as the agent having moved, and re-root away from the
    /// root the reader chose before quitting.
    public var lastFollowedAgentRoot: String?

    public init(
        root: String, openPathRows: [[String]], selectedPath: String?,
        // Defaulted so every existing caller keeps compiling — a host with no
        // agent has nothing to pass.
        lastFollowedAgentRoot: String? = nil
    ) {
        self.root = root
        self.openPathRows = openPathRows
        self.selectedPath = selectedPath
        self.lastFollowedAgentRoot = lastFollowedAgentRoot
    }

    /// Every field falls back rather than throwing, so a malformed set costs the
    /// set and not whatever larger document a host has nested it inside. A
    /// record written before a field existed decodes as absent, which is why
    /// adding one needs no migration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        openPathRows =
            try c.decodeIfPresent([[String]].self, forKey: .openPathRows) ?? []
        selectedPath = try c.decodeIfPresent(String.self, forKey: .selectedPath)
        lastFollowedAgentRoot = try c.decodeIfPresent(
            String.self, forKey: .lastFollowedAgentRoot
        )
    }
}

/// Where a host keeps a set between launches.
///
/// **The bytes only.** The shape, the results-path filtering and the restore
/// policy are the package's; what a host owns is the file, the container and the
/// write cadence — which is the whole of what actually differs between an app
/// with one set and an app with one per session.
///
/// Optional by design: a host that supplies no store gets a surface that does
/// not survive relaunch, which is degraded rather than broken.
///
/// **Deliberately not `@MainActor`.** Reading and writing bytes needs no
/// isolation, and requiring it would force the annotation onto whatever type a
/// host already keeps its window state in — which in one app meant every
/// unrelated caller of that type suddenly needing a hop.
public protocol FileSetStore: AnyObject {
    func save(_ state: PersistedFileSet, forOwner ownerID: String)
    func load(forOwner ownerID: String) -> PersistedFileSet?
}
