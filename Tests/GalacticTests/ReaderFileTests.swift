import XCTest

@testable import Galactic

/// Reading a file for the reader, and noticing when it has moved since.
///
/// The two halves are tested together because they are one claim: what was
/// frozen at open, and whether the thing on disk still matches it. That claim
/// is what lets a review quote content and cite a path without the two having
/// to agree forever.
final class ReaderFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-file-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        try write(name, Data(text.utf8))
    }

    // MARK: - What loads

    func testAUTF8SourceFileLoads() throws {
        let url = try write("main.swift", "let x = 1\nlet y = 2\n")
        let file = try ReaderFile.load(url: url)

        XCTAssertEqual(file.content, "let x = 1\nlet y = 2\n")
        XCTAssertEqual(file.kind, .source)
        XCTAssertEqual(file.byteSize, 20)
        XCTAssertEqual(file.url, url)
    }

    /// One stray byte must not lose a file that is otherwise readable. Latin-1
    /// maps every byte, so the fallback cannot itself fail.
    func testAFileWithOneInvalidUTF8ByteStillLoads() throws {
        var bytes = Data("caf".utf8)
        bytes.append(0xE9)  // é in latin-1, invalid alone in UTF-8
        bytes.append(contentsOf: Data("\n".utf8))
        let url = try write("notes.txt", bytes)

        let file = try ReaderFile.load(url: url)

        XCTAssertTrue(file.content.hasPrefix("caf"))
        XCTAssertEqual(file.kind, .source)
    }

    /// A name with no extension is answered by the widened kind table, so a
    /// build file opens as source rather than being handed to the system.
    func testAnExtensionlessBuildFileLoadsAsSource() throws {
        let url = try write("Makefile", "all:\n\techo hi\n")
        XCTAssertEqual(try ReaderFile.load(url: url).kind, .source)
    }

    func testAnEmptyFileLoads() throws {
        let url = try write("empty.rb", "")
        let file = try ReaderFile.load(url: url)

        XCTAssertEqual(file.content, "")
        XCTAssertEqual(file.byteSize, 0)
    }

    /// The one kind resolved by content rather than by name, so the first line
    /// has to be read before the kind is settled.
    func testATranscriptIsRecognisedFromItsFirstLine() throws {
        let url = try write(
            "agent.jsonl",
            #"{"agentId":"a1","message":{"role":"assistant"}}"# + "\n"
        )
        XCTAssertEqual(try ReaderFile.load(url: url).kind, .transcript)
    }

    func testJSONLThatIsNotATranscriptLoadsAsSource() throws {
        let url = try write("data.jsonl", #"{"a":1}"# + "\n")
        XCTAssertEqual(try ReaderFile.load(url: url).kind, .source)
    }

    /// Read from its path, never as a string — which is why the size cap and
    /// the binary sniff both have to be answered before any text is decoded.
    func testAnImageLoadsWithoutBeingReadAsText() throws {
        var png = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic, then a NUL
        png.append(0x00)
        let url = try write("shot.png", png)

        let file = try ReaderFile.load(url: url)

        XCTAssertEqual(file.kind, .image)
        XCTAssertEqual(
            file.content, "",
            "an image carries no text, and its NUL must not read as binary"
        )
        XCTAssertEqual(file.byteSize, 5)
    }

    // MARK: - What does not load

    func testAMissingFileIsUnreadable() {
        let url = dir.appendingPathComponent("nope.swift")
        XCTAssertThrowsError(try ReaderFile.load(url: url)) { error in
            XCTAssertEqual(
                error as? ReaderFile.LoadFailure, .unreadable
            )
        }
    }

    func testABinaryFileIsRefused() throws {
        var bytes = Data("plausible text".utf8)
        bytes.append(0x00)
        let url = try write("thing.bin", bytes)

        XCTAssertThrowsError(try ReaderFile.load(url: url)) { error in
            XCTAssertEqual(error as? ReaderFile.LoadFailure, .notText)
        }
    }

    /// A text-looking extension does not exempt a file from the sniff.
    func testATextExtensionHoldingBinaryIsStillRefused() throws {
        var bytes = Data("log line".utf8)
        bytes.append(0x00)
        let url = try write("output.log", bytes)

        XCTAssertThrowsError(try ReaderFile.load(url: url)) { error in
            XCTAssertEqual(error as? ReaderFile.LoadFailure, .notText)
        }
    }

    func testAFileOverTheCapIsRefusedWithItsNumbers() throws {
        let url = try write("big.txt", String(repeating: "x", count: 500))

        XCTAssertThrowsError(
            try ReaderFile.load(url: url, capOverride: 100)
        ) { error in
            XCTAssertEqual(
                error as? ReaderFile.LoadFailure,
                .tooLarge(byteSize: 500, cap: 100),
                "the reader is told by how much, not just that it failed"
            )
        }
    }

    func testAFileExactlyAtTheCapLoads() throws {
        let url = try write("edge.txt", String(repeating: "x", count: 100))
        XCTAssertEqual(
            try ReaderFile.load(url: url, capOverride: 100).byteSize, 100
        )
    }

    /// The sniff reads a window, not the file. A NUL beyond it is not found —
    /// pinned so the limit is a known trade rather than a surprise.
    func testANULBeyondTheSniffWindowIsNotFound() throws {
        var bytes = Data(String(repeating: "a", count: ReaderFile.sniffWindow).utf8)
        bytes.append(0x00)
        let url = try write("late.txt", bytes)

        XCTAssertNoThrow(try ReaderFile.load(url: url))
    }

    // MARK: - Drift

    func testAnUntouchedFileHasNotDrifted() throws {
        let url = try write("a.swift", "let x = 1\n")
        let file = try ReaderFile.load(url: url)

        XCTAssertFalse(FileDriftCheck.hasDrifted(file))
    }

    func testChangedContentHasDrifted() throws {
        let url = try write("a.swift", "let x = 1\n")
        let file = try ReaderFile.load(url: url)

        try Data("let x = 2\n".utf8).write(to: url)

        XCTAssertTrue(FileDriftCheck.hasDrifted(file))
    }

    /// The reason the check is two-stage. A moved stat is a reason to look, not
    /// an answer — a build step that rewrites a file byte-for-byte would
    /// otherwise mark every note in it, and a marker that fires on nothing
    /// stops being read.
    func testAFileRewrittenWithIdenticalContentHasNotDrifted() throws {
        let url = try write("a.swift", "let x = 1\n")
        let file = try ReaderFile.load(url: url)

        // Move the modification date without changing a byte.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: url.path
        )

        XCTAssertNotEqual(
            ReaderFile.stat(url)?.modifiedAt, file.modifiedAt,
            "precondition: the stat really did move"
        )
        XCTAssertFalse(
            FileDriftCheck.hasDrifted(file),
            "the stat moved and the content did not, so nothing is reported"
        )
    }

    /// The quote stays true; what stops being true is that the path leads to it.
    func testADeletedFileHasDrifted() throws {
        let url = try write("a.swift", "let x = 1\n")
        let file = try ReaderFile.load(url: url)

        try FileManager.default.removeItem(at: url)

        XCTAssertTrue(FileDriftCheck.hasDrifted(file))
    }

    func testAGrownFileHasDrifted() throws {
        let url = try write("a.swift", "let x = 1\n")
        let file = try ReaderFile.load(url: url)

        try Data("let x = 1\nlet y = 2\n".utf8).write(to: url)

        XCTAssertTrue(FileDriftCheck.hasDrifted(file))
    }
}
