import Foundation

/// The index's own log, at `~/.galactic/logs/index.log`.
///
/// ### Why this is not `GalacticLog`
///
/// `GalacticLog` discards until a host installs a sink, and its documentation
/// is explicit that it is written once at launch and read from the main thread
/// thereafter. The index is the opposite on every count: it runs on background
/// queues, it must record what happened whether or not an application
/// configured anything, and what it records has to survive the process that
/// wrote it — the whole point is being able to read back what the index did
/// over days, across launches, after a crash.
///
/// ### What it is for
///
/// An index maintains itself out of sight. When it goes wrong the symptom is a
/// file that cannot be found, which looks identical to a file that does not
/// exist. This log is how that gets diagnosed after the fact rather than
/// reproduced.
///
/// Lines are `timestamp [category] key=value …` — one event per line, flat, so
/// `grep`, `awk` and a spreadsheet all work without a parser.
public final class FileIndexLog: @unchecked Sendable {

    public static let shared = FileIndexLog()

    /// Rotate at four megabytes, keep five behind the current file.
    ///
    /// Twenty-five megabytes total, bounded regardless of how long the index
    /// runs or how noisy the file system gets. A large checkout can produce
    /// thousands of lines in a minute, and an unbounded log would be the one
    /// part of this effort that grows without limit — which is the failure it
    /// exists to help diagnose.
    ///
    /// Settable rather than constant so rotation can be exercised without
    /// writing four megabytes, the same reason `FileIndexRefreshSweep.targetAge`
    /// is settable.
    public static var rotateAtBytes = 4 * 1024 * 1024
    public static let generationsKept = 5

    /// Serial, and asynchronous to the caller.
    ///
    /// A walk emits a line per shard and the watcher emits one per batch of
    /// file-system events, so logging must never be something a caller waits
    /// on. Serial because the ordering *is* the diagnostic.
    private let queue = DispatchQueue(
        label: "com.kellyredding.galactic.index-log", qos: .utility
    )
    private var handle: FileHandle?
    private var bytesWritten = 0
    /// The inode `handle` is attached to, so another process's rotation can be
    /// noticed. A path comparison cannot see it: the path never changes.
    private var openInode: ino_t?
    /// Serialises rotation against the other applications sharing this index.
    private let rotationLease = FileIndexLock(.log)
    /// Writes since `bytesWritten` was last reconciled with the file.
    private var writesSinceSizeCheck = 0

    /// How often to ask the file how big it actually is.
    ///
    /// `bytesWritten` counts what *this* process wrote, which was the whole
    /// truth while one process wrote. With two, the file grows at the combined
    /// rate and neither counter reaches the threshold until it has written the
    /// threshold itself — so the log settles at roughly the bound times the
    /// number of applications, which is precisely the unbounded growth the
    /// rotation exists to prevent.
    ///
    /// One `fstat` per this many lines is the cost of the counter meaning the
    /// file rather than the writer. Rotation re-checks the size under the lease
    /// anyway, so an eager trigger costs a stat and never a lost generation.
    private static let writesPerSizeCheck = 128
    /// The path `handle` was opened for.
    ///
    /// A cached handle that never re-checks its own path will happily keep
    /// writing to a file nobody is reading: `fileURL` is computed from
    /// `FileIndexPaths`, so if the index location moves, the reader and the
    /// writer end up looking at two different files and the log appears empty.
    /// In a shipping app the location never moves; a test pointing it elsewhere
    /// found this immediately.
    private var openPath: String?

    private lazy var formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init() {}

    public var fileURL: URL {
        FileIndexPaths.logsDirectory.appendingPathComponent("index.log")
    }

    // MARK: - Writing

    /// Record one event.
    ///
    /// - Parameters:
    ///   - category: the subsystem — `walk`, `shard`, `load`, `publish`,
    ///     `watch`, `refresh`, `lock`, `privacy`. Bracketed so a reader can
    ///     grep one subsystem out of an interleaved file.
    ///   - fields: ordered key/value pairs. Ordered rather than a dictionary
    ///     because these lines are read by eye far more often than parsed, and
    ///     a stable column order is most of what makes that possible.
    public func record(
        _ category: String, _ fields: [(String, String)] = []
    ) {
        let stamp = formatter.string(from: Date())
        var line = "\(stamp) [\(category)]"
        for (key, value) in fields {
            let needsQuotes = value.contains(" ") || value.isEmpty
            line += needsQuotes ? " \(key)=\"\(value)\"" : " \(key)=\(value)"
        }
        line += "\n"
        append(line)
    }

    /// Convenience for the shape most call sites want.
    public func record(_ category: String, _ fields: KeyValuePairs<String, Any>) {
        record(category, fields.map { ($0.key, String(describing: $0.value)) })
    }

    private func append(_ line: String) {
        queue.async { [self] in
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil || !handleStillPointsAtTheLiveLog() { openFile() }
            guard let handle else { return }
            handle.write(data)
            bytesWritten += data.count
            writesSinceSizeCheck += 1
            if writesSinceSizeCheck >= Self.writesPerSizeCheck {
                resyncBytesWritten()
            }
            if bytesWritten >= Self.rotateAtBytes { rotate() }
        }
    }

    /// Open the log for appending.
    ///
    /// `O_APPEND` rather than a seek to the end, because the end is not a fact a
    /// process can cache once. Two applications share this index, and each held
    /// its own file offset established at open: every write landed where *that*
    /// process believed the end was, so the second writer overwrote the first
    /// rather than following it. Nothing detected it — the file stayed
    /// well-formed and simply held fewer lines than were written. With
    /// `O_APPEND` the kernel places each write at the true end atomically, which
    /// is the only version of this that survives a second writer.
    private func openFile() {
        try? handle?.close()
        handle = nil
        FileIndexPaths.prepare()
        let descriptor = open(
            fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600
        )
        guard descriptor >= 0 else {
            openPath = nil
            openInode = nil
            bytesWritten = 0
            return
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        openPath = fileURL.path
        writesSinceSizeCheck = 0
        var status = stat()
        if fstat(descriptor, &status) == 0 {
            openInode = status.st_ino
            bytesWritten = Int(status.st_size)
        } else {
            openInode = nil
            bytesWritten = 0
        }
    }

    /// Replace this process's tally with the file's real size.
    private func resyncBytesWritten() {
        writesSinceSizeCheck = 0
        guard let handle else { return }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else { return }
        bytesWritten = Int(status.st_size)
    }

    /// Whether the file this handle is attached to is still the one at
    /// `fileURL`.
    ///
    /// Rotation renames, and a rename moves the name rather than the file. A
    /// handle held across another process's rotation stays bound to the inode
    /// that is now `index.log.1`, so it keeps writing into a rotated generation
    /// while every reader tails the new `index.log`. The path is unchanged
    /// throughout, which is why comparing paths cannot see it and comparing
    /// inodes can.
    private func handleStillPointsAtTheLiveLog() -> Bool {
        guard openPath == fileURL.path, let openInode else { return false }
        var status = stat()
        guard stat(fileURL.path, &status) == 0 else { return false }
        return status.st_ino == openInode
    }

    /// Shift `index.log` down the numbered generations and start a new one.
    ///
    /// Oldest is deleted rather than compressed: the value of an index log
    /// falls off sharply with age, and a compressed tail nobody can `grep`
    /// without decompressing first is worse than no tail.
    /// Only one process may shift the generations.
    ///
    /// Unguarded, two rotations interleave and a generation is lost outright:
    /// both rename `index.log.1` to `.2`, and the second finds nothing there
    /// because the first already moved it — so `.1` ends up holding what `.2`
    /// should, and one file's worth of history is unlinked with nothing
    /// recording that it went.
    ///
    /// Losing the lease is not a failure. It means another process is rotating
    /// right now, so the work is being done; this one only has to stop believing
    /// its own byte count and pick the new file up, which the inode check does
    /// on the next line.
    private func rotate() {
        guard rotationLease.acquire() else {
            try? handle?.close()
            handle = nil
            bytesWritten = 0
            return
        }
        defer { rotationLease.release() }

        // Between reaching the threshold and taking the lease, the winner may
        // have already rotated — in which case this file is new and small, and
        // rotating it again would discard a generation for nothing.
        var status = stat()
        if stat(fileURL.path, &status) == 0,
            Int(status.st_size) < Self.rotateAtBytes
        {
            try? handle?.close()
            handle = nil
            return
        }

        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        let directory = FileIndexPaths.logsDirectory

        let oldest = directory.appendingPathComponent(
            "index.log.\(Self.generationsKept)"
        )
        try? manager.removeItem(at: oldest)

        for generation in stride(from: Self.generationsKept - 1, through: 1, by: -1) {
            let from = directory.appendingPathComponent("index.log.\(generation)")
            let to = directory.appendingPathComponent("index.log.\(generation + 1)")
            if manager.fileExists(atPath: from.path) {
                try? manager.moveItem(at: from, to: to)
            }
        }
        let first = directory.appendingPathComponent("index.log.1")
        try? manager.moveItem(at: fileURL, to: first)

        bytesWritten = 0
        openFile()
        record("log", [("event", "rotated"), ("kept", "\(Self.generationsKept)")])
    }

    /// Flush anything queued. For tests, and for a host shutting down.
    public func drain() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    /// The most recent lines, newest last. For diagnostics and verification.
    public func tail(_ count: Int = 50) -> [String] {
        drain()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        return Array(
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init).suffix(count)
        )
    }
}
