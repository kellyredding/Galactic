import Foundation

/// Runs a CLI subprocess and returns its stdout without ever
/// parking a thread on the child.
///
/// The previous pattern — `readDataToEndOfFile()` followed by
/// `Process.waitUntilExit()` on a `.userInitiated` GCD block —
/// blocked a worker thread for the lifetime of every query. When a
/// child's termination notification was lost (e.g. across a
/// sleep/wake transition), `waitUntilExit()` never returned and the
/// worker thread leaked permanently. Enough leaked threads exhausted
/// the global dispatch pool, after which no new async work could be
/// scheduled and the app went unresponsive while its main thread sat
/// idle.
///
/// This runner removes every blocking wait:
/// - stdout/stderr are drained with `readabilityHandler`
///   (event-driven dispatch sources, never a parked thread), so both
///   pipes drain concurrently and the ~64KB pipe-buffer deadlock is
///   impossible.
/// - exit is observed via `terminationHandler` (a callback), never a
///   blocking wait.
/// - a hard `timeout` bounds every run. On timeout the child is
///   terminated (then killed after a grace period); closing its
///   pipes drives the reads to EOF and tears everything down. So even
///   if every notification is lost, a query self-destructs after
///   `timeout` seconds instead of leaking.
///
/// One `ProcessRunner` instance is one cancellation domain:
/// `cancelAll()` terminates every in-flight child it launched. A
/// service that needs independent domains (one cancellable, one not)
/// uses a separate instance per domain.
public final class ProcessRunner: @unchecked Sendable {
    private let binaryPath: String
    private let defaultTimeout: TimeInterval

    /// Every launched-and-not-yet-finished process, so `cancelAll()`
    /// can reach all of them — not just the most recent.
    private let registryLock = NSLock()
    private var live: [ObjectIdentifier: Process] = [:]

    public init(binaryPath: String, defaultTimeout: TimeInterval = 10) {
        self.binaryPath = binaryPath
        self.defaultTimeout = defaultTimeout
    }

    private var binaryName: String {
        (binaryPath as NSString).lastPathComponent
    }

    // MARK: - Public API

    /// Terminate every in-flight subprocess this runner launched.
    /// Each terminated child closes its pipes, which drives its
    /// in-progress `run(...)` to completion (as a `cliError` from the
    /// non-zero termination signal).
    public func cancelAll() {
        registryLock.lock()
        let processes = Array(live.values)
        registryLock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    /// Spawn the binary with `args`, optionally feeding `stdin`, and
    /// return its stdout. Throws `ProcessRunError` on launch failure,
    /// non-zero exit, or timeout. Never parks a thread on the child.
    public func run(
        args: [String],
        stdin: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        try Task.checkCancellation()

        let (process, outPipe, errPipe, inPipe) = Self.makeProcess(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: args,
            stdin: stdin,
            currentDirectory: nil
        )

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            Self.drive(
                process: process,
                stdout: outPipe,
                stderr: errPipe,
                stdin: stdin,
                stdinPipe: inPipe,
                binary: binaryName,
                timeout: timeout ?? defaultTimeout,
                onLaunch: { self.register(process) }
            ) { result in
                self.deregister(process)
                continuation.resume(with: result)
            }
        }
    }

    /// Synchronous sibling of `run`. Blocks the calling thread until
    /// the subprocess finishes or the timeout fires, then returns its
    /// stdout. Use only off the main thread.
    ///
    /// This intentionally parks the *caller's* thread — that is the
    /// point of a synchronous call. It does NOT bridge through Swift
    /// concurrency: the shared core is pure GCD and its completion
    /// fires from independent dispatch queues, so blocking here on a
    /// semaphore can never starve the cooperative thread pool. The
    /// timeout bounds the wait, so the caller blocks at most `timeout`
    /// seconds rather than forever.
    ///
    /// Static because synchronous callers run arbitrary system
    /// binaries (which, git, …) and need no cancellation domain.
    public static func runSync(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> Data {
        let (process, outPipe, errPipe, inPipe) = makeProcess(
            executableURL: executableURL,
            arguments: arguments,
            stdin: stdin,
            currentDirectory: currentDirectory
        )

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error>!
        drive(
            process: process,
            stdout: outPipe,
            stderr: errPipe,
            stdin: stdin,
            stdinPipe: inPipe,
            binary: executableURL.lastPathComponent,
            timeout: timeout,
            onLaunch: nil
        ) { result in
            outcome = result
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }

    /// Callback sibling of `run`/`runSync` for non-async, non-blocking
    /// callers (completion-based pipelines). Spawns the binary and
    /// delivers the result to `completion` on a background queue. Like
    /// `runSync`, it is static and registry-free — callers that need
    /// cancellation manage their own concurrency.
    public static func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let (process, outPipe, errPipe, inPipe) = makeProcess(
            executableURL: executableURL,
            arguments: arguments,
            stdin: stdin,
            currentDirectory: currentDirectory
        )
        drive(
            process: process,
            stdout: outPipe,
            stderr: errPipe,
            stdin: stdin,
            stdinPipe: inPipe,
            binary: executableURL.lastPathComponent,
            timeout: timeout,
            onLaunch: nil,
            completion: completion
        )
    }

    // MARK: - Subprocess core

    /// Build and configure a Process with drained stdout/stderr pipes
    /// plus an optional stdin pipe and working directory.
    private static func makeProcess(
        executableURL: URL,
        arguments: [String],
        stdin: Data?,
        currentDirectory: URL?
    ) -> (process: Process, stdout: Pipe, stderr: Pipe, stdinPipe: Pipe?) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        var inPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            inPipe = nil
        }
        return (process, outPipe, errPipe, inPipe)
    }

    /// Event-driven core shared by `run` and `runSync`. Pure GCD — no
    /// Swift concurrency — so a synchronous caller can safely block on
    /// the completion. Drains both pipes via `readabilityHandler`,
    /// observes exit via `terminationHandler`, and bounds the run with
    /// a timeout that terminates (then kills) the child. Calls
    /// `completion` exactly once. `onLaunch` runs synchronously after a
    /// successful launch (used to register for cancellation).
    private static func drive(
        process: Process,
        stdout outPipe: Pipe,
        stderr errPipe: Pipe,
        stdin: Data?,
        stdinPipe inPipe: Pipe?,
        binary: String,
        timeout limit: TimeInterval,
        onLaunch: (() -> Void)?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // All completion state is mutated only on this serial queue,
        // so the three event sources (stdout EOF, stderr EOF,
        // termination) and the timeout never race.
        let coord = DispatchQueue(label: "galactic.processrunner.\(binary)")

        var outBuf = Data()
        var errBuf = Data()
        var pending = 3 // stdout EOF + stderr EOF + termination
        var outDone = false
        var errDone = false
        var finished = false

        let timer = DispatchSource.makeTimerSource(queue: coord)
        timer.schedule(deadline: .now() + limit)

        // Resolve exactly once and tear everything down. Must run on
        // `coord`.
        func finish(_ result: Result<Data, Error>) {
            if finished { return }
            finished = true
            timer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            completion(result)
        }

        // Resolve once both pipes have hit EOF and the process has
        // terminated (so terminationStatus is valid and all output is
        // drained). Must run on `coord`.
        func completeIfReady() {
            guard !finished, pending == 0 else { return }
            let status = process.terminationStatus
            if status == 0 {
                finish(.success(outBuf))
            } else {
                let message = String(data: errBuf, encoding: .utf8)
                    ?? "Unknown error"
                finish(.failure(ProcessRunError.cliError(
                    binary: binary,
                    status: status,
                    message: message.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )))
            }
        }

        // Both pipes have hit EOF — the child closed its descriptors,
        // so it has exited — but `terminationHandler` hasn't fired. The
        // exit notification was most likely lost across a sleep/wake
        // transition (the same failure that wedged the old
        // `waitUntilExit`). Give termination a short grace; if it still
        // doesn't arrive, resolve with the fully drained output instead
        // of waiting out the hard timeout. Status is unknown, so assume
        // success — a process that died mid-write yields output its
        // caller will fail to parse. Must run on `coord`.
        func armEofGrace() {
            guard !finished, outDone, errDone else { return }
            coord.asyncAfter(deadline: .now() + 2.0) {
                guard !finished else { return }
                finish(.success(outBuf))
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // Stop EOF from re-firing immediately; the source stays
            // readable at EOF until the handler is cleared.
            if chunk.isEmpty { handle.readabilityHandler = nil }
            coord.async {
                guard !finished else { return }
                if chunk.isEmpty {
                    guard !outDone else { return }
                    outDone = true
                    pending -= 1
                    completeIfReady()
                    armEofGrace()
                } else {
                    outBuf.append(chunk)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            coord.async {
                guard !finished else { return }
                if chunk.isEmpty {
                    guard !errDone else { return }
                    errDone = true
                    pending -= 1
                    completeIfReady()
                    armEofGrace()
                } else {
                    errBuf.append(chunk)
                }
            }
        }

        process.terminationHandler = { _ in
            coord.async {
                guard !finished else { return }
                pending -= 1
                completeIfReady()
            }
        }

        timer.setEventHandler {
            guard !finished else { return }
            if process.isRunning { process.terminate() }
            let pid = process.processIdentifier
            // Escalate to SIGKILL if SIGTERM is ignored.
            coord.asyncAfter(deadline: .now() + 2.0) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
            finish(.failure(ProcessRunError.timedOut(
                binary: binary,
                seconds: limit
            )))
        }

        do {
            try process.run()
        } catch {
            timer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            completion(.failure(ProcessRunError.launchFailed(
                binary: binary,
                underlying: error
            )))
            return
        }

        onLaunch?()

        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        // Arm the timeout on `coord` so it is ordered against a fast
        // process that finishes before we get here (in which case
        // `finished` is already set and the timer — already cancelled
        // by finish() — is never activated).
        coord.async {
            guard !finished else { return }
            timer.activate()
        }
    }

    // MARK: - Registry

    private func register(_ process: Process) {
        registryLock.lock()
        live[ObjectIdentifier(process)] = process
        registryLock.unlock()
    }

    private func deregister(_ process: Process) {
        registryLock.lock()
        live[ObjectIdentifier(process)] = nil
        registryLock.unlock()
    }
}

// MARK: - Error Type

public enum ProcessRunError: Error, LocalizedError {
    case launchFailed(binary: String, underlying: Error)
    case cliError(binary: String, status: Int32, message: String)
    case timedOut(binary: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let binary, let underlying):
            return "\(binary) failed to launch: "
                + underlying.localizedDescription
        case .cliError(let binary, let status, let message):
            return "\(binary) exited with status \(status): \(message)"
        case .timedOut(let binary, let seconds):
            return "\(binary) timed out after \(Int(seconds))s"
        }
    }
}
