import Foundation

/// Walks a root and produces a `FileCorpus`.
///
/// ### Why `getattrlistbulk` and not `readdir`
///
/// Measured on 156,993 entries, `readdir` runs at 128,800 entries/sec against
/// bulk's 92,000 — so this deliberately takes the slower call. It wins anyway
/// because the index needs a modification time and the file flags for *every*
/// entry, and bulk returns them in the same syscall that returns the name.
/// Getting them alongside `readdir` costs an `fstatat` per entry, which more
/// than gives back the forty percent.
///
/// ### The three things this walk must not do
///
/// **Materialise a dataless file.** `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`
/// defaults to *on*, which the `setiopolicy_np` man page denies and a
/// measurement confirms. Under the default, walking a home directory pulls
/// down every file in the user's cloud storage. The opt-out below is per
/// thread, so it is asserted by whoever is walking rather than assumed from
/// somewhere else.
///
/// **Cross a firmlink.** On an APFS volume group `/Users` is a firmlink and
/// `st_dev` is *identical* on both sides of it, so the usual device comparison
/// does not notice the crossing and a walk from `/` indexes every user file
/// twice. `SF_FIRMLINK` is the only reliable signal, and it arrives in the
/// same bulk read.
///
/// **Loop.** See `visited`.
public enum FileCorpusBuilder {

    /// Directory names never descended into.
    ///
    /// Chosen to be the noise every project has, and no more than that.
    /// Deliberately absent: `lib`, `src`, `bin` and `vendor`. `lib` is
    /// dependencies in Crystal and source in Ruby; `vendor` is checked-in
    /// source often enough to matter. Hiding a reader's own code is a worse
    /// failure than showing them a build directory, so where a name is
    /// genuinely ambiguous it stays in.
    public static let defaultSkipList: Set<String> = [
        // Version control
        ".git", ".hg", ".svn",
        // Node
        "node_modules", "bower_components", ".next", ".nuxt", "dist",
        // Swift and Xcode
        ".build", "build", "DerivedData", ".swiftpm", "Pods",
        // Ruby
        ".bundle", "tmp", "log",
        // Python
        "__pycache__", ".venv", "venv", ".tox", ".mypy_cache",
        ".pytest_cache", ".ruff_cache",
        // Rust, and other build output
        "target", ".gradle", ".terraform", ".dart_tool",
        // Caches and tooling
        ".cache", ".parcel-cache", ".turbo", "coverage", ".idea",
        // The index's own storage. Without this it indexes itself — thirty
        // megabytes of its own shards — and worse, every publish writes there,
        // which the watcher then reports as file-system activity, which churns
        // the overlay. A loop that costs a little on every pass.
        ".galactic",
    ]

    /// Also skipped when the root takes in the user's home directory.
    ///
    /// Not merged into the list above, because these are wrong for a repository:
    /// a project may legitimately hold a directory called `Library`, and
    /// skipping it there would hide real source. They belong to the home
    /// directory specifically — a container the walk cannot afford to enter,
    /// since the walk caps and reports truncation, and one enormous directory
    /// otherwise spends the whole corpus before reaching anything a reader
    /// wanted.
    public static let homeSkipList: Set<String> = defaultSkipList.union([
        "Library",
        "Photos Library.photoslibrary",
        "OrbStack",
    ])

    /// The list for a root, decided by what the root is.
    ///
    /// A property of the index rather than of whichever application opened it.
    /// Every host used to supply its own, which made the same corpus mean two
    /// different things depending on who built it: two applications sharing a
    /// root would publish the same shard with different contents and each
    /// rewalk would replace the other's, forever, with nothing recording that
    /// they disagreed. Deriving it here means they cannot disagree — the answer
    /// is a function of the root, and both compute it from the same code.
    public static func skipList(forRoot root: URL) -> Set<String> {
        coversHomeDirectory(FilePaths.canonical(root))
            ? homeSkipList : defaultSkipList
    }

    /// Whether a root is the home directory or something containing it.
    static func coversHomeDirectory(_ canonicalRoot: String) -> Bool {
        let home = FilePaths.canonical(
            URL(fileURLWithPath: NSHomeDirectory())
        )
        return canonicalRoot == home
            || FilePaths.relative(home, under: canonicalRoot) != nil
    }

    /// How deep to descend.
    ///
    /// A guard against a pathological tree rather than a policy — nothing a
    /// person navigates is this deep, and the cycle case is handled by
    /// identity rather than by depth.
    public static let depthCap = 24

    /// 128 KB, measured as the point where a larger buffer stops helping.
    private static let bufferSize = 128 * 1024

    /// Walk `root`, reporting progress as it goes.
    ///
    /// `onProgress` is called on the walking thread with the running entry
    /// count. It is a *count* and nothing more: the index it replaced handed
    /// back batches of files, and every batch triggered a full re-rank, which
    /// is how one walk became sixty-three overlapping ranking passes.
    /// Walk one shard of a root.
    ///
    /// A shard is a top-level subtree, and the empty name means the entries
    /// sitting directly in the root. Splitting a walk this way is what makes
    /// the index refreshable in pieces: a change under one subtree rewrites
    /// that subtree's bytes and leaves the rest of the index untouched, and
    /// the staggered rescan has something smaller than "everything" to redo.
    ///
    /// Paths stay relative to `root` in every shard, so shards of one root
    /// concatenate into one corpus without rewriting a single byte.
    public static func buildShard(
        root: URL,
        shard: String,
        skipping skipList: Set<String> = defaultSkipList,
        isCancelled: () -> Bool = { false },
        onProgress: (Int) -> Void = { _ in }
    ) -> FileCorpus {
        build(
            root: root,
            subtree: shard,
            // The root's own shard records the top-level entries and descends
            // into none of them: everything below belongs to another shard.
            depthCap: shard.isEmpty ? 0 : depthCap,
            skipping: skipList,
            isCancelled: isCancelled,
            onProgress: onProgress
        )
    }

    /// The top-level names a root divides into, plus the root's own shard.
    public static func shardNames(
        of root: URL, skipping skipList: Set<String> = defaultSkipList
    ) -> [String] {
        var names = [""]
        let corpus = buildShard(root: root, shard: "", skipping: skipList)
        for index in 0..<corpus.entryCount where corpus.isDirectory(at: index) {
            names.append(corpus.relativePath(at: index))
        }
        return names
    }

    public static func build(
        root: URL,
        subtree: String = "",
        depthCap: Int = depthCap,
        skipping skipList: Set<String> = defaultSkipList,
        isCancelled: () -> Bool = { false },
        onProgress: (Int) -> Void = { _ in }
    ) -> FileCorpus {
        // Per thread, before anything is enumerated. Enumeration itself is a
        // materialisation trigger, so this cannot wait until the first file.
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )

        let rootPath = FilePaths.canonical(root)
        var writer = FileCorpusWriter(reservingCapacity: 200_000)

        /// Directories already walked, by device and inode.
        ///
        /// The walk this replaces refused to descend into a symlinked
        /// directory at all. That terminated, and it was wrong: on this
        /// machine `~/projects/implementation-plans` is a symlink into a sync
        /// target, so every plan written this year was invisible to the picker
        /// and nothing reported it.
        ///
        /// A link pointing at an ancestor is the hazard the refusal was
        /// avoiding, and identity is the honest instrument against it — the
        /// ancestor's `(device, inode)` is already here, so the descent stops,
        /// while a link to a genuine sibling tree is walked exactly once.
        /// Only symlinked directories are recorded here.
        ///
        /// A real directory cannot participate in a cycle — the file system
        /// does not permit hard links to directories — so identifying every
        /// directory would mean an extra `stat` per directory to guard against
        /// something that cannot happen. Measured on this machine that was
        /// 85,095 wasted syscalls and a fifth of the walk.
        var visited: Set<DeviceInode> = []
        if let identity = DeviceInode(path: rootPath) { visited.insert(identity) }

        let start =
            subtree.isEmpty ? rootPath : rootPath + "/" + subtree
        var queue: [(path: String, relative: [UInt8], depth: Int)] = [
            (start, Array(subtree.utf8), 0)
        ]
        var head = 0
        var count = 0

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize, alignment: 8
        )
        defer { buffer.deallocate() }

        while head < queue.count {
            if isCancelled() { break }
            let (directory, relative, depth) = queue[head]
            head += 1

            let descriptor = open(directory, O_RDONLY, 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }

            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr =
                attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
                | attrgroup_t(ATTR_CMN_NAME)
                | attrgroup_t(ATTR_CMN_DEVID)
                | attrgroup_t(ATTR_CMN_OBJTYPE)
                | attrgroup_t(ATTR_CMN_MODTIME)
                | attrgroup_t(ATTR_CMN_FLAGS)

            while true {
                let returned = getattrlistbulk(
                    descriptor, &request, buffer, bufferSize,
                    UInt64(FSOPT_PACK_INVAL_ATTRS)
                )
                if returned <= 0 { break }

                var cursor = UnsafeRawPointer(buffer)
                for _ in 0..<returned {
                    let entry = Entry(cursor)
                    cursor = cursor.advanced(by: entry.length)
                    guard let name = entry.name, !entry.nameIsDot else { continue }

                    // A dataless directory holds its contents in the cloud.
                    // Descending would be the download the io policy above
                    // exists to prevent.
                    if entry.flags & UInt32(SF_DATALESS) != 0 { continue }

                    let isDirectory = entry.objectType == UInt32(VDIR.rawValue)
                    let isLink = entry.objectType == UInt32(VLNK.rawValue)

                    // A name becomes a `String` only when something has to
                    // compare it against the skip list, which is directories
                    // and links. The three hundred thousand files in a tree
                    // this size never pay for one.
                    if isDirectory || isLink {
                        if entry.flags & UInt32(SF_FIRMLINK) != 0 { continue }
                        if skipList.contains(String(decoding: name, as: UTF8.self)) {
                            continue
                        }
                    }

                    var childIsDirectory = isDirectory
                    var linkIdentity: DeviceInode?
                    if isLink {
                        // Resolved rather than skipped, which is the bug fix.
                        var resolved = stat()
                        let childPath = Self.join(directory, name)
                        guard stat(childPath, &resolved) == 0 else { continue }
                        childIsDirectory = resolved.st_mode & S_IFMT == S_IFDIR
                        linkIdentity = DeviceInode(
                            device: resolved.st_dev, inode: resolved.st_ino
                        )
                    }

                    writer.add(
                        parent: relative[...],
                        name: name,
                        modified: entry.modified,
                        isDirectory: childIsDirectory
                    )
                    count += 1

                    guard childIsDirectory, depth + 1 <= depthCap else { continue }
                    if let linkIdentity, !visited.insert(linkIdentity).inserted {
                        continue
                    }
                    queue.append(
                        (
                            Self.join(directory, name),
                            Array(writer.lastEntryBytes),
                            depth + 1
                        )
                    )
                }
                onProgress(count)
            }
        }

        onProgress(count)
        return writer.finish(root: rootPath)
    }

    /// A parent path and a child name, joined without an intermediate array.
    private static func join(
        _ directory: String, _ name: UnsafeRawBufferPointer
    ) -> String {
        var bytes = Array(directory.utf8)
        bytes.append(0x2F)
        bytes.append(contentsOf: name)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// One entry as `getattrlistbulk` packed it.
    ///
    /// Read through `loadUnaligned` rather than a mirrored C struct, because
    /// the kernel packs attributes in *bit order* with each one's own
    /// alignment, and a struct that disagrees by a single padding byte reads
    /// every field after it from the wrong place — silently, as plausible
    /// values.
    private struct Entry {
        let length: Int
        /// The raw name bytes, which is what the arena wants. Turning every
        /// one into a `String` was an allocation per file in the tree.
        let name: UnsafeRawBufferPointer?
        let nameIsDot: Bool
        let device: Int32
        let objectType: UInt32
        let modified: Date?
        let flags: UInt32

        init(_ base: UnsafeRawPointer) {
            length = Int(base.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            // 4: attribute_set_t returned (five bitmaps).
            let nameOffset = base.loadUnaligned(
                fromByteOffset: 24, as: Int32.self
            )
            let nameLength = base.loadUnaligned(
                fromByteOffset: 28, as: UInt32.self
            )
            if nameLength > 1 {
                let bytes = base.advanced(by: 24 + Int(nameOffset))
                let view = UnsafeRawBufferPointer(
                    start: bytes, count: Int(nameLength) - 1
                )
                name = view
                nameIsDot =
                    (view.count == 1 && view[0] == 0x2E)
                    || (view.count == 2 && view[0] == 0x2E && view[1] == 0x2E)
            } else {
                name = nil
                nameIsDot = true
            }
            device = base.loadUnaligned(fromByteOffset: 32, as: Int32.self)
            objectType = base.loadUnaligned(fromByteOffset: 36, as: UInt32.self)
            let seconds = base.loadUnaligned(fromByteOffset: 40, as: Int64.self)
            modified = seconds > 0
                ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
            flags = base.loadUnaligned(fromByteOffset: 56, as: UInt32.self)
        }
    }
}

/// A directory's identity, which is what a cycle guard has to compare.
///
/// Not the path: two paths reach the same directory whenever a symlink is
/// involved, and that is precisely the case being guarded.
struct DeviceInode: Hashable {
    /// `dev_t` is already a signed 32-bit value on this platform, and it is
    /// signed for a reason: a device id with its high bit set is ordinary, and
    /// this walk found one under a home directory. Converting it through
    /// `UInt32` on the way in traps — "Negative value is not representable" —
    /// after three quarters of a million entries, which is exactly the kind of
    /// crash that only ever happens on someone else's machine.
    let device: dev_t
    let inode: UInt64

    init(device: dev_t, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }

    /// For a directory whose device the bulk read already reported, so only
    /// the inode needs asking for.
    init?(device: dev_t, path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.device = device
        inode = info.st_ino
    }
}
