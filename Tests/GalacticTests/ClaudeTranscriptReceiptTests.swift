import Foundation
import XCTest

@testable import Galactic

/// Whether a prompt reached Claude Code's transcript.
///
/// The record shapes below were captured from Claude Code 2.1.296: a prompt is
/// a `user` record, a prompt typed mid-turn is first a `queue-operation`
/// enqueue, a slash command is filed under its command name, and a long typed
/// prompt is wrapped in `<pasted_content>`.
final class ClaudeTranscriptReceiptTests: XCTestCase {

    private var directory: URL!
    private var transcript: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        transcript = directory.appendingPathComponent("session.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func userRecord(_ content: Any) -> String {
        json(["type": "user", "message": ["role": "user", "content": content]])
    }

    private func enqueueRecord(_ content: String) -> String {
        json(["type": "queue-operation", "operation": "enqueue", "content": content])
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func append(_ lines: String...) {
        append(raw: lines.map { $0 + "\n" }.joined())
    }

    private func append(raw: String) {
        let data = Data(raw.utf8)
        if let handle = try? FileHandle(forWritingTo: transcript) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: transcript.path, contents: data)
        }
    }

    private func receipt(for prompt: String) -> ClaudeTranscriptReceipt {
        ClaudeTranscriptReceipt(transcript: transcript, prompt: prompt)
    }

    // MARK: - Prompts that arrived

    func testADifferentPromptDoesNotCount() {
        let receipt = receipt(for: "/galaxy:resume extra ")
        append(userRecord("Reply with only the word INDIA."))
        XCTAssertFalse(receipt.hasArrived(), "a different prompt is not this one")
    }

    func testAPlainPromptArrivesDespiteTheComposedTrailingSpace() {
        let receipt = receipt(for: "Reply with only the word INDIA. ")
        append(userRecord("Reply with only the word INDIA."))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testAPromptQueuedMidTurnArrivesWhenEnqueued() {
        let receipt = receipt(for: "Reply with only the word HOTEL. ")
        append(enqueueRecord("Reply with only the word HOTEL."))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testASlashCommandArrivesUnderItsCommandName() {
        let receipt = receipt(for: "/galaxy:recall what did we decide ")
        append(userRecord(
            "<command-message>galaxy:recall</command-message>\n"
                + "<command-name>/galaxy:recall</command-name>\n"
                + "<command-args>what did we decide</command-args>"))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testALongPromptArrivesInsideItsPastedContentWrapper() {
        let body = "[1] > LIMA scrollback first line\n> line 0: lorem ipsum"
        let receipt = receipt(for: body + " ")
        append(userRecord("\n\n<pasted_content id=\"90e6\">\n" + body))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testAMultiLinePromptArrivesOnItsFirstLine() {
        let receipt = receipt(for: "First line KILO\nSecond line ")
        append(userRecord("First line KILO\nSecond line"))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testAPromptInTextBlocksArrives() {
        let receipt = receipt(for: "hello there ")
        append(userRecord([["type": "text", "text": "hello there"]]))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testATranscriptCreatedAfterTheReceiptStillCounts() {
        let receipt = receipt(for: "first prompt of the session ")
        append(userRecord("first prompt of the session"))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testOnceArrivedItStaysArrived() {
        let receipt = receipt(for: "ok ")
        append(userRecord("ok"))
        XCTAssertTrue(receipt.hasArrived())
        XCTAssertTrue(receipt.hasArrived())
    }

    // MARK: - What does not count

    func testTheSamePromptRecordedBeforeTheReceiptDoesNotCount() {
        append(userRecord("/galaxy:resume"))
        let receipt = receipt(for: "/galaxy:resume ")
        XCTAssertFalse(receipt.hasArrived(), "only what was appended since counts")
    }

    func testAToolResultMentioningThePromptDoesNotCount() {
        let receipt = receipt(for: "Reply with only ok ")
        append(userRecord([
            ["type": "tool_result", "content": "Reply with only ok"],
        ]))
        XCTAssertFalse(receipt.hasArrived())
    }

    /// A short prompt quoted inside some other record must not pass for it.
    func testAPromptMentionedMidRecordDoesNotCount() {
        let receipt = receipt(for: "ok ")
        append(userRecord("<task-notification>reply ok</task-notification>"))
        XCTAssertFalse(receipt.hasArrived())
    }

    func testOtherRecordTypesDoNotCount() {
        let receipt = receipt(for: "hello ")
        append(
            json(["type": "assistant", "message": ["content": "hello"]]),
            json(["type": "queue-operation", "operation": "dequeue"]))
        XCTAssertFalse(receipt.hasArrived())
    }

    func testALineStillBeingWrittenIsReadOnceItIsWhole() {
        let receipt = receipt(for: "Reply with only the word INDIA. ")
        let line = userRecord("Reply with only the word INDIA.")
        let middle = line.index(line.startIndex, offsetBy: line.count / 2)
        append(raw: String(line[..<middle]))
        XCTAssertFalse(receipt.hasArrived(), "half a record is not a record")

        append(raw: String(line[middle...]) + "\n")
        XCTAssertTrue(receipt.hasArrived())
    }

    func testAnEmptyPromptNeverArrives() {
        let receipt = receipt(for: "   ")
        append(userRecord(""))
        XCTAssertFalse(receipt.hasArrived())
    }

    // MARK: - Finding the transcript

    func testItLocatesATranscriptByItsSessionId() throws {
        let project = directory.appendingPathComponent("-Users-someone-project")
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent(
            "4b8e5f4a-f048-41e3-bed9-32f4906f5b48.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        XCTAssertEqual(
            ClaudeTranscriptReceipt.locate(
                sessionId: "4B8E5F4A-F048-41E3-BED9-32F4906F5B48",
                projectsRoot: directory)?.standardizedFileURL,
            file.standardizedFileURL)
    }

    /// A session's first prompt creates its transcript, so the receipt for it
    /// is taken before there is a file to find.
    func testAReceiptBySessionFindsATranscriptCreatedAfterIt() throws {
        let sessionId = UUID().uuidString.lowercased()
        let receipt = ClaudeTranscriptReceipt(
            sessionId: sessionId, prompt: "Reply with only the word ALPHA. ",
            projectsRoot: directory)
        XCTAssertFalse(receipt.hasArrived(), "no transcript yet")

        let project = directory.appendingPathComponent("-Users-someone-project")
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        transcript = project.appendingPathComponent("\(sessionId).jsonl")
        append(userRecord("Reply with only the word ALPHA."))

        XCTAssertTrue(receipt.hasArrived())
    }

    func testAReceiptBySessionSkipsWhatItsTranscriptAlreadyHeld() throws {
        let sessionId = UUID().uuidString.lowercased()
        let project = directory.appendingPathComponent("-Users-someone-project")
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        transcript = project.appendingPathComponent("\(sessionId).jsonl")
        append(userRecord("/galaxy:resume"))

        let receipt = ClaudeTranscriptReceipt(
            sessionId: sessionId, prompt: "/galaxy:resume ",
            projectsRoot: directory)
        XCTAssertFalse(receipt.hasArrived())

        append(userRecord(
            "<command-message>galaxy:resume</command-message>\n"
                + "<command-name>/galaxy:resume</command-name>"))
        XCTAssertTrue(receipt.hasArrived())
    }

    func testItLocatesNothingForAnUnknownSession() {
        XCTAssertNil(
            ClaudeTranscriptReceipt.locate(
                sessionId: UUID().uuidString, projectsRoot: directory))
    }
}
