import XCTest

@testable import Galactic

/// Reading a query that changes the root rather than filtering it.
///
/// One field does both, told apart by how the query starts — the shell's
/// convention, which keeps the common case free of a mode to be in.
final class FilePickerRootInputTests: XCTestCase {

    func testAQueryStartingWithASlashIsARootChange() {
        XCTAssertTrue(FilePickerRootInput.isRootChange("/work/project"))
        XCTAssertTrue(FilePickerRootInput.isRootChange("~"))
        XCTAssertTrue(FilePickerRootInput.isRootChange("~/projects"))
    }

    func testAnOrdinaryQueryIsAFilter() {
        XCTAssertFalse(FilePickerRootInput.isRootChange("usermodel"))
        XCTAssertFalse(FilePickerRootInput.isRootChange("src/user.rb"))
        XCTAssertFalse(FilePickerRootInput.isRootChange(""))
    }

    /// A relative path that happens to contain a slash is still a filter — the
    /// distinction is the *leading* character, so typing a path fragment to
    /// narrow results keeps working.
    func testASlashInTheMiddleDoesNotMakeItAPath() {
        XCTAssertFalse(FilePickerRootInput.isRootChange("models/user"))
    }

    // MARK: - Expansion

    func testTildeExpandsToHome() {
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("~"), NSHomeDirectory()
        )
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("~/projects"),
            NSHomeDirectory() + "/projects"
        )
    }

    func testAnAbsolutePathIsTakenAsGiven() {
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("/work/project"), "/work/project"
        )
    }

    /// Nil rather than a guess, so a caller can use this as the test rather than
    /// asking two questions.
    func testAFilterExpandsToNothing() {
        XCTAssertNil(FilePickerRootInput.expandedPath("usermodel"))
    }

    // MARK: - Completion

    func testCompletionExtendsToTheSharedPrefix() {
        XCTAssertEqual(
            FilePickerRootInput.completion(
                for: "/work/pro",
                directories: ["/work/project", "/work/projections"]
            ),
            "/work/project",
            "as far as every candidate agrees, and no further"
        )
    }

    /// Candidates that diverge at the very next character add nothing, even
    /// though they all match what was typed. One press moving nowhere is how a
    /// reader learns they have to choose.
    func testCandidatesDivergingAtTheNextCharacterAddNothing() {
        XCTAssertNil(
            FilePickerRootInput.completion(
                for: "/work/pro",
                directories: ["/work/project", "/work/prototype"]
            )
        )
    }

    /// One candidate completes the whole way.
    func testASingleCandidateCompletesFully() {
        XCTAssertEqual(
            FilePickerRootInput.completion(
                for: "/work/pro", directories: ["/work/project"]
            ),
            "/work/project"
        )
    }

    /// Nothing to add is nil, which is what makes a second press meaningful:
    /// the field not moving is the answer.
    func testCandidatesThatDisagreeImmediatelyAddNothing() {
        XCTAssertNil(
            FilePickerRootInput.completion(
                for: "/work/", directories: ["/work/alpha", "/work/beta"]
            )
        )
    }

    func testNoCandidatesCompleteToNothing() {
        XCTAssertNil(
            FilePickerRootInput.completion(
                for: "/work/zzz", directories: ["/work/alpha"]
            )
        )
    }

    func testAFilterIsNeverCompleted() {
        XCTAssertNil(
            FilePickerRootInput.completion(
                for: "usermodel", directories: ["/work/usermodels"]
            )
        )
    }

    /// A reader who typed `~` keeps seeing `~`. Replacing it with their home
    /// path would be correct and would read as the field rewriting them.
    func testATildeQueryIsCompletedBackIntoATildeQuery() {
        let home = NSHomeDirectory()
        let completed = FilePickerRootInput.completion(
            for: "~/pro", directories: ["\(home)/projects"]
        )

        XCTAssertEqual(completed, "~/projects")
    }

    // MARK: - The prefix primitive

    func testLongestCommonPrefix() {
        XCTAssertEqual(
            FilePickerRootInput.longestCommonPrefix(["abcd", "abce"]), "abc"
        )
        XCTAssertEqual(
            FilePickerRootInput.longestCommonPrefix(["abc"]), "abc"
        )
        XCTAssertEqual(
            FilePickerRootInput.longestCommonPrefix(["abc", "xyz"]), ""
        )
        XCTAssertEqual(FilePickerRootInput.longestCommonPrefix([]), "")
    }
}
