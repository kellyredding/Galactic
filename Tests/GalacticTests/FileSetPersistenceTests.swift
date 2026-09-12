import XCTest

@testable import Galactic

/// The saved shape, and the older shape it still has to read.
///
/// Both hosts nest this inside a larger document, and one of them discards the
/// whole document on any decode failure — so a record from before sets existed
/// has to read as something, not throw.
final class FileSetPersistenceTests: XCTestCase {

    private func decode(_ json: String) throws -> PersistedFileSetGroup {
        try JSONDecoder().decode(
            PersistedFileSetGroup.self, from: Data(json.utf8)
        )
    }

    func testAGroupSurvivesARoundTrip() throws {
        let group = PersistedFileSetGroup(
            sets: [
                PersistedFileSet(
                    id: "default-o", name: "Default", isDefault: true,
                    root: "/work", openPathRows: [["/work/a"]],
                    selectedPath: "/work/a"
                ),
                PersistedFileSet(
                    id: "x", name: "auth", isDefault: false, origin: .agent,
                    root: "/work", openPathRows: [["/work/b"], ["/work/c"]],
                    selectedPath: nil
                ),
            ],
            selectedID: "x"
        )

        let back = try JSONDecoder().decode(
            PersistedFileSetGroup.self, from: try JSONEncoder().encode(group)
        )

        XCTAssertEqual(back, group)
    }

    func testARecordFromBeforeSetsReadsAsAGroupOfOneDefault() throws {
        let group = try decode(
            #"{"root":"/work","openPathRows":[["/work/a"]],"selectedPath":"/work/a"}"#
        )

        XCTAssertEqual(group.sets.count, 1)
        XCTAssertTrue(group.sets[0].isDefault)
        XCTAssertEqual(group.sets[0].root, "/work")
        XCTAssertEqual(group.sets[0].openPathRows, [["/work/a"]])
        XCTAssertEqual(group.sets[0].selectedPath, "/work/a")
        XCTAssertNil(group.selectedID)
    }

    func testMissingFieldsFallBack() throws {
        let set = try XCTUnwrap(
            try decode(#"{"sets":[{"root":"/w"}]}"#).sets.first
        )

        XCTAssertEqual(set.id, "")
        XCTAssertEqual(set.name, "")
        XCTAssertTrue(set.isDefault)
        XCTAssertEqual(set.origin, .user)
        XCTAssertEqual(set.openPathRows, [])
        XCTAssertNil(set.selectedPath)
    }

    func testAnOriginThisBuildDoesNotKnowIsTheReaders() throws {
        let set = try XCTUnwrap(
            try decode(#"{"sets":[{"origin":"robot"}]}"#).sets.first
        )

        XCTAssertEqual(set.origin, .user)
    }

    func testAnEmptyRecordIsAnEmptyDefault() throws {
        let group = try decode("{}")

        XCTAssertEqual(group.sets.count, 1)
        XCTAssertTrue(group.sets[0].isDefault)
        XCTAssertEqual(group.sets[0].root, "")
    }
}
