import Foundation
import SQLite3

/// What the index knows *about* itself: which roots are covered, which shards
/// exist, how fresh each one is, and what file-system position it is current
/// as of.
///
/// **It never holds a path from the corpus.** Those are 20 MB of front-coded
/// bytes in a mapped file, and putting them here measured at 4.5× the size for
/// a query that still cannot express a subsequence match. What SQLite is right
/// for is exactly this: a few hundred rows of bookkeeping, updated
/// transactionally, readable by another process, and inspectable by hand when
/// something looks wrong.
public final class FileIndexCatalog: @unchecked Sendable {

    public struct Shard {
        public let root: String
        /// The top-level subtree this shard covers, relative to the root.
        /// Empty means the files directly inside the root.
        public let name: String
        public let generation: UInt64
        public let entryCount: Int
        public let walkedAt: Date
        public let dirty: Bool
        /// The FSEvents stream position this shard reflects.
        ///
        /// Stored with the **volume UUID**, never a `dev_t`. Device numbers are
        /// assigned in mount order and are not stable across reboots, and on an
        /// APFS volume group `st_dev` is identical for `/`, the data volume and
        /// the home directory — so it cannot even tell two volumes apart. A
        /// changed UUID means the event store was discarded and every stored
        /// position with it.
        public let eventsUUID: String?
        public let eventsID: UInt64?
    }

    private var database: OpaquePointer?
    private let queue = DispatchQueue(
        label: "com.kellyredding.galactic.index-catalog"
    )

    public init?(at url: URL = FileIndexPaths.catalogFile) {
        FileIndexPaths.prepare()
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { return nil }
        // Wait rather than refuse. WAL admits one writer at a time, so a second
        // application is refused the instant it asks, and with no timeout every
        // contended write was simply lost. Bounded, because these calls reach
        // the main actor through a synchronous queue: long enough to absorb a
        // single-statement write from another process many times over, short
        // enough that the worst case is not a stall anyone sees.
        sqlite3_busy_timeout(database, Int32(Self.busyTimeoutMilliseconds))
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute(
            """
            CREATE TABLE IF NOT EXISTS shards (
                root_path   TEXT    NOT NULL,
                name        TEXT    NOT NULL,
                generation  INTEGER NOT NULL,
                entry_count INTEGER NOT NULL,
                walked_at   REAL    NOT NULL,
                dirty       INTEGER NOT NULL DEFAULT 0,
                dirtied_at  REAL    NOT NULL DEFAULT 0,
                events_uuid TEXT,
                events_id   INTEGER,
                PRIMARY KEY (root_path, name)
            )
            """
        )
        addDirtiedAtIfMissing()
        execute(
            """
            CREATE TABLE IF NOT EXISTS roots (
                path       TEXT PRIMARY KEY,
                adopted_at REAL NOT NULL
            )
            """
        )
    }

    deinit { if let database { sqlite3_close(database) } }

    // MARK: - Roots

    public func adopt(root: String) {
        queue.sync {
            let sql = "INSERT OR IGNORE INTO roots (path, adopted_at) VALUES (?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, root)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            step(statement, "adopt")
        }
    }

    public func roots() -> [String] {
        queue.sync {
            var found: [String] = []
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    database, "SELECT path FROM roots", -1, &statement, nil
                ) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                found.append(text(statement, 0))
            }
            return found
        }
    }

    // MARK: - Shards

    /// Record a completed walk.
    ///
    /// - Parameter walkStartedAt: when the walk that produced this corpus began.
    ///   A dirty mark raised *after* that instant describes a change the corpus
    ///   cannot contain, so publishing must not clear it. Without this the
    ///   window between a walk starting and its publish landing was a hole:
    ///   marking is not lease-guarded, so an event arriving inside it set a flag
    ///   that the publish then erased, and the rewalk it asked for never
    ///   happened.
    public func record(
        root: String, name: String, generation: UInt64, entryCount: Int,
        walkedAt: Date = Date(), walkStartedAt: Date? = nil,
        eventsUUID: String?, eventsID: UInt64?
    ) {
        queue.sync {
            let sql = """
                INSERT INTO shards
                    (root_path, name, generation, entry_count, walked_at,
                     dirty, events_uuid, events_id)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(root_path, name) DO UPDATE SET
                    generation = excluded.generation,
                    entry_count = excluded.entry_count,
                    walked_at = excluded.walked_at,
                    dirty = CASE WHEN shards.dirtied_at > ?8 THEN 1 ELSE 0 END,
                    events_uuid = excluded.events_uuid,
                    events_id = excluded.events_id
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, root)
            bindText(statement, 2, name)
            sqlite3_bind_int64(statement, 3, Int64(generation))
            sqlite3_bind_int64(statement, 4, Int64(entryCount))
            sqlite3_bind_double(statement, 5, walkedAt.timeIntervalSince1970)
            if let eventsUUID { bindText(statement, 6, eventsUUID) } else {
                sqlite3_bind_null(statement, 6)
            }
            if let eventsID {
                sqlite3_bind_int64(statement, 7, Int64(bitPattern: eventsID))
            } else {
                sqlite3_bind_null(statement, 7)
            }
            // Absent, every mark counts as predating the walk, which is the old
            // unconditional clear — chosen deliberately so a caller that cannot
            // say when it started does not silently start keeping flags forever.
            sqlite3_bind_double(
                statement, 8,
                (walkStartedAt ?? Date.distantFuture).timeIntervalSince1970
            )
            step(statement, "record")
        }
    }

    /// Record that a shard is owed a walk, whether or not it has ever had one.
    ///
    /// `markDirty` updates a row, so it does nothing at all for a shard that was
    /// never published — which is exactly the shard a lost lease leaves behind.
    /// A publish that cannot take the lease writes nothing and never retries, so
    /// without a row saying otherwise the shard is simply missing from the index
    /// and no mechanism is looking for it.
    ///
    /// A placeholder at generation zero is never mapped, because loading skips
    /// dirty rows, and it sorts first for the sweep, because dirty rows do. The
    /// walk timestamp is the epoch rather than now: the shard has genuinely
    /// never been walked to completion, and saying so keeps it at the front of
    /// the queue if the dirty flag is ever cleared by something else.
    public func markPending(root: String, name: String) {
        queue.sync {
            let sql = """
                INSERT INTO shards
                    (root_path, name, generation, entry_count, walked_at,
                     dirty, dirtied_at)
                VALUES (?, ?, 0, 0, 0, 1, ?)
                ON CONFLICT(root_path, name) DO UPDATE SET
                    dirty = 1, dirtied_at = excluded.dirtied_at
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, root)
            bindText(statement, 2, name)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            step(statement, "markPending")
        }
    }

    public func shards(forRoot root: String) -> [Shard] {
        queue.sync {
            var found: [Shard] = []
            let sql = """
                SELECT name, generation, entry_count, walked_at, dirty,
                       events_uuid, events_id
                FROM shards WHERE root_path = ? ORDER BY name
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, root)
            while sqlite3_step(statement) == SQLITE_ROW {
                found.append(
                    Shard(
                        root: root,
                        name: text(statement, 0),
                        generation: UInt64(sqlite3_column_int64(statement, 1)),
                        entryCount: Int(sqlite3_column_int64(statement, 2)),
                        walkedAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(statement, 3)
                        ),
                        dirty: sqlite3_column_int64(statement, 4) != 0,
                        eventsUUID: sqlite3_column_type(statement, 5) == SQLITE_NULL
                            ? nil : text(statement, 5),
                        eventsID: sqlite3_column_type(statement, 6) == SQLITE_NULL
                            ? nil
                            : UInt64(bitPattern: sqlite3_column_int64(statement, 6))
                    )
                )
            }
            return found
        }
    }

    public func markDirty(root: String, name: String) {
        queue.sync {
            var statement: OpaquePointer?
            let sql = """
                UPDATE shards SET dirty = 1, dirtied_at = ?
                WHERE root_path = ? AND name = ?
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            bindText(statement, 2, root)
            bindText(statement, 3, name)
            step(statement, "markDirty")
        }
    }

    /// The shard that has gone longest without being walked.
    ///
    /// This is the whole mechanism behind the staggered refresh: rather than
    /// scheduling anything, ask which part of the index is stalest and redo
    /// that one. Dirty shards come first, because something has already told
    /// us they are wrong.
    public func stalestShard(forRoot root: String) -> Shard? {
        shards(forRoot: root)
            .sorted {
                if $0.dirty != $1.dirty { return $0.dirty }
                return $0.walkedAt < $1.walkedAt
            }
            .first
    }

    public func remove(root: String, name: String) {
        queue.sync {
            var statement: OpaquePointer?
            let sql = "DELETE FROM shards WHERE root_path = ? AND name = ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, root)
            bindText(statement, 2, name)
            step(statement, "remove")
        }
    }

    /// Drop a root and every shard recorded under it.
    ///
    /// A root that a wider one already contains has to stop being a candidate
    /// here, not merely stop being walked. Nothing sweeps it once it is served
    /// from above, so leaving its rows behind leaves an index that ages without
    /// bound and still answers for the subtree it names — the stalest possible
    /// source, preferred over the fresh one because it is the nearer match.
    ///
    /// The shard files are left on disk. They are unreachable without these
    /// rows, and reclaiming them is the business of a sweep over the whole
    /// index rather than of whichever root happened to notice.
    public func forget(root: String) {
        queue.sync {
            for sql in [
                "DELETE FROM shards WHERE root_path = ?",
                "DELETE FROM roots WHERE path = ?",
            ] {
                var statement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                        == SQLITE_OK
                else { continue }
                defer { sqlite3_finalize(statement) }
                bindText(statement, 1, root)
                step(statement, "forget")
            }
        }
    }

    // MARK: - Plumbing

    /// Add `dirtied_at` to an index written before the column existed.
    ///
    /// Checked rather than attempted, because a failed `ALTER TABLE` is now
    /// logged, and an expected failure on every launch is noise that trains a
    /// reader to ignore the one that matters.
    private func addDirtiedAtIfMissing() {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "PRAGMA table_info(shards)", -1, &statement, nil
            ) == SQLITE_OK
        else { return }
        var present = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == "dirtied_at" { present = true }
        }
        sqlite3_finalize(statement)
        guard !present else { return }
        execute(
            "ALTER TABLE shards ADD COLUMN dirtied_at REAL NOT NULL DEFAULT 0"
        )
    }

    /// How long a contended write may wait before it is treated as failed.
    ///
    /// Waiting is SQLite's job here, not this class's. A retry loop layered on
    /// top was measured and removed: with the timeout in place it never fired,
    /// and with the timeout absent it made matters worse than doing nothing —
    /// four hundred and fifty of six hundred writes lost against two hundred
    /// and forty — because an immediate retry is a spin that holds the lock
    /// contended rather than letting the other writer finish.
    private static let busyTimeoutMilliseconds = 250

    /// Run a statement to completion, and say so when it does not.
    ///
    /// Every mutating method used to discard this result, which made a refused
    /// write and a successful one the same event as far as the caller and the
    /// log were concerned. Since the index heals itself by writing to the
    /// catalog — recording a shard as owed, marking one dirty — a write that
    /// vanishes quietly disables the recovery rather than delaying it.
    @discardableResult
    private func step(_ statement: OpaquePointer?, _ what: String) -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            FileIndexLog.shared.record(
                "catalog",
                [
                    ("event", "write-failed"), ("statement", what),
                    ("code", "\(result)"),
                ]
            )
            return false
        }
        return true
    }

    private func execute(_ sql: String) {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            FileIndexLog.shared.record(
                "catalog",
                [("event", "exec-failed"), ("sql", String(sql.prefix(40)))]
            )
            return
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }
}
