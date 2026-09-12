import Foundation

/// What a restore needs to rebuild one set.
///
/// **Notes are absent by construction** — they live in memory and have no
/// representation here to be tempted by.
///
/// The shape lives in the package rather than in each host because it had
/// already been spelled out once per application before there was a second one.
public struct PersistedFileSet: Codable, Equatable {
    public var id: String
    public var name: String
    /// Absent means true: a record written before sets had names was its
    /// owner's only set.
    public var isDefault: Bool
    public var origin: FileSet.Origin
    public var root: String
    public var openPathRows: [[String]]
    public var selectedPath: String?

    public init(
        id: String = "",
        name: String = "",
        isDefault: Bool = true,
        origin: FileSet.Origin = .user,
        root: String,
        openPathRows: [[String]],
        selectedPath: String?
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.origin = origin
        self.root = root
        self.openPathRows = openPathRows
        self.selectedPath = selectedPath
    }

    /// Every field falls back rather than throwing, so a malformed set costs the
    /// set and not whatever larger document a host has nested it inside. A
    /// record written before a field existed decodes as absent, which is why
    /// adding one needs no migration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? true
        origin =
            try c.decodeIfPresent(String.self, forKey: .origin)
            .flatMap(FileSet.Origin.init(rawValue:)) ?? .user
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        openPathRows =
            try c.decodeIfPresent([[String]].self, forKey: .openPathRows) ?? []
        selectedPath = try c.decodeIfPresent(String.self, forKey: .selectedPath)
    }
}

/// What a restore needs to rebuild every set an owner has.
///
/// Reads either shape. A record with `sets` is a group; one without is the lone
/// set an owner had before sets had names, and is wrapped — so a host's old file
/// loads with nothing to migrate, and a host whose loader discards the whole
/// document on any failure never sees one.
public struct PersistedFileSetGroup: Codable, Equatable {
    public var sets: [PersistedFileSet]
    public var selectedID: String?

    public init(sets: [PersistedFileSet], selectedID: String?) {
        self.sets = sets
        self.selectedID = selectedID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.sets) else {
            sets = [try PersistedFileSet(from: decoder)]
            selectedID = nil
            return
        }
        sets = (try? c.decode([PersistedFileSet].self, forKey: .sets)) ?? []
        selectedID =
            (try? c.decodeIfPresent(String.self, forKey: .selectedID)) ?? nil
    }
}

/// Where a host keeps an owner's sets between launches.
///
/// **The bytes only.** The shape, the results-path filtering and the restore
/// policy are the package's; what a host owns is the file, the container and the
/// write cadence — which is the whole of what actually differs between an app
/// with one owner and an app with one per session.
///
/// Optional by design: a host that supplies no store gets a surface that does
/// not survive relaunch, which is degraded rather than broken.
///
/// **Deliberately not `@MainActor`.** Reading and writing bytes needs no
/// isolation, and requiring it would force the annotation onto whatever type a
/// host already keeps its window state in.
public protocol FileSetStore: AnyObject {
    func save(_ group: PersistedFileSetGroup, forOwner ownerID: String)
    func load(forOwner ownerID: String) -> PersistedFileSetGroup?
}
