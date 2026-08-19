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
    public static let rotateAtBytes = 4 * 1024 * 1024
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
            if handle == nil { openFile() }
            guard let handle else { return }
            handle.write(data)
            bytesWritten += data.count
            if bytesWritten >= Self.rotateAtBytes { rotate() }
        }
    }

    private func openFile() {
        FileIndexPaths.prepare()
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        bytesWritten = (try? handle?.seekToEnd()).flatMap { Int($0) } ?? 0
    }

    /// Shift `index.log` down the numbered generations and start a new one.
    ///
    /// Oldest is deleted rather than compressed: the value of an index log
    /// falls off sharply with age, and a compressed tail nobody can `grep`
    /// without decompressing first is worse than no tail.
    private func rotate() {
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
