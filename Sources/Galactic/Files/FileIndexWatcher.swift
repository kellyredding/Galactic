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

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(
        label: "com.kellyredding.galactic.index-watch", qos: .utility
    )
    private let canonicalRoot: String
    private let log = FileIndexLog.shared

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
        FSEventStreamStart(created)
        log.record(
            "watch",
            [
                ("event", "started"),
                ("root", canonicalRoot),
                ("since", since.map(String.init) ?? "now"),
                ("latency", "\(Self.latency)"),
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
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            touched.append(path)
        }

        let root = canonicalRoot
        Task { @MainActor in
            FileCorpusStore.shared.apply(
                touched: touched, rescan: rescan, canonicalRoot: root
            )
        }
    }
}
