import XCTest

@testable import Galactic

/// Two processes against one index.
///
/// Every other test in this suite runs alone, which is the one condition the
/// index will not be under once a second application mounts it. The lock is
/// advisory, the log holds its own file offset, and the catalog takes no
/// transaction across a read-modify-write — none of which a single-process test
/// can be wrong about, because nothing is there to contend with it.
///
/// ### How a second process happens
///
/// The package builds no executable, so the only Galactic-linked binary is this
/// test bundle. A child is therefore this same bundle re-entered through
/// `xctest`, running one designated test method and nothing else, told which
/// part to play through the environment.
///
/// `GALACTIC_HOME` is the whole reason this works: it is the only variable
/// Galactic reads, `FileIndexPaths.root` recomputes on every access, and the
/// override is consulted before the automatic per-pid test sandbox. A child that
/// fails to receive it does not fail loudly — it writes to a private directory
/// of its own and satisfies every assertion made about it. So the child reports
/// the root it resolved, and the parent refuses to trust a run it cannot place.
@MainActor
final class FileIndexMultiProcessTests: FileIndexIsolatedTestCase {

    /// Which part a spawned process plays. Absent in the parent run, which is
    /// how the child-only tests know to skip.
    private static let roleKey = "GALACTIC_MULTIPROCESS_ROLE"
    /// Where the child writes what it did, since stdout is the runner's.
    private static let reportKey = "GALACTIC_MULTIPROCESS_REPORT"
    /// The tree to index. The parent's, so both processes walk one corpus.
    private static let treeKey = "GALACTIC_MULTIPROCESS_TREE"
    /// Lowers the child's rotation threshold, so rotation can be reached.
    private static let rotateAtKey = "GALACTIC_MULTIPROCESS_ROTATE_AT"
    /// How many probe lines the child emits.
    private static let lineCountKey = "GALACTIC_MULTIPROCESS_LINES"

    private var home: URL!
    private var root: URL!

    private var isChild: Bool {
        ProcessInfo.processInfo.environment[Self.roleKey] != nil
    }

    /// A child adopts the parent's index and tree; it must not build its own.
    ///
    /// This is not a nicety. `setUp` used to call `setenv` unconditionally, so
    /// every child overwrote the very variable it was spawned with and indexed a
    /// private directory instead — contending with nobody while reporting
    /// success. The harness's own root check is what surfaced it, and it stays
    /// for that reason.
    override func setUp() async throws {
        try await super.setUp()
        guard !isChild else {
            home = FileIndexPaths.root
            root = ProcessInfo.processInfo.environment[Self.treeKey]
                .map { URL(fileURLWithPath: $0) }
            return
        }
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-mp-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-mp-root-\(UUID().uuidString)")
        setenv("GALACTIC_HOME", home.path, 1)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        FileCorpusStore.shared.forgetAll()
        FileIndexRefreshSweep.shared.stop()
        // A child owns none of this: deleting it would take the index out from
        // under the parent that is still measuring it.
        if !isChild {
            unsetenv("GALACTIC_HOME")
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - The harness

    /// A spawned run of this bundle, and what it reported back.
    private struct ChildRun {
        let role: String
        let status: Int32
        /// The index root the child actually resolved. The assertion that makes
        /// every other assertion mean something.
        let resolvedRoot: String?
        let output: String
    }

    private static let xctestURL: URL = {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        which.arguments = ["--find", "xctest"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }()

    /// A launched-but-unfinished child, and everything needed to collect it.
    private struct PendingChild {
        let role: String
        let process: Process
        let handle: FileHandle
        let report: URL
        let collected: Collected

        final class Collected: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ more: Data) {
                lock.lock()
                data.append(more)
                lock.unlock()
            }
            var text: String {
                lock.lock()
                defer { lock.unlock() }
                return String(decoding: data, as: UTF8.self)
            }
        }
    }

    /// The file whose appearance releases every waiting child at once.
    ///
    /// Launching two processes and hoping they overlap is not contention, it is
    /// a coincidence that a fast machine will decline to reproduce. The children
    /// spin on this instead, so the race starts when the parent says so.
    private var gate: URL { home.appendingPathComponent("gate") }

    private func launch(
        _ test: String, role: String, extraEnvironment: [String: String] = [:]
    ) throws -> PendingChild {
        let report = home.appendingPathComponent("report-\(role)-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = Self.xctestURL
        process.arguments = [
            "-XCTest", "GalacticTests.FileIndexMultiProcessTests/\(test)",
            Bundle(for: Self.self).bundlePath,
        ]
        var environment = Self.environmentWithoutInheritedTestPlan()
        environment["GALACTIC_HOME"] = home.path
        environment[Self.roleKey] = role
        environment[Self.reportKey] = report.path
        environment[Self.treeKey] = root.path
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = PendingChild.Collected()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { collected.append($0.availableData) }
        try process.run()
        return PendingChild(
            role: role, process: process, handle: handle, report: report,
            collected: collected
        )
    }

    private func collect(_ pending: PendingChild) -> ChildRun {
        pending.process.waitUntilExit()
        pending.handle.readabilityHandler = nil
        pending.collected.append(pending.handle.availableData)
        let reported = try? String(contentsOf: pending.report, encoding: .utf8)
        return ChildRun(
            role: pending.role,
            status: pending.process.terminationStatus,
            resolvedRoot: reported?.split(separator: "\n").first.map(String.init),
            output: pending.collected.text
        )
    }

    /// Launch every role, release them together, and collect them all.
    private func race(
        _ test: String, roles: [String],
        extraEnvironment: [String: String] = [:]
    ) throws -> [ChildRun] {
        let pending = try roles.map {
            try launch(test, role: $0, extraEnvironment: extraEnvironment)
        }
        try Data("go".utf8).write(to: gate)
        return pending.map(collect)
    }

    /// Wait for the parent's starting signal.
    private static func waitForGate() {
        let gate = FileIndexPaths.root.appendingPathComponent("gate")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: gate.path),
            Date() < deadline
        {
            usleep(200)
        }
    }

    /// Run `test` in a separate process and wait for it. For children that need
    /// no starting signal, since nothing is racing them.
    private func spawn(
        _ test: String, role: String, extraEnvironment: [String: String] = [:]
    ) throws -> ChildRun {
        let pending = try launch(
            test, role: role, extraEnvironment: extraEnvironment
        )
        try Data("go".utf8).write(to: gate)
        return collect(pending)
    }

    /// Fail unless the child ran, and ran against the index we meant.
    private func verify(
        _ run: ChildRun, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            run.status, 0,
            "child \(run.role) exited \(run.status):\n\(run.output)",
            file: file, line: line
        )
        XCTAssertEqual(
            run.resolvedRoot, home.path,
            """
            child \(run.role) used a different index, so it proved nothing:
            \(run.output)
            """,
            file: file, line: line
        )
    }

    /// Called by every child first: records where it is, so the parent can
    /// refuse a run that landed somewhere else.
    private static func reportResolvedRoot() {
        guard let path = ProcessInfo.processInfo.environment[reportKey] else {
            return
        }
        try? Data("\(FileIndexPaths.root.path)\n".utf8).write(
            to: URL(fileURLWithPath: path)
        )
    }

    /// Skip unless this process was spawned as a child.
    private static func requireChildRole() throws -> String {
        guard let role = ProcessInfo.processInfo.environment[roleKey] else {
            throw XCTSkip("child entry point; runs only when spawned")
        }
        reportResolvedRoot()
        return role
    }

    /// Skip when this process is already a child.
    ///
    /// Structural, not defensive. A parent test spawning while itself spawned is
    /// how one stray process becomes a fork bomb, and the environment that
    /// caused it was subtle enough to survive a passing test — so the guard
    /// stands on its own rather than on the argument that it cannot happen.
    private static func requireParentRole() throws {
        if ProcessInfo.processInfo.environment[roleKey] != nil {
            throw XCTSkip("parent test; never runs inside a spawned child")
        }
    }

    /// The parent's environment with the running test plan removed.
    ///
    /// `xctest` prefers `XCTestConfigurationFilePath` over the `-XCTest`
    /// argument, so a child that inherits it runs whatever the parent was
    /// filtered to rather than the one method it was asked for. Under a
    /// method-level filter that means zero tests and a clean exit status — a
    /// child that did nothing, indistinguishable from a child that found
    /// nothing wrong. Under a class-level filter it is worse: the child runs the
    /// whole class, spawning children of its own.
    private static func environmentWithoutInheritedTestPlan() -> [String: String] {
        ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("XCTest")
        }
    }

    // MARK: - Proving the harness before trusting it

    /// The child inherits the scratch index rather than falling back to its own
    /// per-pid sandbox, and says so in a way the parent can check.
    func testASpawnedChildSharesTheIndexRoot() throws {
        try Self.requireParentRole()
        let run = try spawn("testChildReportsWhereItIs", role: "probe")
        verify(run)
    }

    func testChildReportsWhereItIs() throws {
        _ = try Self.requireChildRole()
        // Touching the index is what would expose a wrong root as a real
        // divergence rather than a reported string.
        FileIndexPaths.prepare()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: FileIndexPaths.indexDirectory.path
            )
        )
    }

    // MARK: - The log

    /// How many lines each writer emits. Enough that two writers interleave
    /// rather than happening to finish in turn.
    private static let probeLines = 1200

    /// Every line both writers emitted is still in the log.
    ///
    /// The log is opened for writing and positioned once with `seekToEnd`, so
    /// each process carries its own file offset and neither learns that the
    /// other advanced the file. Two writers therefore overwrite each other's
    /// bytes rather than interleaving, and the loss is silent — the file stays
    /// well-formed, and only a line that should be there and is not gives it
    /// away.
    func testNeitherWriterLosesLinesToTheOther() throws {
        try Self.requireParentRole()
        let roles = ["writer-a", "writer-b", "writer-c", "writer-d"]
        let runs = try race("testChildWritesProbeLines", roles: roles)
        runs.forEach { verify($0) }

        let found = probeLinesInEveryGeneration()
        var missing: [String] = []
        for role in roles {
            for line in 0..<Self.probeLines where !found.contains("\(role):\(line)") {
                missing.append("\(role):\(line)")
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            """
            \(missing.count) of \(roles.count * Self.probeLines) log lines were \
            lost to a concurrent writer (first few: \(missing.prefix(5).joined(separator: ", ")))
            """
        )
    }

    func testChildWritesProbeLines() throws {
        let role = try Self.requireChildRole()
        if let bytes = ProcessInfo.processInfo.environment[Self.rotateAtKey],
            let value = Int(bytes)
        {
            FileIndexLog.rotateAtBytes = value
        }
        let count =
            ProcessInfo.processInfo.environment[Self.lineCountKey]
            .flatMap(Int.init) ?? Self.probeLines
        Self.waitForGate()
        for line in 0..<count {
            FileIndexLog.shared.record(
                "probe", [("role", role), ("n", "\(line)")]
            )
        }
        FileIndexLog.shared.drain()
    }

    /// Rotation is one process shifting a set of filenames, and two doing it at
    /// once corrupt the set: each renames `index.log.1` onwards, and a rename
    /// that arrives after the file has already moved is silently skipped. The
    /// damage is structural rather than textual — the generations stop being a
    /// contiguous run, so history is unlinked with nothing recording that it
    /// went.
    ///
    /// Rotated hard and often, and asserted on the shape of the generation set
    /// rather than its contents, because at this rate the oldest generation is
    /// legitimately pruned and any assertion about total lines would be wrong
    /// for a reason that has nothing to do with concurrency.
    func testRotationUnderFourWritersLeavesAContiguousGenerationSet() throws {
        try Self.requireParentRole()
        let roles = ["writer-a", "writer-b", "writer-c", "writer-d"]
        let runs = try race(
            "testChildWritesProbeLines", roles: roles,
            extraEnvironment: [
                Self.rotateAtKey: "4096",
                Self.lineCountKey: "1500",
            ]
        )
        runs.forEach { verify($0) }

        let present = presentGenerations()
        XCTAssertGreaterThanOrEqual(
            present.count, 3,
            "rotation barely happened, so nothing about it was tested"
        )
        XCTAssertLessThanOrEqual(
            present.count, FileIndexLog.generationsKept,
            "more generations than the log is allowed to keep: \(present)"
        )
        XCTAssertEqual(
            present, Array(1...present.count),
            """
            the generations are not a contiguous run — \(present) — so a \
            rename landed on a file another rotation had already moved
            """
        )

        // Whatever survived must still be readable as log lines. An interleaved
        // rotation that merged two files would leave this parsing as garbage.
        for generation in present {
            let url = FileIndexPaths.logsDirectory
                .appendingPathComponent("index.log.\(generation)")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(
                text.isEmpty, "generation \(generation) is empty"
            )
            let probes = text.split(separator: "\n").filter {
                $0.contains("[probe]")
            }
            let wellFormed = probes.filter {
                value(of: "role", in: $0) != nil && value(of: "n", in: $0) != nil
            }
            XCTAssertEqual(
                probes.count, wellFormed.count,
                "generation \(generation) holds \(probes.count - wellFormed.count) malformed lines"
            )
        }
    }

    // MARK: - The writer lease

    /// A log tidying itself must not cost a shard.
    ///
    /// The lease does not wait and a publish that loses it writes nothing,
    /// records nothing and never retries, so anything sharing that lease can
    /// make a shard silently absent from the index and rewalked on every
    /// launch. Rotation used to share it.
    func testRotatingTheLogDoesNotCostAPublish() async throws {
        try Self.requireParentRole()
        for subtree in 0..<12 {
            try touch("shard\(subtree)/file.swift")
        }

        // The child only churns the log; this process is the second writer, and
        // it is the one whose publishes have something to lose.
        let rotator = try launch(
            "testChildRotatesTheLog", role: "rotator",
            extraEnvironment: [
                Self.rotateAtKey: "2048",
                Self.lineCountKey: "6000",
            ]
        )
        try Data("go".utf8).write(to: gate)
        await indexRoot()
        verify(collect(rotator))

        let catalog = try XCTUnwrap(FileIndexCatalog())
        let recorded = Set(catalog.shards(forRoot: canonical).map(\.name))
        var absent: [String] = []
        for subtree in 0..<12 where !recorded.contains("shard\(subtree)") {
            absent.append("shard\(subtree)")
        }
        XCTAssertTrue(
            absent.isEmpty,
            """
            \(absent.count) walked shard(s) were never recorded, so a publish \
            lost the lease and never came back: \(absent.joined(separator: ", "))
            """
        )
        XCTAssertEqual(
            deferredPublishCount(), 0,
            "a publish was deferred for want of a lease it should not contend for"
        )
    }

    /// Two processes building the same index lose publishes to each other, and
    /// the index must still converge.
    ///
    /// The lease is a try-lock: whoever asks second is told no, and told once.
    /// What must not happen is a shard that no mechanism ever returns to — so
    /// this contends hard, then drives the sweep and requires a complete index
    /// at the end of it.
    func testShardsLostToContentionAreRecoveredByTheSweep() async throws {
        try Self.requireParentRole()
        let subtrees = 14
        for subtree in 0..<subtrees {
            try touch("shard\(subtree)/file.swift")
        }

        let builder = try launch("testChildIndexesTheTree", role: "builder")
        try Data("go".utf8).write(to: gate)
        await indexRoot()
        verify(collect(builder))

        let catalog = try XCTUnwrap(FileIndexCatalog())

        // Contention has to have actually happened, or this proves nothing about
        // recovery — it would just be a second walk of an uncontended index.
        XCTAssertGreaterThan(
            deferredPublishCount(), 0,
            "no publish was ever deferred, so no loss was there to recover from"
        )

        // Every shard is either published or recorded as owed. A shard in
        // neither state is the permanent loss this exists to rule out.
        let known = Set(catalog.shards(forRoot: canonical).map(\.name))
        var untracked: [String] = []
        for subtree in 0..<subtrees where !known.contains("shard\(subtree)") {
            untracked.append("shard\(subtree)")
        }
        XCTAssertTrue(
            untracked.isEmpty,
            """
            \(untracked.count) shard(s) are absent from the index with nothing \
            recorded to bring them back: \(untracked.joined(separator: ", "))
            """
        )

        // Then the promise itself: the sweep closes the gap.
        FileIndexRefreshSweep.targetAge = 0
        defer { FileIndexRefreshSweep.targetAge = 3_600 }
        FileCorpusStore.shared.forgetAll()
        await indexRoot()
        for _ in 0..<(subtrees * 3) {
            let dirty = catalog.shards(forRoot: canonical).filter(\.dirty)
            if dirty.isEmpty { break }
            await FileIndexRefreshSweep.shared.tick()
        }

        let settled = catalog.shards(forRoot: canonical)
        XCTAssertTrue(
            settled.allSatisfy { !$0.dirty },
            "the sweep did not clear: \(settled.filter(\.dirty).map(\.name))"
        )
        for subtree in 0..<subtrees {
            let name = "shard\(subtree)"
            guard let shard = settled.first(where: { $0.name == name }) else {
                XCTFail("\(name) never reached the index at all")
                continue
            }
            XCTAssertGreaterThan(
                shard.generation, 0, "\(name) is still only a placeholder"
            )
            XCTAssertGreaterThan(
                shard.entryCount, 0, "\(name) was published empty"
            )
        }
    }

    func testChildIndexesTheTree() async throws {
        _ = try Self.requireChildRole()
        Self.waitForGate()
        await indexRoot()
    }

    private func indexRoot() async {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.index(
                root: root, skipping: [],
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }
    }

    func testChildRotatesTheLog() throws {
        _ = try Self.requireChildRole()
        if let bytes = ProcessInfo.processInfo.environment[Self.rotateAtKey],
            let value = Int(bytes)
        {
            FileIndexLog.rotateAtBytes = value
        }
        let count =
            ProcessInfo.processInfo.environment[Self.lineCountKey]
            .flatMap(Int.init) ?? Self.probeLines
        Self.waitForGate()
        for line in 0..<count {
            FileIndexLog.shared.record("probe", [("role", "rotator"), ("n", "\(line)")])
        }
        FileIndexLog.shared.drain()
    }

    private func deferredPublishCount() -> Int {
        let directory = FileIndexPaths.logsDirectory
        var names = ["index.log"]
        names += (1...FileIndexLog.generationsKept).map { "index.log.\($0)" }
        var total = 0
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            total += text.split(separator: "\n").filter {
                $0.contains("[publish]") && $0.contains("reason=another-writer")
            }.count
        }
        return total
    }

    @discardableResult
    private func touch(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    private var canonical: String { FilePaths.canonical(root) }

    // MARK: - The catalog

    /// How many rows each cataloguing child writes.
    private static let catalogRows = 150

    /// A catalog write either lands or says it did not.
    ///
    /// WAL admits one writer at a time and the busy timeout was zero, so a
    /// second process was refused immediately — and every mutating method
    /// discarded the result, so a refusal was indistinguishable from success.
    /// Everything the index does to heal itself is a catalog write, which makes
    /// a silently dropped one the failure that disables the recovery from all
    /// the others.
    func testConcurrentCatalogWritesAllLand() throws {
        try Self.requireParentRole()
        let roles = ["cataloger-a", "cataloger-b", "cataloger-c", "cataloger-d"]
        let runs = try race("testChildWritesCatalogRows", roles: roles)
        runs.forEach { verify($0) }

        let catalog = try XCTUnwrap(FileIndexCatalog())
        let present = Set(catalog.shards(forRoot: canonical).map(\.name))
        var missing: [String] = []
        for role in roles {
            for row in 0..<Self.catalogRows where !present.contains("\(role)-\(row)") {
                missing.append("\(role)-\(row)")
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            """
            \(missing.count) of \(roles.count * Self.catalogRows) catalog writes \
            were dropped without error (first few: \
            \(missing.prefix(5).joined(separator: ", ")))
            """
        )
        // The other half of the promise: a write that cannot land says so.
        XCTAssertEqual(
            logLineCount(containing: "event=write-failed"), 0,
            "a catalog write reported failure, so the wait was not long enough"
        )
    }

    private func logLineCount(containing needle: String) -> Int {
        let directory = FileIndexPaths.logsDirectory
        var names = ["index.log"]
        names += (1...FileIndexLog.generationsKept).map { "index.log.\($0)" }
        var total = 0
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            total += text.split(separator: "\n").filter { $0.contains(needle) }.count
        }
        return total
    }

    func testChildWritesCatalogRows() throws {
        let role = try Self.requireChildRole()
        guard let catalog = FileIndexCatalog() else {
            XCTFail("no catalog")
            return
        }
        let root = FilePaths.canonical(
            URL(fileURLWithPath: ProcessInfo.processInfo.environment[Self.treeKey] ?? "/")
        )
        Self.waitForGate()
        for row in 0..<Self.catalogRows {
            catalog.record(
                root: root, name: "\(role)-\(row)", generation: 1,
                entryCount: row + 1, eventsUUID: nil, eventsID: nil
            )
        }
    }

    /// Which numbered generations exist, in order.
    private func presentGenerations() -> [Int] {
        (1...FileIndexLog.generationsKept).filter {
            FileManager.default.fileExists(
                atPath: FileIndexPaths.logsDirectory
                    .appendingPathComponent("index.log.\($0)").path
            )
        }
    }


    /// Every `role:n` pair present across the live log and every rotated
    /// generation.
    ///
    /// Rotation has to be included or the count is wrong for a reason that has
    /// nothing to do with concurrency: `tail()` reads only `index.log`, so a
    /// line moved into `index.log.1` reads as lost when it is merely filed.
    private func probeLinesInEveryGeneration() -> Set<String> {
        let directory = FileIndexPaths.logsDirectory
        var names = ["index.log"]
        names += (1...FileIndexLog.generationsKept).map { "index.log.\($0)" }
        var found: Set<String> = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            for line in text.split(separator: "\n") {
                guard line.contains("[probe]"),
                    let role = value(of: "role", in: line),
                    let number = value(of: "n", in: line)
                else { continue }
                found.insert("\(role):\(number)")
            }
        }
        return found
    }

    private func value(of key: String, in line: Substring) -> String? {
        for field in line.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == key else { continue }
            return String(parts[1])
        }
        return nil
    }
}
