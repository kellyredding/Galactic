import Foundation

/// Keeps the index from drifting, by rewalking the stalest shard at intervals.
///
/// ### Why this exists even though the index is watched
///
/// File-system events are not a log that can be replayed to arrive at the
/// truth — Apple's own header says so outright. The kernel drops a non-Apple
/// watcher's entire queue under load, and a large checkout is exactly that
/// load. So the watcher keeps the index current *most* of the time, and this
/// makes sure that being wrong is temporary rather than permanent.
///
/// An overflow does usually announce itself: `FileIndexWatcher` handles the
/// kernel's own must-scan-subdirs flag and marks the shard dirty, and a
/// discarded event store shows up as a changed volume identifier. This is the
/// backstop for whatever gets past both — which is why a dirty shard and a
/// merely old one are not treated as the same thing.
///
/// ### Why one shard at a time
///
/// Refreshing everything on a schedule would put the entire cost in one
/// moment, which on a home directory is half a minute of walking. Asking
/// instead for whichever shard has gone longest without being walked spreads
/// the same work across the hour, and it self-corrects: a shard marked dirty
/// by a dropped event jumps the queue.
///
/// A second refresh may overlap the first, and only for one reason: a walk that
/// blocks would otherwise stop every other shard from being refreshed at all.
/// The cap is deliberately small — see `maxConcurrentRefreshes`.
///
/// ### A re-walk is not free, and not only in time
///
/// The picker was originally built never to re-walk at all, and one of the two
/// reasons was this: **entering a protected directory costs a consent prompt**,
/// so a walk on a timer asks the reader for permission on a schedule. The other
/// reason — that a reader watched a finished corpus be replaced by one counting
/// up from zero — is answered by refreshing one shard in the background, which
/// is what this does. The permission cost is not answered, and re-walking a
/// home directory hourly asks about Desktop, Documents, Downloads, Movies,
/// Music and Pictures once per pass each.
///
/// That is a live constraint rather than a historical note. The case for
/// re-walking is that the kernel drops a non-Apple watcher's queue under load,
/// and the load in question is a build or a checkout — which happens in project
/// trees, not in `~/Pictures`. So the directories least likely to need this
/// backstop are the only ones that cost a prompt to re-check, and anything
/// added here should account for that rather than rediscover it.
/// ### Why this is an actor and has no timer
///
/// Selecting a shard is a database open and a query, and doing that on the
/// main actor put file I/O on the thread drawing the window once a minute —
/// and, once a dirty backlog drains back-to-back, once per shard in quick
/// succession. Small, but the same category of thing as the stall this whole
/// mechanism exists to prevent.
///
/// A `Timer` needs a run loop, which an actor has no business borrowing, so
/// the cadence is a sleeping task instead. That is not merely equivalent: a
/// main-run-loop timer does not fire while that run loop is blocked, which is
/// exactly the condition under which the backstop is most needed.
public actor FileIndexRefreshSweep {

    public static let shared = FileIndexRefreshSweep()

    /// How stale a shard may be before it is worth rewalking.
    public static var targetAge: TimeInterval = 3_600

    /// How often to consider one. A minute is frequent enough to reach every
    /// shard of a large root inside the target age, and rare enough that the
    /// question costs nothing when the answer is "nothing yet".
    public static var tickInterval: TimeInterval = 60

    /// How long a consent-protected shard is left alone after a walk that
    /// came back incomplete.
    ///
    /// The policy above — a protected directory is eligible only when
    /// something reported it wrong — assumed a dirty mark names a directory.
    /// A replay does not: one marked all 44 shards at once, and Music was
    /// selected on that basis. A day is long enough that a prompt cannot
    /// recur on any schedule a reader would notice.
    public static var refusalBackoff: TimeInterval = 86_400

    /// The sleeping task that provides the cadence, and the record of whether
    /// the sweep is running at all.
    private var loop: Task<Void, Never>?
    /// Passes started and not yet finished, so `stop()` can mean it.
    ///
    /// Keyed so a pass can retire itself. A drain chain runs for as long as
    /// there is a backlog — forty-four shards after a stale-cursor replay,
    /// arriving back to back — and a list emptied only by `stop()` would hold
    /// a finished task for every one of them for the life of the process.
    private var inFlightPasses: [Int: Task<Void, Never>] = [:]
    private var nextPassID = 0
    /// Whether a follow-up pass is already queued for a dirty backlog.
    private var backlogDrainScheduled = false
    private var roots: Set<String> = []
    /// Which shards are being refreshed right now, as `root` and name.
    ///
    /// This was a single flag, which meant one slow walk stopped the sweep
    /// entirely rather than stopping itself: a consent dialog left unanswered
    /// held a walk for twenty minutes, and in those twenty minutes no shard of
    /// any root was refreshed, because every tick saw the flag and returned.
    /// Tracking which shard is busy lets the rest of the index keep moving past
    /// one that is stuck.
    ///
    /// Internal so a test can hold a shard busy and watch the sweep route past
    /// it, which is the behaviour rather than an implementation detail. Reached
    /// through `hold(shard:inRoot:)` now that mutating it means entering an
    /// actor, which a `defer` cannot do.
    var inFlight: Set<String> = []
    private let log = FileIndexLog.shared

    /// The root served last, so the next pass starts after it.
    ///
    /// Sorted order plus returning after the first eligible shard made position
    /// in the alphabet into policy. One home directory never noticed; an
    /// application with a session per tab would have early roots refreshed
    /// indefinitely and late ones never, with nothing in the log to say why.
    private var lastServedRoot: String?

    /// How many refreshes may overlap.
    ///
    /// More than one so a stuck shard cannot block the others, and few, because
    /// the reason this refreshes one shard at a time is that walking is
    /// expensive. Two is enough to route around a blockage without turning a
    /// backstop into a second indexing pass.
    public static var maxConcurrentRefreshes = 2

    init() {}

    /// Hold a shard busy, as a walk in progress would.
    ///
    /// A method rather than direct access to `inFlight`, now that mutating it
    /// means entering an actor and a `defer` cannot do that.
    func hold(shard: String, inRoot root: String) {
        inFlight.insert(Self.inFlightKey(root: root, shard: shard))
    }

    func releaseAll() {
        inFlight.removeAll()
    }

    /// Whether the sweep runs a cadence of its own.
    ///
    /// A knob like `targetAge`, and for the same reason: this is a backstop
    /// that acts on its own schedule, so anything asserting on a corpus it did
    /// not just build is racing it. In an application that is the point. In a
    /// test that indexes a tree and then asserts what is in it, a background
    /// pass rewalking that tree is indistinguishable from a bug, and the test
    /// exercising the sweep is the one that wants it.
    public static var isEnabled = true

    public func add(canonicalRoot root: String) {
        roots.insert(root)
        guard Self.isEnabled else { return }
        startIfNeeded()
    }

    /// Stop, and wait for whatever was already underway.
    ///
    /// Waiting is the part that matters. A timer on the main run loop could
    /// only fire when the main actor was free, so invalidating it was enough —
    /// nothing could be halfway through a walk at that moment. On its own
    /// executor a pass can be anywhere, and a pass that outlives the stop goes
    /// on to publish under whichever root is registered next.
    public func stop() async {
        let running = loop
        running?.cancel()
        loop = nil
        roots.removeAll()

        // The cadence task first, and that order is load-bearing. It is the one
        // that may be *inside* a pass rather than asleep, and a pass that is
        // mid-refresh goes on to schedule a drain when it finds the shard was
        // dirty — after any drain loop that ran before it. Waiting here means
        // every drain this stop has to account for already exists.
        _ = await running?.value

        for task in inFlightPasses.values { task.cancel() }
        while !inFlightPasses.isEmpty {
            let waiting = inFlightPasses
            inFlightPasses = [:]
            for task in waiting.values { _ = await task.value }
        }
        backlogDrainScheduled = false
    }

    private func startIfNeeded() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.tickInterval * 1_000_000_000)
                )
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
        log.record(
            "sweep",
            [
                ("event", "started"),
                ("tick", "\(Int(Self.tickInterval))s"),
                ("target", "\(Int(Self.targetAge))s"),
            ]
        )
    }

    /// Consider one shard. Exposed so the behaviour can be exercised without
    /// waiting an hour for it.
    @discardableResult
    public func tick(now: Date = Date()) async -> String? {
        guard inFlight.count < Self.maxConcurrentRefreshes else { return nil }
        guard let catalog = FileIndexCatalog() else { return nil }

        for root in Self.rotated(roots.sorted(), after: lastServedRoot) {
            guard
                let chosen = nextShard(in: root, from: catalog, now: now)
            else { continue }

            let key = Self.inFlightKey(root: root, shard: chosen.name)
            inFlight.insert(key)
            defer { inFlight.remove(key) }

            let age = now.timeIntervalSince(chosen.walkedAt)
            log.record(
                "sweep",
                [
                    ("event", "refreshing"),
                    ("root", root),
                    ("shard", chosen.name.isEmpty ? "(root)" : chosen.name),
                    ("age", String(format: "%.0f", age)),
                    ("reason", chosen.dirty ? "dirty" : "stale"),
                    (
                        "consent",
                        FileCorpusBuilder.isConsentProtected(
                            shard: chosen.name, underCanonicalRoot: root
                        ) ? "protected" : "open"
                    ),
                ]
            )
            lastServedRoot = root
            await FileCorpusStore.shared.refresh(
                shard: chosen.name, canonicalRoot: root
            )
            if chosen.dirty { scheduleBacklogDrain() }
            return chosen.name
        }
        return nil
    }

    /// Come straight back for the next dirty shard instead of waiting a tick.
    ///
    /// A minute apart is the right cadence for staleness, which is a guess
    /// about what the file system might not have told us. A dirty shard is not
    /// a guess, and they arrive in groups: discarding a stale cursor marks
    /// every shard of a root at once, and forty-four of them at a minute each
    /// is three quarters of an hour during which results describe the last
    /// walk rather than the tree. The cadence still governs the steady state —
    /// this only skips the wait while there is a backlog to clear.
    private func scheduleBacklogDrain() {
        guard Self.isEnabled, !backlogDrainScheduled else { return }
        backlogDrainScheduled = true
        let id = nextPassID
        nextPassID += 1
        inFlightPasses[id] = Task {
            // Retired here rather than by whoever stops, so a chain draining a
            // long backlog does not accumulate its own history.
            defer { self.inFlightPasses[id] = nil }
            // Cleared before ticking, not after: the pass that drains the
            // backlog is also the pass that discovers there is more of it, so
            // holding the flag across the tick would stop the chain after one.
            self.backlogDrainScheduled = false
            // Not past a stop. This only exists to skip the wait between
            // passes, so it has no business running when there are none —
            // and a drain queued just before a stop would otherwise walk
            // under whatever root was registered next.
            guard self.loop != nil, !Task.isCancelled else { return }
            await self.tick()
        }
    }

    /// The same roots, rotated so the one after `previous` comes first.
    ///
    /// Round-robin rather than random: the order stays stable and readable in
    /// the log, and every root is reached before any is reached twice.
    static func rotated(_ roots: [String], after previous: String?) -> [String] {
        guard let previous, let index = roots.firstIndex(of: previous) else {
            return roots
        }
        let next = roots.index(after: index)
        return Array(roots[next...]) + Array(roots[..<next])
    }

    /// How an in-flight shard is named. Shared with tests so neither side has to
    /// know the other's string format.
    static func inFlightKey(root: String, shard: String) -> String {
        "\(root)\u{0}\(shard)"
    }

    /// The shard this root most needs refreshed, or none.
    ///
    /// Dirty first, then oldest — dirty means something reported the shard
    /// wrong, which outranks any amount of merely elapsed time.
    ///
    /// A directory the user is asked about is eligible only when something
    /// reported it wrong. Age alone does not qualify it, because re-reading it
    /// costs a consent dialog and buys very little: it is watched like everything
    /// else, and the dropped-event load this backstop exists for happens in trees
    /// being built in, not in a Pictures folder. The trade the skip list accepted
    /// was being asked once; a timer turns that into being asked hourly.
    func nextShard(
        in root: String, from catalog: FileIndexCatalog, now: Date
    ) -> FileIndexCatalog.Shard? {
        catalog.shards(forRoot: root)
            .filter { shard in
                guard
                    !inFlight.contains(
                        Self.inFlightKey(root: root, shard: shard.name)
                    )
                else { return false }

                // A protected shard whose last walk came back incomplete
                // has already spent a consent dialog to learn very little —
                // one measured pass took 27.96s to yield two entries and a
                // refusal. `walkedAt` is written for a refused attempt too,
                // so it dates the incomplete walk without a second column.
                if shard.isIncomplete,
                    FileCorpusBuilder.isConsentProtected(
                        shard: shard.name, underCanonicalRoot: root
                    ),
                    now.timeIntervalSince(shard.walkedAt)
                        < Self.refusalBackoff
                {
                    return false
                }

                if shard.dirty { return true }
                guard now.timeIntervalSince(shard.walkedAt) >= Self.targetAge
                else { return false }
                return !FileCorpusBuilder.isConsentProtected(
                    shard: shard.name, underCanonicalRoot: root
                )
            }
            .sorted {
                if $0.dirty != $1.dirty { return $0.dirty }
                return $0.walkedAt < $1.walkedAt
            }
            .first
    }
}
