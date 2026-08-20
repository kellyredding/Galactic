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

    /// How long to wait for the end of a replay that never announces itself.
    ///
    /// `HistoryDone` is only delivered when history was actually requested, and
    /// this exists so that a stream which never sends it cannot leave events
    /// buffered for the life of the process.
    public static let replayGrace: TimeInterval = 10

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
        queue.async { [self] in
            // Cleared as well as set: a restart must not deliver a previous
            // stream's replay into this one.
            replayTouched = []
            replayRescan = []
            self.replaying = replaying
            guard replaying else { return }
            queue.asyncAfter(deadline: .now() + Self.replayGrace) { [self] in
                flushReplay(reason: "grace")
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
            if historyDone { flushReplay(reason: "history-done") }
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
        Task { @MainActor in
            FileCorpusStore.shared.apply(
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
    private func flushReplay(reason: String) {
        guard replaying else { return }
        replaying = false
        let touched = replayTouched
        let rescan = replayRescan
        replayTouched = []
        replayRescan = []

        if touched.count > Self.replayPathLimit {
            let subtrees = Self.subtrees(of: touched, underCanonical: canonicalRoot)
            log.record(
                "watch",
                [
                    ("event", "replay-done"),
                    ("reason", reason),
                    ("paths", "\(touched.count)"),
                    ("action", "rescan-subtrees"),
                    ("subtrees", "\(subtrees.count)"),
                ]
            )
            deliver(touched: [], rescan: Array(subtrees) + rescan)
            return
        }

        log.record(
            "watch",
            [
                ("event", "replay-done"),
                ("reason", reason),
                ("paths", "\(touched.count)"),
                ("action", "classify"),
            ]
        )
        deliver(touched: touched, rescan: rescan)
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
