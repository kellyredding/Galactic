import Darwin
import Dispatch

/// Signals a terminal's child together with everything in its process group.
///
/// What the child starts stays in its group unless it leaves: tool
/// subprocesses, MCP servers, a program a launcher spawns. Signalling only the
/// child's pid can leave those running.
enum ProcessTreeSignal {

    /// The group to signal, or nil when only the pid itself is safe to signal:
    /// the child does not lead its own group, or that group is the host's.
    /// Read it before the first signal — once the leader exits it is gone.
    static func group(of pid: pid_t) -> pid_t? {
        let pgid = getpgid(pid)
        guard pgid > 1, pgid == pid, pgid != getpgrp() else { return nil }
        return pgid
    }

    @discardableResult
    static func send(_ signal: Int32, to pid: pid_t, group: pid_t?) -> Bool {
        if let group { return killpg(group, signal) == 0 }
        return kill(pid, signal) == 0
    }

    /// Whether anything is left to signal: the pid, or any member of its group.
    static func isAlive(pid: pid_t, group: pid_t?) -> Bool {
        send(0, to: pid, group: group)
    }

    typealias Step = (delay: Double, signal: Int32)

    /// The firmer signals that follow a first one the process may outlast.
    static func escalation(after first: Int32) -> [Step] {
        switch first {
        case SIGHUP: return [(0.5, SIGTERM), (1.0, SIGKILL)]
        case SIGTERM: return [(0.5, SIGKILL)]
        default: return []
        }
    }

    /// Sends each step to the group while it still has a member. Holds nothing
    /// but the group id, so the stop outlives whoever began it; a group id is
    /// not reused while any member remains, so a late step reaches nothing else.
    static func escalate(
        group: pid_t,
        steps: [Step],
        on queue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        for step in steps {
            queue.asyncAfter(deadline: .now() + step.delay) {
                guard killpg(group, 0) == 0 else { return }
                killpg(group, step.signal)
            }
        }
    }
}
