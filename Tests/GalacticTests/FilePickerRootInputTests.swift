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

    /// One candidate completes the whole way, and closes with the separator —
    /// the segment is settled, so the next thing typed belongs to the next one.
    func testASingleCandidateCompletesFullyAndClosesTheSegment() {
        XCTAssertEqual(
            FilePickerRootInput.completion(
                for: "/work/pro", directories: ["/work/project"]
            ),
            "/work/project/"
        )
    }

    /// The case that did nothing at all before, and the reason Tab appeared to
    /// stop working one level in: the parent of `~` is `/Users`, whose only
    /// matching child is the home directory itself, so the shared prefix
    /// equalled what was typed and the guard refused it.
    func testATildeAloneCompletesToATildeSlash() {
        XCTAssertEqual(
            FilePickerRootInput.completion(
                for: "~", directories: [NSHomeDirectory()]
            ),
            "~/"
        )
    }

    /// A name typed in full is settled even with longer siblings present, which
    /// is what makes a second press move rather than sit there.
    func testANameTypedInFullClosesDespiteLongerSiblings() {
        XCTAssertEqual(
            FilePickerRootInput.completion(
                for: "/work/project",
                directories: ["/work/project", "/work/projections"]
            ),
            "/work/project/"
        )
    }

    /// The tripwire for the opposite mistake. Completing to a shared prefix
    /// that happens to name a real directory must **not** close it: doing so
    /// commits a choice the reader has not made and puts the sibling out of
    /// reach by typing.
    func testASharedPrefixNamingADirectoryIsNotClosed() {
        XCTAssertEqual(
            FilePickerRootInput.completion(
                for: "/work/pro",
                directories: ["/work/project", "/work/projections"]
            ),
            "/work/project",
            "closing this would make /work/projections unreachable"
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

        XCTAssertEqual(completed, "~/projects/")
    }

    // MARK: - Which directory the candidates come from

    /// The trailing separator is the whole distinction, and it is why this
    /// cannot be `deletingLastPathComponent`: that strips a trailing slash
    /// before removing a component, so it answers the grandparent for the
    /// second case and the folder list would offer the wrong directory's
    /// children.
    func testTheCandidateParentFollowsTheTrailingSeparator() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            FilePickerRootInput.candidateParent(of: "~/pro"), home
        )
        XCTAssertEqual(
            FilePickerRootInput.candidateParent(of: "~/projects/"),
            "\(home)/projects"
        )
    }

    func testTheCandidateParentOfTheFilesystemRootIsItself() {
        XCTAssertEqual(FilePickerRootInput.candidateParent(of: "/"), "/")
    }

    func testAFilterHasNoCandidateParent() {
        XCTAssertNil(FilePickerRootInput.candidateParent(of: "usermodel"))
    }

    // MARK: - Relative paths

    private let route = "/Users/someone/projects"

    /// The trap this rule exists for. There are more dotfiles in a checkout
    /// than there are reasons to type `..`, and treating a leading dot as a
    /// path turns a common filter into a failed directory lookup — which reads
    /// as the file not existing.
    func testADotfileQueryIsStillAFilter() {
        XCTAssertFalse(
            FilePickerRootInput.isRootChange(".env", route: route)
        )
        XCTAssertFalse(
            FilePickerRootInput.isRootChange(".gitignore", route: route)
        )
        XCTAssertFalse(
            FilePickerRootInput.isRootChange("..foo", route: route)
        )
    }

    func testDotAndDotDotAreRelativePaths() {
        XCTAssertTrue(FilePickerRootInput.isRootChange(".", route: route))
        XCTAssertTrue(FilePickerRootInput.isRootChange("..", route: route))
        XCTAssertTrue(FilePickerRootInput.isRootChange("./src", route: route))
        XCTAssertTrue(FilePickerRootInput.isRootChange("../src", route: route))
    }

    /// Without a route there is nothing for them to be relative *to*, so they
    /// stay filters rather than resolving against a guess.
    func testARelativePathNeedsARoute() {
        XCTAssertFalse(FilePickerRootInput.isRootChange(".."))
        XCTAssertNil(FilePickerRootInput.expandedPath(".."))
    }

    func testDotDotGoesUpFromTheRoute() {
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("..", route: route),
            "/Users/someone"
        )
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("../Documents", route: route),
            "/Users/someone/Documents"
        )
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("../../shared", route: route),
            "/Users/shared",
            "each leading .. consumes one component of the route"
        )
    }

    func testASingleDotIsTheRouteItself() {
        XCTAssertEqual(
            FilePickerRootInput.expandedPath(".", route: route), route
        )
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("./src", route: route),
            "\(route)/src"
        )
    }

    /// The separator carries the "show me what is inside" meaning the folder
    /// list reads, so resolving must not eat it.
    func testATrailingSeparatorSurvivesResolution() {
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("../", route: route),
            "/Users/someone/"
        )
    }

    /// An interior `..` is left for the filesystem to settle. Standardising the
    /// whole path would also rewrite a symlinked prefix, and every caller here
    /// matches the result against names read from a directory — where a
    /// resolved spelling matches none of them.
    func testAnInteriorDotDotIsLeftAlone() {
        XCTAssertEqual(
            FilePickerRootInput.expandedPath("../a/../b", route: route),
            "/Users/someone/a/../b"
        )
    }

    /// Completion keeps the reader's spelling, exactly as it does for `~`.
    /// Answering with an absolute path would discard the part they chose to say
    /// and change what a following `..` means.
    func testARelativeCompletionStaysRelative() {
        XCTAssertEqual(
            FilePickerRootInput.completion(
                for: "../Doc",
                directories: ["/Users/someone/Documents"],
                route: route
            ),
            "../Documents/"
        )
    }

    func testTheCandidateParentOfARelativePathResolves() {
        XCTAssertEqual(
            FilePickerRootInput.candidateParent(of: "../Doc", route: route),
            "/Users/someone"
        )
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
