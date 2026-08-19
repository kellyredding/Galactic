import Foundation

/// The single-writer lease over the shared index.
///
/// Several applications map the same index, and exactly one of them may
/// rebuild it. Readers need no lock at all — a published generation is
/// immutable and a replacement is a rename — so this guards writers against
/// each other and nothing else.
public final class FileIndexLock: @unchecked Sendable {

    /// What a lease protects.
    ///
    /// Two, because one lock file for unrelated work is not caution but a
    /// coupling: rotation is a handful of renames, and a publish that happened
    /// to ask during them lost a non-blocking lease, wrote nothing, recorded
    /// nothing and never retried — a shard silently absent from the index and
    /// rewalked on every launch, caused by a log tidying itself.
    public enum Scope {
        /// Shards and the catalog rows describing them — the writer lease.
        case index
        /// The log's own generations, which nothing else touches.
        case log

        /// Resolved on each acquisition rather than stored, because the index
        /// location is a computed path a host or a test can move.
        var url: URL {
            switch self {
            case .index: FileIndexPaths.lockFile
            case .log: FileIndexPaths.logLockFile
            }
        }
    }

    private var descriptor: Int32 = -1
    private let scope: Scope

    public init(_ scope: Scope = .index) {
        self.scope = scope
    }

    public var isHeld: Bool { descriptor >= 0 }

    /// Try to take the lease without waiting.
    ///
    /// **`F_OFD_SETLK`, not `F_SETLK`.** POSIX record locks carry the famous
    /// defect that closing *any* descriptor for a file drops every lock the
    /// process holds on it — so an unrelated `open`/`close` of the lock file
    /// anywhere in the process would silently release this. Open-file-
    /// description locks are scoped to the descriptor instead. They exist on
    /// macOS from 10.11 and are simply absent from the `fcntl(2)` man page,
    /// which is why they are widely believed to be Linux-only.
    ///
    /// Falls back to `flock` where OFD locks are unsupported, which is
    /// network filesystems in practice.
    @discardableResult
    public func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        FileIndexPaths.prepare()
        let path = scope.url.path
        let opened = open(path, O_RDWR | O_CREAT, 0o600)
        guard opened >= 0 else { return false }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0

        var taken = fcntl(opened, F_OFD_SETLK, &lock) != -1
        var held = opened
        if !taken, errno == ENOTSUP || errno == EINVAL {
            // The fallback is spelled with `O_EXLOCK` rather than `flock(2)`
            // because Swift resolves the bare name to the `flock` *struct*
            // this function already uses, and the open flag has the same
            // whole-file, per-description semantics.
            close(opened)
            held = open(path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK, 0o600)
            taken = held >= 0
        }
        guard taken else {
            if held >= 0 { close(held) }
            return false
        }
        descriptor = held
        FileIndexLog.shared.record(
            "lock",
            [
                ("event", "acquired"), ("scope", "\(scope)"),
                ("pid", "\(getpid())"),
            ]
        )
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        FileIndexLog.shared.record(
            "lock",
            [
                ("event", "released"), ("scope", "\(scope)"),
                ("pid", "\(getpid())"),
            ]
        )
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
