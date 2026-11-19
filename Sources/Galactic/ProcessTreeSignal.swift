import Darwin

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
}
