import XCTest
@testable import Galactic

/// The `annotation` channel's wire format, parsed.
///
/// Nothing checked this before it moved here: two hosts each wrote their own
/// switch over the same dictionaries, one of them covering four of the nine
/// cases. A body that fails to parse produces no message, no error, and no
/// log line — the page has already acted locally, so the only symptom is that
/// the app never hears about it.
final class AnnotationMessageTests: XCTestCase {

    // MARK: - Create, by anchor type

    func testLineRangeCreate() throws {
        let parsed = AnnotationMessage.from([
            "action": "create",
            "startLine": 3,
            "endLine": 7,
            "content": "note text",
        ])
        guard case let .create(startLine, endLine, content) = try XCTUnwrap(parsed)
        else { return XCTFail("expected .create, got \(String(describing: parsed))") }
        XCTAssertEqual(startLine, 3)
        XCTAssertEqual(endLine, 7)
        XCTAssertEqual(content, "note text")
    }

    /// The default when the page names no anchor type. Every reader that does
    /// not deal in rows, blocks, or whole-document anchors relies on it.
    func testMissingAnchorTypeFallsBackToLineRange() throws {
        let parsed = AnnotationMessage.from([
            "action": "create", "startLine": 1, "endLine": 1, "content": "x",
        ])
        guard case .create = try XCTUnwrap(parsed) else {
            return XCTFail("an absent anchorType must mean line_range")
        }
    }

    func testRowRangeCreate() throws {
        let parsed = AnnotationMessage.from([
            "action": "create",
            "anchorType": "row_range",
            "startRow": 2,
            "endRow": 5,
            "content": "c",
        ])
        guard case let .createRowRange(startRow, endRow, _) = try XCTUnwrap(parsed)
        else { return XCTFail("expected .createRowRange") }
        XCTAssertEqual(startRow, 2)
        XCTAssertEqual(endRow, 5)
    }

    func testBlockRangeCreateCarriesOptionalBlockContent() throws {
        let withContent = AnnotationMessage.from([
            "action": "create",
            "anchorType": "block_range",
            "startBlock": 0,
            "endBlock": 1,
            "blockContent": "para",
            "content": "c",
        ])
        guard case let .createBlockRange(_, _, blockContent, _)
            = try XCTUnwrap(withContent)
        else { return XCTFail("expected .createBlockRange") }
        XCTAssertEqual(blockContent, "para")

        let without = AnnotationMessage.from([
            "action": "create",
            "anchorType": "block_range",
            "startBlock": 0,
            "endBlock": 1,
            "content": "c",
        ])
        guard case let .createBlockRange(_, _, missing, _)
            = try XCTUnwrap(without)
        else { return XCTFail("block content is optional") }
        XCTAssertNil(missing)
    }

    /// Whole-document anchors carry no position at all. This is one of the
    /// cases the markdown reader used to drop.
    func testWholeCreateNeedsNothingButContent() throws {
        let parsed = AnnotationMessage.from([
            "action": "create", "anchorType": "whole", "content": "all of it",
        ])
        guard case let .createWhole(content) = try XCTUnwrap(parsed)
        else { return XCTFail("expected .createWhole") }
        XCTAssertEqual(content, "all of it")
    }

    // MARK: - The diff-range split

    /// Rows are what select the richer case, not a declared mode. A body that
    /// carries them must never come back as a plain line range, or the diff
    /// anchor loses its per-row payload and the file reference with it.
    func testRowsPromoteALineRangeToADiffRange() throws {
        let parsed = AnnotationMessage.from([
            "action": "create",
            "startLine": 10,
            "endLine": 12,
            "content": "c",
            "rows": [["kind": "add", "new_line": 11]],
            "filePath": "src/main.swift",
            "fileStartLine": 40,
            "fileEndLine": 42,
            "fileLineSide": "new",
        ])
        guard case let .createDiffRange(
            _, _, rows, filePath, fileStartLine, fileEndLine, fileLineSide, _
        ) = try XCTUnwrap(parsed) else {
            return XCTFail("rows must select .createDiffRange")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(filePath, "src/main.swift")
        XCTAssertEqual(fileStartLine, 40)
        XCTAssertEqual(fileEndLine, 42)
        XCTAssertEqual(fileLineSide, "new")
    }

    /// An empty rows array is not a diff selection. Treating it as one would
    /// build an anchor with no rows in it.
    func testEmptyRowsStaysAPlainLineRange() throws {
        let parsed = AnnotationMessage.from([
            "action": "create",
            "startLine": 1, "endLine": 2, "content": "c",
            "rows": [[String: Any]](),
        ])
        guard case .create = try XCTUnwrap(parsed) else {
            return XCTFail("an empty rows array must not select the diff case")
        }
    }

    /// A header-only diff selection has no line numbers on either side.
    func testDiffRangeToleratesAbsentFileReference() throws {
        let parsed = AnnotationMessage.from([
            "action": "create",
            "startLine": 1, "endLine": 1, "content": "c",
            "rows": [["kind": "file-header"]],
        ])
        guard case let .createDiffRange(
            _, _, _, filePath, fileStartLine, fileEndLine, fileLineSide, _
        ) = try XCTUnwrap(parsed) else {
            return XCTFail("expected .createDiffRange")
        }
        XCTAssertNil(filePath)
        XCTAssertNil(fileStartLine)
        XCTAssertNil(fileEndLine)
        XCTAssertNil(fileLineSide)
    }

    // MARK: - The rest of the channel

    func testUpdateDeleteAndDragReplace() throws {
        guard case let .update(number, content) = try XCTUnwrap(
            AnnotationMessage.from([
                "action": "update", "number": 4, "content": "edited",
            ])
        ) else { return XCTFail("expected .update") }
        XCTAssertEqual(number, 4)
        XCTAssertEqual(content, "edited")

        guard case let .delete(deleted) = try XCTUnwrap(
            AnnotationMessage.from(["action": "delete", "number": 9])
        ) else { return XCTFail("expected .delete") }
        XCTAssertEqual(deleted, 9)

        guard case let .confirmDragReplace(startIdx, endIdx) = try XCTUnwrap(
            AnnotationMessage.from([
                "action": "confirmDragReplace", "startIdx": 2, "endIdx": 6,
            ])
        ) else { return XCTFail("expected .confirmDragReplace") }
        XCTAssertEqual(startIdx, 2)
        XCTAssertEqual(endIdx, 6)
    }

    /// Not an annotation — the diff reader's Viewed checkbox rides this
    /// channel rather than opening a second one for a single boolean.
    func testSetViewed() throws {
        guard case let .setViewed(filePath, isViewed) = try XCTUnwrap(
            AnnotationMessage.from([
                "action": "setViewed", "filePath": "a/b.swift", "isViewed": true,
            ])
        ) else { return XCTFail("expected .setViewed") }
        XCTAssertEqual(filePath, "a/b.swift")
        XCTAssertTrue(isViewed)
    }

    // MARK: - Refusals

    func testUnknownAndMalformedBodiesParseToNothing() {
        let rejected: [(String, [String: Any])] = [
            ("no action at all", ["startLine": 1]),
            ("an action nobody handles", ["action": "teleport"]),
            ("create missing endLine", ["action": "create", "startLine": 1]),
            (
                "row_range missing endRow",
                ["action": "create", "anchorType": "row_range", "startRow": 1]
            ),
            ("update missing content", ["action": "update", "number": 1]),
            ("delete missing number", ["action": "delete"]),
            (
                "dragReplace missing endIdx",
                ["action": "confirmDragReplace", "startIdx": 1]
            ),
            (
                "setViewed missing isViewed",
                ["action": "setViewed", "filePath": "a"]
            ),
        ]
        for (label, body) in rejected {
            XCTAssertNil(
                AnnotationMessage.from(body),
                "\(label) should parse to nothing rather than a partial message"
            )
        }
    }

    /// Content is the one field with a default. A create with no content is a
    /// real thing — an empty form submitted — and must not be dropped.
    func testCreateWithoutContentDefaultsToEmptyRatherThanFailing() throws {
        guard case let .create(_, _, content) = try XCTUnwrap(
            AnnotationMessage.from([
                "action": "create", "startLine": 1, "endLine": 1,
            ])
        ) else { return XCTFail("a missing content must not reject the message") }
        XCTAssertEqual(content, "")
    }
}
