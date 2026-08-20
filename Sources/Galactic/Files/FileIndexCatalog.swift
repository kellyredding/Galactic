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
        /// When the shard's own top directory was last refused, if it has been
        /// and has not since been walked successfully.
        ///
        /// The reason this is stored rather than inferred: a refused shard and an
        /// empty one both hold zero entries, and the walk that could tell them
        /// apart has already finished by the time anything asks. Without it the
        /// only honest thing a reader can say about either is the number, which
        /// is the same number.
        public let refusedAt: Date?
        /// The `errno` from that refusal.
        public let refusalCode: Int32?
        /// How many directories *inside* the shard the last successful walk was
        /// refused. A shard can be readable at its top and still be missing
        /// most of what is under it.
        public let refusedDirectoryCount: Int

        /// Whether the shard's own top directory is currently unreadable.
        public var isRefused: Bool { refusedAt != nil }

        /// Whether anything at all was withheld from the last walk.
        public var isIncomplete: Bool {
            refusedAt != nil || refusedDirectoryCount > 0
        }
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
                refused_at  REAL    NOT NULL DEFAULT 0,
                refusal_code INTEGER NOT NULL DEFAULT 0,
                refused_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (root_path, name)
            )
            """
        )
        addColumnIfMissing("dirtied_at", "REAL NOT NULL DEFAULT 0")
        addColumnIfMissing("refused_at", "REAL NOT NULL DEFAULT 0")
        addColumnIfMissing("refusal_code", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("refused_count", "INTEGER NOT NULL DEFAULT 0")
        execute(
            """
            CREATE TABLE IF NOT EXISTS roots (
                path       TEXT PRIMARY KEY,
                adopted_at REAL NOT NULL
            )
            """
        )
        execute(
            """
            CREATE TABLE IF NOT EXISTS shard_skips (
                root_path TEXT NOT NULL,
                shard     TEXT NOT NULL,
                name      TEXT NOT NULL,
                PRIMARY KEY (root_path, shard, name)
            )
            """
        )
        // A delta against the derived list rather than the list itself, so an
        // improvement to the built-in one still reaches a reader who has
        // customised theirs. Storing the whole list would freeze them on
        // whatever the default happened to be the day they first changed it.
        //
        // Not keyed by root. What a person means by "don't index this" is one
        // preference, not one per tree they have happened to open — and roots
        // arrive by browsing to them rather than by being configured, so a
        // per-root list would silently not apply to the next one. The built-in
        // list still varies by root, because that part describes what a tree is
        // rather than what anyone wants.
        execute(
            """
            CREATE TABLE IF NOT EXISTS global_skip_list (
                name    TEXT    PRIMARY KEY,
                skipped INTEGER NOT NULL
            )
            """
        )
        adoptAnyPerRootSkipList()
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

    // MARK: - The skip list

    /// What this index has been told to skip, or not to skip, everywhere.
    ///
    /// Lives here rather than in an application because two applications share
    /// one index: a list held per app made the same corpus mean different things
    /// depending on which built it, with nothing recording that they disagreed.
    /// Read through on every walk rather than captured, which is what makes a
    /// change in one application visible to the other without either notifying
    /// anything.
    public func skipListDelta() -> (added: Set<String>, removed: Set<String>) {
        queue.sync {
            var added: Set<String> = []
            var removed: Set<String> = []
            var statement: OpaquePointer?
            let sql = "SELECT name, skipped FROM global_skip_list"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return (added, removed) }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = text(statement, 0)
                if sqlite3_column_int64(statement, 1) == 1 {
                    added.insert(name)
                } else {
                    removed.insert(name)
                }
            }
            return (added, removed)
        }
    }

    /// Record that a name should, or should not, be skipped.
    public func setSkipListEntry(name: String, skipped: Bool) {
        queue.sync {
            let sql = """
                INSERT INTO global_skip_list (name, skipped)
                VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET skipped = excluded.skipped
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, name)
            sqlite3_bind_int64(statement, 2, skipped ? 1 : 0)
            step(statement, "setSkipListEntry")
        }
    }

    /// Forget an override, returning the name to whatever the derived list says.
    public func clearSkipListEntry(name: String) {
        queue.sync {
            let sql = "DELETE FROM global_skip_list WHERE name = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, name)
            step(statement, "clearSkipListEntry")
        }
    }

    /// Replace the set of skipped names a shard's walk met.
    ///
    /// Written with the publish, under the same lease, because it describes the
    /// generation being published and would otherwise disagree with it.
    public func recordEncounteredSkips(
        root: String, shard: String, names: Set<String>
    ) {
        queue.sync {
            var clear: OpaquePointer?
            let clearSQL = "DELETE FROM shard_skips WHERE root_path = ? AND shard = ?"
            if sqlite3_prepare_v2(database, clearSQL, -1, &clear, nil) == SQLITE_OK {
                bindText(clear, 1, root)
                bindText(clear, 2, shard)
                step(clear, "recordEncounteredSkips")
            }
            sqlite3_finalize(clear)

            for name in names {
                var insert: OpaquePointer?
                let sql = """
                    INSERT OR IGNORE INTO shard_skips (root_path, shard, name)
                    VALUES (?, ?, ?)
                    """
                guard sqlite3_prepare_v2(database, sql, -1, &insert, nil) == SQLITE_OK
                else { continue }
                bindText(insert, 1, root)
                bindText(insert, 2, shard)
                bindText(insert, 3, name)
                step(insert, "recordEncounteredSkips")
                sqlite3_finalize(insert)
            }
        }
    }

    /// Which shards of a root met this skipped name when they were walked.
    ///
    /// The answer to "what would un-skipping this change". Empty means nothing,
    /// which is the common case and the point.
    public func shardsEncountering(skip name: String, root: String) -> [String] {
        queue.sync {
            var found: [String] = []
            var statement: OpaquePointer?
            let sql = """
                SELECT shard FROM shard_skips WHERE root_path = ? AND name = ?
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return found }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, root)
            bindText(statement, 2, name)
            while sqlite3_step(statement) == SQLITE_ROW {
                found.append(text(statement, 0))
            }
            return found
        }
    }

    /// The same question asked of the whole index rather than one root.
    ///
    /// What a change to the skip list now costs, since the list stopped being a
    /// per-root thing: a name may be met by shards of several trees, and all of
    /// them are owed a walk.
    public func shardsEncountering(skip name: String) -> [(root: String, shard: String)] {
        queue.sync {
            var found: [(root: String, shard: String)] = []
            var statement: OpaquePointer?
            let sql = """
                SELECT root_path, shard FROM shard_skips WHERE name = ?
                ORDER BY root_path, shard
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return found }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, name)
            while sqlite3_step(statement) == SQLITE_ROW {
                found.append((root: text(statement, 0), shard: text(statement, 1)))
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
    /// - Parameter refusedDirectoryCount: how many directories inside the shard
    ///   this walk was refused. Recorded on the successful path because that is
    ///   where it happens: the shard opened, published a generation, and is
    ///   nonetheless missing whatever sat under those directories.
    public func record(
        root: String, name: String, generation: UInt64, entryCount: Int,
        walkedAt: Date = Date(), walkStartedAt: Date? = nil,
        eventsUUID: String?, eventsID: UInt64?,
        refusedDirectoryCount: Int = 0
    ) {
        queue.sync {
            // A completed walk clears the refusal outright rather than ageing
            // it: reaching here is proof the top directory opened, which is the
            // only thing the stored refusal claimed.
            let sql = """
                INSERT INTO shards
                    (root_path, name, generation, entry_count, walked_at,
                     dirty, events_uuid, events_id,
                     refused_at, refusal_code, refused_count)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, 0, 0, ?9)
                ON CONFLICT(root_path, name) DO UPDATE SET
                    generation = excluded.generation,
                    entry_count = excluded.entry_count,
                    walked_at = excluded.walked_at,
                    dirty = CASE WHEN shards.dirtied_at > ?8 THEN 1 ELSE 0 END,
                    events_uuid = excluded.events_uuid,
                    events_id = excluded.events_id,
                    refused_at = 0,
                    refusal_code = 0,
                    refused_count = excluded.refused_count
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
            sqlite3_bind_int64(statement, 9, Int64(refusedDirectoryCount))
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

    /// Record that a walk was attempted and refused.
    ///
    /// Moves the walk time forward without touching the generation, and clears
    /// the dirty flag. Both halves matter: leaving the time alone would have the
    /// sweep choose this shard on every tick forever, and leaving it dirty would
    /// do the same and jump the queue while doing it. Neither retry can succeed,
    /// because the obstacle is permission rather than staleness, and each one
    /// costs a dialog.
    ///
    /// The shard keeps whatever generation it last published, so a refusal never
    /// destroys an index that was readable when it was built.
    ///
    /// The refusal is also *stored*, which is the whole reason a reader can tell
    /// this shard from an empty one. Both hold zero entries and both report a
    /// recent walk; only this column distinguishes "we were not allowed to look"
    /// from "there was nothing there".
    /// A shard refused on its *first* walk is inserted rather than skipped.
    ///
    /// An update alone silently did nothing for it, because a shard that has
    /// never published has no row to update — so the one directory a reader most
    /// needs to be told about, the one never granted access at all, was the one
    /// absent from the index entirely. It lands at generation zero, which the
    /// load path treats as nothing to map.
    public func noteWalkRefused(root: String, name: String, code: Int32 = 0) {
        queue.sync {
            let sql = """
                INSERT INTO shards
                    (root_path, name, generation, entry_count, walked_at,
                     dirty, refused_at, refusal_code)
                VALUES (?4, ?5, 0, 0, ?1, 0, ?2, ?3)
                ON CONFLICT(root_path, name) DO UPDATE SET
                    walked_at = ?1, dirty = 0, refused_at = ?2, refusal_code = ?3
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(statement, 1, now)
            sqlite3_bind_double(statement, 2, now)
            sqlite3_bind_int64(statement, 3, Int64(code))
            bindText(statement, 4, root)
            bindText(statement, 5, name)
            step(statement, "noteWalkRefused")
        }
    }

    /// Move a shard's event position forward without walking it.
    ///
    /// **A shard nothing happened to is current.** Once a replay has been read
    /// up to some event, every shard it did not mention is as fresh as that
    /// event, and saying so costs nothing — no walk, no generation, no consent
    /// dialog for a directory macOS asks about.
    ///
    /// This exists because a position only ever advanced on publish, and a
    /// publish only happens on a walk. A shard deliberately taken off the
    /// refresh rotation therefore froze its position forever, and since a
    /// root replays from the *oldest* position among its shards, five frozen
    /// ones dragged every launch further back than the last — measured at
    /// 550,799 replayed paths from a day earlier.
    ///
    /// Monotonic in SQL rather than in the caller: two applications may be doing
    /// this at once, and the one with the older idea of now must not win.
    public func advanceEventPosition(
        root: String, name: String, uuid: String, id: UInt64
    ) {
        queue.sync {
            let sql = """
                UPDATE shards SET events_uuid = ?, events_id = ?
                WHERE root_path = ? AND name = ?
                    AND (events_id IS NULL OR events_id < ?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, uuid)
            sqlite3_bind_int64(statement, 2, Int64(bitPattern: id))
            bindText(statement, 3, root)
            bindText(statement, 4, name)
            sqlite3_bind_int64(statement, 5, Int64(bitPattern: id))
            step(statement, "advanceEventPosition")
        }
    }

    public func shards(forRoot root: String) -> [Shard] {
        queue.sync {
            var found: [Shard] = []
            let sql = """
                SELECT name, generation, entry_count, walked_at, dirty,
                       events_uuid, events_id,
                       refused_at, refusal_code, refused_count
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
                            : UInt64(bitPattern: sqlite3_column_int64(statement, 6)),
                        // Zero is the never-refused default every existing row
                        // acquired when the column was added, so it has to read
                        // back as absence rather than as the epoch.
                        refusedAt: Self.date(sqlite3_column_double(statement, 7)),
                        refusalCode: Self.code(sqlite3_column_int64(statement, 8)),
                        refusedDirectoryCount: Int(
                            sqlite3_column_int64(statement, 9)
                        )
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

    /// Carry a per-root skip list into the global one, then retire the table.
    ///
    /// Two roots could in principle disagree about a name, and one of them has
    /// to win — the first read does, which is arbitrary but only reachable by an
    /// index that predates the list being one thing. Preferred to dropping the
    /// rows outright, which would silently discard a customisation.
    private func adoptAnyPerRootSkipList() {
        var probe: OpaquePointer?
        let exists = """
            SELECT 1 FROM sqlite_master
            WHERE type = 'table' AND name = 'skip_list'
            """
        guard
            sqlite3_prepare_v2(database, exists, -1, &probe, nil) == SQLITE_OK
        else { return }
        let present = sqlite3_step(probe) == SQLITE_ROW
        sqlite3_finalize(probe)
        guard present else { return }
        execute(
            """
            INSERT OR IGNORE INTO global_skip_list (name, skipped)
            SELECT name, skipped FROM skip_list
            """
        )
        execute("DROP TABLE skip_list")
    }

    /// Add a column to an index written before that column existed.
    ///
    /// Checked rather than attempted, because a failed `ALTER TABLE` is now
    /// logged, and an expected failure on every launch is noise that trains a
    /// reader to ignore the one that matters.
    ///
    /// Every column reaching here must carry a default, since existing rows
    /// acquire one without being rewritten. That is what keeps a column
    /// addition off the corpus: the mapped shard files are untouched, so no
    /// generation is invalidated and nothing is rewalked to satisfy a schema
    /// change.
    private func addColumnIfMissing(_ column: String, _ definition: String) {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "PRAGMA table_info(shards)", -1, &statement, nil
            ) == SQLITE_OK
        else { return }
        var present = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { present = true }
        }
        sqlite3_finalize(statement)
        guard !present else { return }
        execute("ALTER TABLE shards ADD COLUMN \(column) \(definition)")
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

    /// Sentinel zero read back as absence.
    ///
    /// The column is `NOT NULL DEFAULT 0` because that is what lets it be added
    /// to an existing table without rewriting a row, so the "never happened"
    /// case arrives as an epoch timestamp rather than as SQL `NULL`.
    private static func date(_ seconds: Double) -> Date? {
        seconds == 0 ? nil : Date(timeIntervalSince1970: seconds)
    }

    private static func code(_ raw: Int64) -> Int32? {
        raw == 0 ? nil : Int32(truncatingIfNeeded: raw)
    }
}
