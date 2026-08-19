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
                events_uuid TEXT,
                events_id   INTEGER,
                PRIMARY KEY (root_path, name)
            )
            """
        )
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
            sqlite3_step(statement)
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

    public func record(
        root: String, name: String, generation: UInt64, entryCount: Int,
        walkedAt: Date = Date(), eventsUUID: String?, eventsID: UInt64?
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
                    dirty = 0,
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
            sqlite3_step(statement)
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
            let sql = "UPDATE shards SET dirty = 1 WHERE root_path = ? AND name = ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, root)
            bindText(statement, 2, name)
            sqlite3_step(statement)
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
            sqlite3_step(statement)
        }
    }

    // MARK: - Plumbing

    private func execute(_ sql: String) {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }
}
