import XCTest
@testable import Galactic

final class ClaudeConversationChainTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAConversationThatNeverMovedIsItsOwnChain() throws {
        try write("a", records: [message("hello")])
        XCTAssertEqual(resolve("a"), ["a"])
    }

    func testOneMoveIsFollowed() throws {
        try write("a", records: [message("hello"), continued(to: "b")])
        try write("b", records: [message("hello again")])
        XCTAssertEqual(resolve("a"), ["a", "b"])
    }

    func testMovesAreFollowedToTheNewest() throws {
        try write("a", records: [continued(to: "b")])
        try write("b", records: [message("x"), continued(to: "c")])
        try write("c", records: [message("y")])
        XCTAssertEqual(resolve("a"), ["a", "b", "c"])
    }

    func testTheLastMoveInATranscriptWins() throws {
        try write("a", records: [continued(to: "b"), message("x"), continued(to: "c")])
        try write("b", records: [])
        try write("c", records: [])
        XCTAssertEqual(resolve("a"), ["a", "c"])
    }

    func testACycleEndsTheChain() throws {
        try write("a", records: [continued(to: "b")])
        try write("b", records: [continued(to: "a")])
        XCTAssertEqual(resolve("a"), ["a", "b"])
    }

    func testAMoveToAMissingTranscriptEndsTheChain() throws {
        try write("a", records: [continued(to: "b")])
        XCTAssertEqual(resolve("a"), ["a"])
    }

    func testAMissingStartIsStillTheChain() {
        XCTAssertEqual(resolve("absent"), ["absent"])
    }

    // A transcript that discusses the record, as this very feature's did,
    // carries the marker inside message text; only the record itself counts.
    func testTheMarkerQuotedInMessageTextIsNotAMove() throws {
        try write("a", records: [message(#"saw {"type":"continued-in","continuedInSessionId":"b"}"#)])
        try write("b", records: [])
        XCTAssertEqual(resolve("a"), ["a"])
    }

    // MARK: - Helpers

    private func resolve(_ id: String) -> [String] {
        ClaudeConversationChain.resolve(sessionId: id, in: directory)
    }

    private func write(_ id: String, records: [[String: Any]]) throws {
        let lines = try records.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(
            to: directory.appendingPathComponent("\(id).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    private func message(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text]]
    }

    private func continued(to id: String) -> [String: Any] {
        ["type": "continued-in", "continuedInSessionId": id]
    }
}
