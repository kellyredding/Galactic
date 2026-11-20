import XCTest
@testable import Galactic

final class ClaudeSessionGuardTests: XCTestCase {

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

    // MARK: - Listing

    // The shape `claude agents --json` prints: background workers carry a
    // short id and no pid while they are not running.
    private let listing = Data(#"""
    [
      {"pid":null,"sessionId":"87c2a138-d72f-4892-a0fc-8989d8c0398d","kind":"background","status":null,"id":"87c2a138"},
      {"pid":4242,"sessionId":"aaaa0000-0000-0000-0000-000000000001","kind":"background","status":"busy","id":"aaaa0000","startedAt":1795192800000},
      {"pid":28774,"cwd":"/Users/x/.assist-ant/workspace","kind":"interactive","startedAt":1795192834331,"sessionId":"1bf7ef4e-2059-4ea9-affa-eae1fee320e2","status":"idle"},
      {"pid":29017,"cwd":"/Users/x/projects","kind":"interactive","startedAt":1795192848743,"sessionId":"c601b842-f194-46fc-9cd7-23a79702285c","status":"busy"}
    ]
    """#.utf8)

    func testOnlyLiveHoldersOfTheWantedIdsAreReturned() throws {
        let holders = try ClaudeSessionGuard.holders(
            in: listing,
            of: ["1BF7EF4E-2059-4EA9-AFFA-EAE1FEE320E2", "87c2a138-d72f-4892-a0fc-8989d8c0398d"]
        )
        XCTAssertEqual(holders, [
            ClaudeSessionHolder(
                pid: 28774,
                sessionId: "1bf7ef4e-2059-4ea9-affa-eae1fee320e2",
                kind: "interactive",
                status: "idle",
                startedAt: Date(timeIntervalSince1970: 1_795_192_834.331)
            ),
        ])
    }

    func testABackgroundHolderKeepsItsShortId() throws {
        let holders = try ClaudeSessionGuard.holders(
            in: listing, of: ["aaaa0000-0000-0000-0000-000000000001"]
        )
        XCTAssertEqual(holders.count, 1)
        XCTAssertTrue(holders[0].isBackground)
        XCTAssertTrue(holders[0].isBusy)
        XCTAssertEqual(holders[0].id, "aaaa0000")
    }

    func testNoMatchIsAnEmptyList() throws {
        XCTAssertTrue(try ClaudeSessionGuard.holders(in: listing, of: ["nope"]).isEmpty)
    }

    func testAnUnreadableListingThrows() {
        XCTAssertThrowsError(try ClaudeSessionGuard.holders(in: Data("nope".utf8), of: ["a"]))
    }

    func testAListingThatCannotRunIsUnknownNotNone() async {
        let guardian = ClaudeSessionGuard(claudePath: "/nonexistent/claude")
        let lookup = await guardian.holders(of: ["a"])
        guard case .unknown = lookup else {
            return XCTFail("expected .unknown, got \(lookup)")
        }
    }

    // MARK: - Identity

    func testAProcessThatBeganBeforeTheRecordedStartIsTheHolder() throws {
        let pid = try spawn("sleep 30")
        let holder = holder(pid, startedAt: Date())
        XCTAssertEqual(ClaudeSessionGuard.identity(of: holder), .same)
    }

    // What a recycled pid looks like: the process there began after the
    // holder recorded its start.
    func testAProcessThatBeganAfterTheRecordedStartIsNotTheHolder() throws {
        let pid = try spawn("sleep 30")
        let holder = holder(pid, startedAt: Date().addingTimeInterval(-60))
        XCTAssertEqual(ClaudeSessionGuard.identity(of: holder), .other)
    }

    func testAHolderWithoutAStartCannotBeVerified() throws {
        let pid = try spawn("sleep 30")
        XCTAssertEqual(ClaudeSessionGuard.identity(of: holder(pid, startedAt: nil)), .unverifiable)
    }

    // MARK: - Stopping

    func testStoppingAnInteractiveHolderReturnsOnceItHasExited() async throws {
        let pid = try spawn("sleep 30")
        try await ClaudeSessionGuard.stop(interactive: holder(pid, startedAt: Date()))
        XCTAssertTrue(reaped(pid))
    }

    func testAHolderIgnoringTheHangupIsStoppedByTheEscalation() async throws {
        let pid = try spawnIgnoringHangup()
        try await ClaudeSessionGuard.stop(
            interactive: holder(pid, startedAt: Date()),
            steps: [(0.05, SIGTERM), (0.1, SIGKILL)]
        )
        XCTAssertTrue(reaped(pid))
    }

    // Positive control: the polite signals alone leave it running, so the case
    // above is the escalation's doing.
    func testAHolderIgnoringTheHangupSurvivesThePoliteSignals() throws {
        let pid = try spawnIgnoringHangup()
        killpg(pid, SIGHUP)
        killpg(pid, SIGTERM)
        XCTAssertFalse(reaped(pid, within: 0.3))
    }

    // Positive control for the two cases above: a recycled pid is refused and
    // left running.
    func testAProcessThatIsNotTheHolderIsLeftRunning() async throws {
        let pid = try spawn("sleep 30")
        do {
            try await ClaudeSessionGuard.stop(
                interactive: holder(pid, startedAt: Date().addingTimeInterval(-60))
            )
            XCTFail("a process that began after the holder was signalled")
        } catch let error as ClaudeSessionGuardError {
            XCTAssertEqual(error, .notTheHolder(pid))
        }
        XCTAssertEqual(kill(pid, 0), 0, "the refused process was signalled")
    }

    // The holder exits between being verified and being sent the hangup: the
    // send fails with ESRCH, and the exit it already watches ends the stop.
    func testAHolderThatExitsBeforeTheHangupIsStopped() async throws {
        let pid = try spawn("sleep 30")
        try await ClaudeSessionGuard.stop(
            interactive: holder(pid, startedAt: Date()),
            steps: [],
            send: { _, target, _ in
                kill(target, SIGKILL)
                errno = ESRCH
                return false
            }
        )
        XCTAssertTrue(reaped(pid))
    }

    func testAFailedHangupForAnotherReasonIsReported() async throws {
        let pid = try spawn("sleep 30")
        do {
            try await ClaudeSessionGuard.stop(
                interactive: holder(pid, startedAt: Date()),
                steps: [],
                send: { _, _, _ in
                    errno = EPERM
                    return false
                }
            )
            XCTFail("a hangup refused with EPERM was taken as a stop")
        } catch let error as ClaudeSessionGuardError {
            XCTAssertEqual(error, .signalFailed(pid, EPERM))
        }
    }

    // A worker `claude stop` leaves running is ended by the escalation that
    // follows it. The stop command is a stand-in that does nothing.
    func testAWorkerTheStopCommandLeavesRunningIsEndedByTheEscalation() async throws {
        let pid = try spawnIgnoringHangup()
        let worker = ClaudeSessionHolder(
            pid: pid, sessionId: "s", kind: "background", status: "busy",
            startedAt: Date(), id: "w"
        )
        try await ClaudeSessionGuard.stop(
            worker, steps: [(0.05, SIGTERM), (0.1, SIGKILL)], politely: { _ in }
        )
        XCTAssertTrue(reaped(pid))
    }

    func testAHolderAlreadyGoneReturnsAtOnce() async throws {
        let pid = try spawn("exit 0")
        XCTAssertTrue(reaped(pid))
        try await ClaudeSessionGuard.stop(interactive: holder(pid, startedAt: Date()))
    }

    // MARK: - Helpers

    private func holder(_ pid: pid_t, startedAt: Date?) -> ClaudeSessionHolder {
        ClaudeSessionHolder(
            pid: pid, sessionId: "s", kind: "interactive", status: "idle", startedAt: startedAt
        )
    }

    /// A shell leading a group of its own, as a terminal's child does. The
    /// test runner passes on an ignored SIGHUP, which a terminal's child would
    /// not have, so dispositions are reset to the defaults.
    private func spawn(_ script: String) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attr, &unblocked)
        posix_spawnattr_setflags(
            &attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attr, 0)

        let args = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", nil, &attr, &argv, environ)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        spawned.append(pid)
        return pid
    }

    /// Returns once the shell has installed its trap, so no signal arrives
    /// before it is in place.
    private func spawnIgnoringHangup() throws -> pid_t {
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let pid = try spawn("trap '' HUP TERM; : > '\(ready.path)'; sleep 30 & wait")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: ready.path) { return pid }
            usleep(10_000)
        }
        throw NSError(
            domain: "ClaudeSessionGuardTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "the shell never installed its trap"]
        )
    }

    /// The test process is the parent, so it reaps; polled so a stop that
    /// failed fails the case instead of hanging the suite.
    private func reaped(_ pid: pid_t, within seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { return true }
            usleep(10_000)
        }
        return false
    }
}
