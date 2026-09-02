import Foundation
import CoreServices

/// Watches a root and keeps its index current.
///
/// ### One stream, and why that number matters
///
/// FSEvents is recursive by construction, and every published failure mode is
/// about the number of *streams* rather than the number of files —
/// `FSEventStreamStart` begins failing somewhere around five hundred
/// concurrent streams. So a root gets one stream covering everything beneath
/// it, never one per shard.
///
/// ### The callback returns immediately, and that is not a style preference
///
/// The kernel discards a non-Apple watcher's **entire** event queue once it is
/// three quarters full, and Apple's own services are exempt through private
/// entitlements no third party can obtain. There is no backpressure to
/// negotiate: the only defence is to take the batch, hand it off, and get out.
/// Everything expensive happens after the callback has returned.
///
/// ### Created or removed is asked of the file system, not of the flags
///
/// `ItemCreated` and `ItemRemoved` can both be set on one path, events for a
/// rename can arrive out of order, and Apple's own guidance is that an event
/// means "look here" rather than "this happened". Asking whether the path
/// exists now is both simpler and more truthful — and it handles a rename
/// exactly right, because the old path stops existing and the new one starts.
public final class FileIndexWatcher: @unchecked Sendable {

    /// Half a second. Long enough that a build or a checkout arrives in
    /// batches rather than one event at a time, short enough that a file saved
    /// in an editor is findable before the reader goes looking for it.
    public static let latency: CFTimeInterval = 0.5

    /// How many replayed paths are worth reading one at a time.
    ///
    /// Above this the replay is answered by naming the subtrees it touched and
    /// letting the sweep redo them, which is the same answer already given when
    /// the file system says it lost track. Reading each path costs an `lstat`,
    /// and a burst of nine hundred of those measured 213 ms — so this bounds
    /// that half of the work to roughly a tenth of a second however long the
    /// application was away.
    public static let replayPathLimit = 500

    /// How long a replay has to go quiet before it counts as finished.
    ///
    /// Measured from the last event rather than from the start of the stream,
    /// and that is the fix for a deadline that fired at the moment delivery
    /// began: the history took ten seconds to arrive and then landed in seventy
    /// milliseconds, so a ten-second deadline from the start expired in the
    /// middle of it and nothing was ever concluded.
    ///
    /// A replay that has said nothing for this long is over whether or not it
    /// announced itself, and anything still to come arrives live — where it
    /// marks its own shard, which is what makes concluding early safe.
    public static let replayIdle: TimeInterval = 2

    /// The longest a replay may stay open.
    ///
    /// A machine churning without pause is indistinguishable from a replay still
    /// arriving, and waiting for quiet that never comes is how the position
    /// stayed frozen in the first place. Whatever is still coming marks its own
    /// shard, so there is nothing to lose by stopping here.
    public static let replayCeiling: TimeInterval = 30

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(
        label: "com.kellyredding.galactic.index-watch", qos: .utility
    )
    private let canonicalRoot: String
    private let log = FileIndexLog.shared

    /// Set only when history was asked for, and cleared by the first
    /// `HistoryDone` — or by the grace timer. Every access is on `queue`, which
    /// is serial, and that is what makes it safe without a lock.
    private var replaying = false
    private var replayTouched: [String] = []
    private var replayRescan: [String] = []
    /// Where the event store stood when this stream was created.
    ///
    /// Read before any event arrives, so it is a conservative bound on what the
    /// replay can contain: anything later than this is delivered live instead.
    /// That is what makes it safe to declare untouched shards current as of it.
    private var replayHorizon: UInt64 = 0
    /// Invalidates a pending idle check when another event arrives, since a
    /// dispatch item cannot be cancelled once scheduled.
    private var replayIdleToken = 0

    public init(canonicalRoot: String) {
        self.canonicalRoot = canonicalRoot
    }

    deinit { stopStream() }

    // MARK: - Stream position

    public static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// The volume's UUID, which is what a stored stream position must be keyed
    /// on.
    ///
    /// Never `dev_t`: device numbers are handed out in mount order and are not
    /// stable across reboots, and on an APFS volume group the root, the data
    /// volume and the home directory all report the *same* one. A UUID that
    /// has changed means the event store was thrown away and every position
    /// recorded against it is meaningless.
    public static func volumeUUID(for path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        guard let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        guard let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }

    // MARK: - Lifecycle

    /// Begin watching. `since` replays what changed while nothing was running.
    public func start(since: UInt64?) {
        stopStream()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
            // Without this a replay can begin mid-chunk and silently skip the
            // events either side of the boundary.
            | UInt32(kFSEventStreamCreateFlagFullHistory)

        // Zero means "the beginning of time", which is both the value a failed
        // lookup returns and a request to replay the entire event store — tens
        // of seconds of it. Guarded here rather than at the call site because
        // the two cases are indistinguishable by the time they arrive.
        let start = (since ?? 0) == 0
            ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            : FSEventStreamEventId(since!)

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<FileIndexWatcher>
                        .fromOpaque(info).takeUnretainedValue()
                    watcher.handle(count: count, paths: paths, flags: flags)
                },
                &context,
                [canonicalRoot] as CFArray,
                start,
                Self.latency,
                flags
            )
        else {
            log.record("watch", [("event", "create-failed"), ("root", canonicalRoot)])
            return
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)

        // Buffer while the replay arrives. Asking for history means being sent
        // everything that happened while the application was away, as fast as
        // the file system can deliver it — the coalescing latency above governs
        // live events and does nothing for these. Measured after half an hour
        // away: 1,048 callbacks carrying 11,807 paths in nine seconds, each one
        // a hop to the main actor and its share of an `lstat` storm, landing in
        // the same window as everything else a launch has to do.
        let replaying = start != FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let horizon = Self.currentEventID()
        queue.async { [self] in
            // Cleared as well as set: a restart must not deliver a previous
            // stream's replay into this one.
            replayTouched = []
            replayRescan = []
            replayHorizon = horizon
            self.replaying = replaying
            guard replaying else { return }
            scheduleReplayIdle()
            queue.asyncAfter(deadline: .now() + Self.replayCeiling) { [self] in
                flushReplay(reason: "ceiling")
            }
        }

        FSEventStreamStart(created)
        log.record(
            "watch",
            [
                ("event", "started"),
                ("root", canonicalRoot),
                ("since", since.map(String.init) ?? "now"),
                ("latency", "\(Self.latency)"),
                ("replaying", "\(replaying)"),
            ]
        )
    }

    public func stop() { stopStream() }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Events

    private func handle(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let list = unsafeBitCast(paths, to: NSArray.self)
        var touched: [String] = []
        var rescan: [String] = []
        var historyDone = false
        touched.reserveCapacity(count)

        for index in 0..<count {
            guard let path = list[index] as? String else { continue }
            let flag = flags[index]
            // The file system lost track. There is no way to learn what was
            // missed, so the only honest answer is to redo that subtree.
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                rescan.append(path)
                continue
            }
            // Not a path at all: the marker saying the replay is over. It was
            // being skipped as an uninteresting event, which threw away the one
            // signal that says when the flood stops.
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyDone = true
                continue
            }
            touched.append(path)
        }

        if replaying {
            replayTouched.append(contentsOf: touched)
            replayRescan.append(contentsOf: rescan)
            scheduleReplayIdle()
            if historyDone {
                flushReplay(reason: "history-done")
            } else if replayTouched.count > Self.replayPathLimit {
                // Drained as it fills rather than held to the end. A replay
                // large enough to pass the limit has already earned the cheap
                // answer, and holding the rest of it in memory to reach the same
                // conclusion later only risks the grace timer arriving first and
                // sending the remainder through the live path one event at a
                // time — which is what happened on a 550,799-path replay.
                drainReplay(reason: "batch")
            }
            return
        }

        deliver(touched: touched, rescan: rescan)
    }

    /// Hand a batch to the store.
    ///
    /// Classified here, on the watcher's own queue, rather than after the hop to
    /// the main actor. This is where the cost is: a burst of nine hundred paths
    /// measured 213 ms in `lstat` alone, because each path is a cold metadata
    /// read somewhere in a tree of nearly a million files. Doing that on the
    /// main actor is what a beach ball is made of, and none of it needs the
    /// store's state — only the answers do.
    private func deliver(touched: [String], rescan: [String]) {
        guard !touched.isEmpty || !rescan.isEmpty else { return }
        let root = canonicalRoot
        let classified = FileCorpusStore.classify(touched)
        Task {
            await FileCorpusStore.shared.apply(
                created: classified.created, removed: classified.removed,
                rescan: rescan, canonicalRoot: root
            )
        }
    }

    /// Answer a whole replay at once.
    ///
    /// One delivery rather than one per callback, and above `replayPathLimit`
    /// the paths are not read at all — the subtrees they fall in are named and
    /// the sweep redoes them. That is not a shortcut: it is the same answer this
    /// watcher already gives when the file system reports it lost track, and for
    /// the same reason. Learning what changed costs a cold `lstat` per path,
    /// which past a certain volume is more expensive than rewalking the few
    /// subtrees involved — and a rewalk is the more accurate answer anyway.
    /// Wait for the replay to go quiet, and treat that as the end of it.
    private func scheduleReplayIdle() {
        replayIdleToken += 1
        let token = replayIdleToken
        queue.asyncAfter(deadline: .now() + Self.replayIdle) { [self] in
            guard replaying, token == replayIdleToken else { return }
            flushReplay(reason: "idle")
        }
    }

    private func flushReplay(reason: String) {
        guard replaying else { return }
        replaying = false
        // Every way of concluding carries the untouched shards forward, and the
        // earlier reluctance about that was wrong twice over. It made the fix
        // conditional on a signal that never arrived, so nothing was ever
        // carried — and the caution was unfounded anyway: the horizon was read
        // before any event was delivered, and a change still in flight marks its
        // own shard when it lands, which is exactly what excludes that shard from
        // being carried.
        drainReplay(reason: reason, advancing: true)
    }

    /// Hand over what has accumulated, and empty the buffer.
    private func drainReplay(reason: String, advancing: Bool = false) {
        let touched = replayTouched
        let rescan = replayRescan
        replayTouched = []
        replayRescan = []
        guard !touched.isEmpty || !rescan.isEmpty || advancing else { return }

        let cheap = touched.count > Self.replayPathLimit
        let subtrees =
            cheap
            ? Self.subtrees(of: touched, underCanonical: canonicalRoot) : []
        log.record(
            "watch",
            [
                ("event", "replay-drained"),
                ("reason", reason),
                ("paths", "\(touched.count)"),
                ("action", cheap ? "rescan-subtrees" : "classify"),
                ("subtrees", "\(subtrees.count)"),
                // A sample, because a count alone cannot say whether these are
                // real shards. Every path should reduce to one of the root's
                // top-level entries, and a reduction producing anything else is
                // marking a shard that does not exist.
                ("sample", subtrees.sorted().prefix(5).joined(separator: ",")),
                ("advancing", "\(advancing)"),
            ]
        )

        let root = canonicalRoot
        let horizon = replayHorizon
        if cheap {
            let all = Array(subtrees) + rescan
            Task {
                await Self.hand(
                    created: [], removed: [], rescan: all, root: root,
                    horizon: advancing ? horizon : nil
                )
            }
            return
        }
        let classified = FileCorpusStore.classify(touched)
        Task {
            await Self.hand(
                created: classified.created, removed: classified.removed,
                rescan: rescan, root: root,
                horizon: advancing ? horizon : nil
            )
        }
    }

    /// No longer main-actor isolated: this existed to make the hop, and the
    /// store it hands to owns its own isolation now.
    private static func hand(
        created: [FileCorpusStore.Appearance], removed: [String],
        rescan: [String], root: String, horizon: UInt64?
    ) async {
        guard let horizon else {
            await FileCorpusStore.shared.apply(
                created: created, removed: removed, rescan: rescan,
                canonicalRoot: root
            )
            return
        }
        await FileCorpusStore.shared.applyReplay(
            created: created, removed: removed, rescan: rescan,
            canonicalRoot: root, horizon: horizon
        )
    }

    /// The distinct top-level subtrees a set of paths falls in.
    ///
    /// What `markSubtreeDirty` reduces each path to anyway. Reduced here
    /// instead, off the main actor and before the hop, so twelve thousand paths
    /// become the handful of shards they actually name — one main-actor call
    /// each rather than twelve thousand.
    ///
    /// A path outside the root is dropped rather than guessed at: the stream
    /// watches one root, and anything else arriving is not this index's to
    /// answer for.
    static func subtrees(
        of paths: [String], underCanonical root: String
    ) -> Set<String> {
        var found: Set<String> = []
        for path in paths {
            guard
                let relative = FilePaths.relativeEntry(
                    of: path, underCanonical: root
                )
            else { continue }
            guard let first = relative.split(separator: "/").first else {
                found.insert(root)
                continue
            }
            found.insert(root + "/" + first)
        }
        return found
    }
}
