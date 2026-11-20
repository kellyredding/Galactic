import XCTest
@testable import Galactic

/// What a terminal's child started dies with it.
///
/// Each case spawns `/bin/sh` leading a group of its own, as forkpty makes a
/// terminal's child, with a `sleep` under it standing in for a process the
/// child started in that group.
final class ProcessTreeSignalTests: XCTestCase {

    private var spawned: [pid_t] = []

    override func tearDown() {
        for pid in spawned {
            killpg(pid, SIGKILL)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
        spawned = []
        super.tearDown()
    }

    func testSignallingTheGroupStopsWhatTheLeaderStarted() throws {
        let (leader, child) = try spawnLeader()

        let group = ProcessTreeSignal.group(of: leader)
        XCTAssertEqual(group, leader)

        ProcessTreeSignal.send(SIGTERM, to: leader, group: group)
        reap(leader)

        XCTAssertTrue(gone(child), "the leader's child outlived the group signal")
        XCTAssertFalse(ProcessTreeSignal.isAlive(pid: leader, group: group))
    }

    // Positive control: without the group, the same child survives, which is
    // what lets the case above tell the two apart.
    func testSignallingOnlyTheLeaderLeavesItsChildRunning() throws {
        let (leader, child) = try spawnLeader()

        ProcessTreeSignal.send(SIGTERM, to: leader, group: nil)
        reap(leader)

        XCTAssertFalse(gone(child, within: 0.5))
        XCTAssertTrue(ProcessTreeSignal.isAlive(pid: leader, group: leader))
    }

    func testAChildInTheHostsGroupIsNotSignalledAsAGroup() throws {
        let pid = try spawn(script: "sleep 30", ownGroup: false)
        XCTAssertNil(ProcessTreeSignal.group(of: pid))
    }

    // The escalation is handed nothing but the group, which is what lets it
    // finish after the backend that began the stop has been released.
    func testEscalationStopsAGroupThatIgnoresThePoliteSignals() throws {
        let (leader, child) = try spawnLeader(ignoring: "HUP TERM")

        ProcessTreeSignal.send(SIGHUP, to: leader, group: leader)
        ProcessTreeSignal.escalate(
            group: leader, steps: [(0.05, SIGTERM), (0.1, SIGKILL)]
        )

        XCTAssertTrue(exited(leader), "the leader outlived the escalation")
        XCTAssertTrue(gone(child), "the leader's child outlived the escalation")
    }

    // Positive control: the same group survives the polite signals on their
    // own, so the case above is the escalation's doing.
    func testThePoliteSignalsAloneLeaveAnIgnoringGroupRunning() throws {
        let (leader, child) = try spawnLeader(ignoring: "HUP TERM")

        ProcessTreeSignal.send(SIGHUP, to: leader, group: leader)
        ProcessTreeSignal.send(SIGTERM, to: leader, group: leader)

        XCTAssertFalse(exited(leader, within: 0.5))
        XCTAssertFalse(gone(child, within: 0.1))
    }

    func testEachFirstSignalHasItsEscalation() {
        XCTAssertEqual(
            ProcessTreeSignal.escalation(after: SIGHUP).map(\.signal),
            [SIGTERM, SIGKILL]
        )
        XCTAssertEqual(
            ProcessTreeSignal.escalation(after: SIGTERM).map(\.signal),
            [SIGKILL]
        )
        XCTAssertTrue(ProcessTreeSignal.escalation(after: SIGKILL).isEmpty)
    }

    // MARK: - Helpers

    /// `ignoring` names signals the leader ignores, which its child inherits.
    private func spawnLeader(
        ignoring signals: String? = nil
    ) throws -> (leader: pid_t, child: pid_t) {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let trap = signals.map { "trap '' \($0); " } ?? ""
        let leader = try spawn(
            script: "\(trap)sleep 30 & echo $! > '\(pidFile.path)'; wait",
            ownGroup: true
        )

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (leader, child)
            }
            usleep(10_000)
        }
        throw NSError(
            domain: "ProcessTreeSignalTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "the leader never reported its child's pid"]
        )
    }

    private func spawn(script: String, ownGroup: Bool) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if ownGroup {
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attr, 0)
        }

        let args = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", nil, &attr, &argv, environ)
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
        }
        spawned.append(pid)
        return pid
    }

    private func reap(_ pid: pid_t) {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// Polls rather than blocks, so a leader the escalation failed to stop
    /// fails the case instead of hanging the suite.
    private func exited(_ pid: pid_t, within seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { return true }
            usleep(10_000)
        }
        return false
    }

    /// The child is reparented once its leader exits, so it can only be
    /// polled, not waited on.
    private func gone(_ pid: pid_t, within seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(10_000)
        }
        return false
    }
}
