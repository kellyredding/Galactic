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

    // MARK: - Helpers

    private func spawnLeader() throws -> (leader: pid_t, child: pid_t) {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let leader = try spawn(
            script: "sleep 30 & echo $! > '\(pidFile.path)'; wait",
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
