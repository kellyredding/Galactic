import XCTest
@testable import Galactic

/// A run lets go of its process once it has resolved.
///
/// The timeout timer's handler reaches back to the timer and holds the process
/// and both pipes, so a timer that never releases its handler keeps all of
/// them alive for the life of the host app.
final class ProcessRunnerTests: XCTestCase {

    func testAFailedLaunchReleasesItsProcess() {
        weak var weakProcess: Process?
        let resolved = expectation(description: "resolved")

        drive(
            executableURL: URL(fileURLWithPath: "/nonexistent/galactic-test"),
            track: { weakProcess = $0 }
        ) { result in
            if case .failure(ProcessRunError.launchFailed) = result {
                resolved.fulfill()
            }
        }

        wait(for: [resolved], timeout: 2)
        XCTAssertTrue(released { weakProcess }, "the failed run kept its process")
    }

    func testAFastFailingRunReleasesItsProcess() {
        weak var weakProcess: Process?
        let resolved = expectation(description: "resolved")

        drive(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            track: { weakProcess = $0 }
        ) { result in
            if case .failure(ProcessRunError.cliError) = result {
                resolved.fulfill()
            }
        }

        wait(for: [resolved], timeout: 5)
        // The EOF grace holds the run for two seconds after its pipes close.
        XCTAssertTrue(
            released(within: 4) { weakProcess },
            "the finished run kept its process"
        )
    }

    // MARK: - Helpers

    private func drive(
        executableURL: URL,
        track: (Process) -> Void,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        autoreleasepool {
            let (process, out, err, inPipe) = ProcessRunner.makeProcess(
                executableURL: executableURL,
                arguments: [],
                stdin: nil,
                currentDirectory: nil
            )
            track(process)
            ProcessRunner.drive(
                process: process,
                stdout: out,
                stderr: err,
                stdin: nil,
                stdinPipe: inPipe,
                binary: executableURL.lastPathComponent,
                timeout: 30,
                onLaunch: nil,
                completion: completion
            )
        }
    }

    private func released(
        within seconds: TimeInterval = 1,
        _ object: () -> AnyObject?
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if autoreleasepool(invoking: { object() == nil }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return autoreleasepool { object() == nil }
    }
}
