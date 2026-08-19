import Foundation

/// Keeps the index from drifting, by rewalking the stalest shard at intervals.
///
/// ### Why this exists even though the index is watched
///
/// File-system events are not a log that can be replayed to arrive at the
/// truth — Apple's own header says so outright. The kernel drops a non-Apple
/// watcher's entire queue under load, a large checkout is exactly that load,
/// and a dropped batch leaves no trace that anything was missed. So the
/// watcher keeps the index current *most* of the time, and this makes sure
/// that being wrong is temporary rather than permanent.
///
/// ### Why one shard at a time
///
/// Refreshing everything on a schedule would put the entire cost in one
/// moment, which on a home directory is half a minute of walking. Asking
/// instead for whichever shard has gone longest without being walked spreads
/// the same work across the hour, and it self-corrects: a shard marked dirty
/// by a dropped event jumps the queue.
@MainActor
public final class FileIndexRefreshSweep {

    public static let shared = FileIndexRefreshSweep()

    /// How stale a shard may be before it is worth rewalking.
    public static var targetAge: TimeInterval = 3_600

    /// How often to consider one. A minute is frequent enough to reach every
    /// shard of a large root inside the target age, and rare enough that the
    /// question costs nothing when the answer is "nothing yet".
    public static var tickInterval: TimeInterval = 60

    private var timer: Timer?
    private var roots: Set<String> = []
    private var isRefreshing = false
    private let log = FileIndexLog.shared

    init() {}

    public func add(canonicalRoot root: String) {
        roots.insert(root)
        startIfNeeded()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        roots.removeAll()
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
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
        guard !isRefreshing else { return nil }
        isRefreshing = true
        defer { isRefreshing = false }

        let catalog = FileIndexCatalog()
        for root in roots {
            guard let stalest = catalog?.stalestShard(forRoot: root) else { continue }
            let age = now.timeIntervalSince(stalest.walkedAt)
            guard stalest.dirty || age >= Self.targetAge else { continue }
            log.record(
                "sweep",
                [
                    ("event", "refreshing"),
                    ("root", root),
                    ("shard", stalest.name.isEmpty ? "(root)" : stalest.name),
                    ("age", String(format: "%.0f", age)),
                    ("reason", stalest.dirty ? "dirty" : "stale"),
                ]
            )
            await FileCorpusStore.shared.refreshStalestShard(canonicalRoot: root)
            return stalest.name
        }
        return nil
    }
}
