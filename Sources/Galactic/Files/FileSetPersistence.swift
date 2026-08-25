import Foundation

/// What a restore needs to rebuild a set.
///
/// Three fields, and provably the minimum: `FileSet` exposes exactly these as
/// its persistable surface, and `restore(openPathRows:selectedPath:)` takes
/// precisely two of them. **Notes are absent by construction** — they live in
/// memory and have no representation here to be tempted by.
///
/// The shape lives in the package rather than in each host because it had
/// already been spelled out once per application before there was a second one,
/// and a third spelling was about to be written.
public struct PersistedFileSet: Codable, Equatable {
    public var root: String
    public var openPathRows: [[String]]
    public var selectedPath: String?

    public init(
        root: String, openPathRows: [[String]], selectedPath: String?
    ) {
        self.root = root
        self.openPathRows = openPathRows
        self.selectedPath = selectedPath
    }

    /// Every field falls back rather than throwing, so a malformed set costs the
    /// set and not whatever larger document a host has nested it inside.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        openPathRows =
            try c.decodeIfPresent([[String]].self, forKey: .openPathRows) ?? []
        selectedPath = try c.decodeIfPresent(String.self, forKey: .selectedPath)
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
