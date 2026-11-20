import Darwin
import Foundation

/// A live Claude Code process holding a conversation, as `claude agents` lists it.
public struct ClaudeSessionHolder: Equatable, Sendable {
    public let pid: pid_t
    public let sessionId: String
    /// `interactive` or `background`.
    public let kind: String
    public let status: String?
    /// When the process recorded its own start.
    public let startedAt: Date?
    /// The short id `claude stop` takes. Background workers only.
    public let id: String?

    public init(
        pid: pid_t, sessionId: String, kind: String,
        status: String? = nil, startedAt: Date? = nil, id: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.id = id
    }

    public var isBackground: Bool { kind == "background" }
    public var isBusy: Bool { status == "busy" }
}

public enum ClaudeSessionHolderLookup: Equatable, Sendable {
    case none
    case found([ClaudeSessionHolder])
    /// The listing failed. Distinct from `none` so a caller can decide whether
    /// to go ahead without knowing.
    case unknown(String)
}

public enum ClaudeSessionGuardError: Error, LocalizedError, Equatable {
    case notTheHolder(pid_t)
    case cannotVerify(pid_t)
    case noShortId(String)
    case signalFailed(pid_t, Int32)
    case stillRunning(String)

    public var errorDescription: String? {
        switch self {
        case .notTheHolder(let pid):
            return "Process \(pid) is no longer the Claude Code session that held the conversation."
        case .cannotVerify(let pid):
            return "Claude Code did not say when process \(pid) started, so it was not signalled."
        case .noShortId(let sessionId):
            return "Claude Code listed \(sessionId) without an id to stop it by."
        case .signalFailed(let pid, let code):
            return "Process \(pid) could not be signalled: \(String(cString: strerror(code)))."
        case .stillRunning(let sessionId):
            return "The session holding \(sessionId) was still running after being stopped."
        }
    }
}

/// Finds and stops a Claude Code process that still holds a conversation, so
/// resuming it does not fork it into a new transcript.
public final class ClaudeSessionGuard: @unchecked Sendable {
    private let runner: ProcessRunner

    public init(claudePath: String) {
        runner = ProcessRunner(binaryPath: claudePath, defaultTimeout: 5)
    }

    public func holders(of sessionIds: [String]) async -> ClaudeSessionHolderLookup {
        do {
            let listing = try await runner.run(args: ["agents", "--json"])
            let found = try Self.holders(in: listing, of: sessionIds)
            return found.isEmpty ? .none : .found(found)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Returns once the holder's process has exited.
    public func stop(_ holder: ClaudeSessionHolder) async throws {
        guard holder.isBackground else {
            return try await Self.stop(interactive: holder)
        }
        guard let id = holder.id else {
            throw ClaudeSessionGuardError.noShortId(holder.sessionId)
        }
        let stopWorker: () async throws -> Void = {
            _ = try await self.runner.run(args: ["stop", id])
        }
        if holder.startedAt != nil {
            return try await Self.stop(holder) { _ in try await stopWorker() }
        }
        // Without a start time its pid cannot be watched or signalled safely,
        // so ask the listing instead, once `claude stop` has returned.
        try await stopWorker()
        if case .found = await holders(of: [holder.sessionId]) {
            throw ClaudeSessionGuardError.stillRunning(holder.sessionId)
        }
    }

    // MARK: - Listing

    private struct Entry: Decodable {
        let pid: Int32?
        let sessionId: String?
        let kind: String?
        let status: String?
        let startedAt: Double?
        let id: String?
    }

    static func holders(in listing: Data, of sessionIds: [String]) throws -> [ClaudeSessionHolder] {
        let wanted = Set(sessionIds.map { $0.lowercased() })
        return try JSONDecoder().decode([Entry].self, from: listing).compactMap { entry in
            guard let pid = entry.pid, pid > 0,
                let sessionId = entry.sessionId, wanted.contains(sessionId.lowercased())
            else { return nil }
            return ClaudeSessionHolder(
                pid: pid,
                sessionId: sessionId,
                kind: entry.kind ?? "interactive",
                status: entry.status,
                startedAt: entry.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                id: entry.id
            )
        }
    }

    // MARK: - Stopping

    static func stop(
        interactive holder: ClaudeSessionHolder,
        steps: [ProcessTreeSignal.Step] = ProcessTreeSignal.escalation(after: SIGHUP),
        send: @escaping (Int32, pid_t, pid_t?) -> Bool = ProcessTreeSignal.send
    ) async throws {
        try await stop(holder, steps: steps) { group in
            guard send(SIGHUP, holder.pid, group) else {
                let code = errno
                // Exited since it was verified: the exit watch has it.
                if code == ESRCH { return }
                throw ClaudeSessionGuardError.signalFailed(holder.pid, code)
            }
        }
    }

    /// Asks the holder to stop with `politely`, then escalates the same way a
    /// terminal's child is stopped, so a holder that outlives the request
    /// cannot keep the caller waiting.
    static func stop(
        _ holder: ClaudeSessionHolder,
        steps: [ProcessTreeSignal.Step] = ProcessTreeSignal.escalation(after: SIGHUP),
        politely: @escaping (_ group: pid_t?) async throws -> Void
    ) async throws {
        try await awaitExit(of: holder) { exited in
            let pid = holder.pid
            let group = ProcessTreeSignal.group(of: pid)
            try await politely(group)
            if let group {
                ProcessTreeSignal.escalate(group: group, steps: steps)
                return
            }
            // A bare pid is escalated only until its exit is seen, after which
            // it may name another process.
            for step in steps {
                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(deadline: .now() + step.delay) {
                        guard !exited() else { return }
                        kill(pid, step.signal)
                    }
            }
        }
    }

    /// Watches the holder's process, confirms it is still the holder, runs
    /// `begin`, and returns when the process exits. The watch is registered
    /// before the check, so a process that passes the check is the one watched.
    static func awaitExit(
        of holder: ClaudeSessionHolder,
        begin: (@escaping () -> Bool) async throws -> Void
    ) async throws {
        let latch = ExitLatch()
        let source = DispatchSource.makeProcessSource(
            identifier: holder.pid, eventMask: .exit,
            queue: DispatchQueue(label: "galactic.session-guard.\(holder.pid)")
        )
        source.setEventHandler {
            latch.fire()
            source.cancel()
        }
        source.activate()

        switch identity(of: holder) {
        case .gone:
            source.cancel()
            return
        case .other:
            source.cancel()
            throw ClaudeSessionGuardError.notTheHolder(holder.pid)
        case .unverifiable:
            source.cancel()
            throw ClaudeSessionGuardError.cannotVerify(holder.pid)
        case .same:
            break
        }

        do {
            try await begin { latch.isSet }
        } catch {
            source.cancel()
            throw error
        }
        await latch.wait()
    }

    enum Identity: Equatable { case same, other, gone, unverifiable }

    /// A recycled pid names a process that began after the holder exited, and
    /// the holder recorded `startedAt` while alive, so a process that began
    /// later than that cannot be the holder.
    static func identity(of holder: ClaudeSessionHolder) -> Identity {
        guard let began = processStart(holder.pid) else { return .gone }
        guard let recorded = holder.startedAt else { return .unverifiable }
        return began <= recorded ? .same : .other
    }

    /// Nil once the process has exited, zombies included: their exit has
    /// already happened, so no exit event would follow.
    static func processStart(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
            size > 0,
            info.kp_proc.p_stat != SZOMB
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(start.tv_sec)
                + TimeInterval(start.tv_usec) / 1_000_000
        )
    }
}

private final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    var isSet: Bool { lock.withLock { fired } }

    func fire() {
        lock.lock()
        fired = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
