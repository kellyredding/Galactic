import XCTest

@testable import Galactic

/// Reading a query that changes the root rather than filtering it.
///
/// One field does both, told apart by how the query starts — the shell's
/// convention, which keeps the common case free of a mode to be in.
final class FileRootInputTests: XCTestCase {

    func testAQueryStartingWithASlashIsARootChange() {
        XCTAssertTrue(FileRootInput.isRootChange("/work/project"))
        XCTAssertTrue(FileRootInput.isRootChange("~"))
        XCTAssertTrue(FileRootInput.isRootChange("~/projects"))
    }

    func testAnOrdinaryQueryIsAFilter() {
        XCTAssertFalse(FileRootInput.isRootChange("usermodel"))
        XCTAssertFalse(FileRootInput.isRootChange("src/user.rb"))
        XCTAssertFalse(FileRootInput.isRootChange(""))
    }

    /// A relative path that happens to contain a slash is still a filter — the
    /// distinction is the *leading* character, so typing a path fragment to
    /// narrow results keeps working.
    func testASlashInTheMiddleDoesNotMakeItAPath() {
        XCTAssertFalse(FileRootInput.isRootChange("models/user"))
    }

    // MARK: - Expansion

    func testTildeExpandsToHome() {
        XCTAssertEqual(
            FileRootInput.expandedPath("~"), NSHomeDirectory()
        )
        XCTAssertEqual(
            FileRootInput.expandedPath("~/projects"),
            NSHomeDirectory() + "/projects"
        )
    }

    func testAnAbsolutePathIsTakenAsGiven() {
        XCTAssertEqual(
            FileRootInput.expandedPath("/work/project"), "/work/project"
        )
    }

    /// Nil rather than a guess, so a caller can use this as the test rather than
    /// asking two questions.
    func testAFilterExpandsToNothing() {
        XCTAssertNil(FileRootInput.expandedPath("usermodel"))
    }

    // MARK: - Completion

    func testCompletionExtendsToTheSharedPrefix() {
        XCTAssertEqual(
            FileRootInput.completion(
                for: "/work/pro",
                directories: ["/work/project", "/work/projections"]
            ),
            "/work/project",
            "as far as every candidate agrees, and no further"
        )
    }

    /// A leniently-matched segment is *corrected*, not preserved: the
    /// extension is taken from the candidate's own spelling, so what lands in
    /// the field is a path that exists.
    func testCompletionCorrectsTheCaseOfWhatWasTyped() {
        XCTAssertEqual(
            FileRootInput.completion(
                for: "/work/lib", directories: ["/work/Library"]
            ),
            "/work/Library/"
        )
    }

    /// Lenience *gains* a completion here rather than costing one, which is the
    /// opposite of what this test asserted while the shared prefix was still
    /// measured case-sensitively: `Desktop` and `dev` agree on two characters
    /// once case stops separating them, so Tab advances by both instead of
    /// sitting still.
    func testCompletionSharesWhatMixedCasingStillAgreesOn() {
        XCTAssertEqual(
            FileRootInput.completion(
                for: "/work/d",
                directories: ["/work/Desktop", "/work/dev"]
            ),
            "/work/de"
        )
    }

    /// **The reported defect.** Once candidates were chosen leniently, the
    /// shared prefix was still measured case-sensitively — so a folder holding
    /// both `kajabi-dev` and `Kajabi-Dash` shared nothing at all for `kaj`, and
    /// Tab did nothing where six characters were obviously common.
    func testCompletionSharesAPrefixAcrossMixedCasing() {
        XCTAssertEqual(
            FileRootInput.completion(
                for: "/work/kaj",
                directories: [
                    "/work/kajabi-dev", "/work/Kajabi-Dash", "/work/kajabi_theme",
                ]
            ),
            "/work/kajabi"
        )
    }

    /// And the letters come from a candidate matching what was typed, so the
    /// reader's own casing is not rewritten out from under them.
    func testCompletionSpellsTheSharedPartAsTheReaderTypedIt() {
        XCTAssertEqual(
            FileRootInput.completion(
                for: "/work/Kaj",
                directories: ["/work/Kajabi-Dash", "/work/Kajabi-Mobile"]
            ),
            "/work/Kajabi-",
            "uppercase typed, so only the uppercase siblings are candidates"
        )
    }

    /// Names that share nothing complete to nothing, however the case falls.
    /// Folding case widens what counts as agreement; it does not invent any.
    func testNamesSharingNothingStillCompleteToNothing() {
        XCTAssertEqual(
            FileRootInput.completion(
                for: "/work/",
                directories: ["/work/Beta", "/work/alpha"]
            ),
            nil,
            "two names sharing nothing complete to nothing"
        )
    }

    func testCompletionKeepsAnUppercaseSegmentExact() {
        XCTAssertNil(
            FileRootInput.completion(
                for: "/work/LIB", directories: ["/work/Library"]
            )
        )
    }

    /// Candidates that diverge at the very next character add nothing, even
    /// though they all match what was typed. One press moving nowhere is how a
    /// reader learns they have to choose.
    func testCandidatesDivergingAtTheNextCharacterAddNothing() {
        XCTAssertNil(
            FileRootInput.completion(
                for: "/work/pro",
                directories: ["/work/project", "/work/prototype"]
            )
        )
    }

    /// One candidate completes the whole way, and closes with the separator —
    /// the segment is settled, so the next thing typed belongs to the next one.
    func testASingleCandidateCompletesFullyAndClosesTheSegment() {
        XCTAssertEqual(
            FileRootInput.completion(
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
            FileRootInput.completion(
                for: "~", directories: [NSHomeDirectory()]
            ),
            "~/"
        )
    }

    /// A name typed in full is settled even with longer siblings present, which
    /// is what makes a second press move rather than sit there.
    func testANameTypedInFullClosesDespiteLongerSiblings() {
        XCTAssertEqual(
            FileRootInput.completion(
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
            FileRootInput.completion(
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
            FileRootInput.completion(
                for: "/work/", directories: ["/work/alpha", "/work/beta"]
            )
        )
    }

    func testNoCandidatesCompleteToNothing() {
        XCTAssertNil(
            FileRootInput.completion(
                for: "/work/zzz", directories: ["/work/alpha"]
            )
        )
    }

    func testAFilterIsNeverCompleted() {
        XCTAssertNil(
            FileRootInput.completion(
                for: "usermodel", directories: ["/work/usermodels"]
            )
        )
    }

    /// A reader who typed `~` keeps seeing `~`. Replacing it with their home
    /// path would be correct and would read as the field rewriting them.
    func testATildeQueryIsCompletedBackIntoATildeQuery() {
        let home = NSHomeDirectory()
        let completed = FileRootInput.completion(
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
            FileRootInput.candidateParent(of: "~/pro"), home
        )
        XCTAssertEqual(
            FileRootInput.candidateParent(of: "~/projects/"),
            "\(home)/projects"
        )
    }

    func testTheCandidateParentOfTheFilesystemRootIsItself() {
        XCTAssertEqual(FileRootInput.candidateParent(of: "/"), "/")
    }

    func testAFilterHasNoCandidateParent() {
        XCTAssertNil(FileRootInput.candidateParent(of: "usermodel"))
    }

    // MARK: - Relative paths

    private let route = "/Users/someone/projects"

    /// The trap this rule exists for. There are more dotfiles in a checkout
    /// than there are reasons to type `..`, and treating a leading dot as a
    /// path turns a common filter into a failed directory lookup — which reads
    /// as the file not existing.
    func testADotfileQueryIsStillAFilter() {
        XCTAssertFalse(
            FileRootInput.isRootChange(".env", route: route)
        )
        XCTAssertFalse(
            FileRootInput.isRootChange(".gitignore", route: route)
        )
        XCTAssertFalse(
            FileRootInput.isRootChange("..foo", route: route)
        )
    }

    func testDotAndDotDotAreRelativePaths() {
        XCTAssertTrue(FileRootInput.isRootChange(".", route: route))
        XCTAssertTrue(FileRootInput.isRootChange("..", route: route))
        XCTAssertTrue(FileRootInput.isRootChange("./src", route: route))
        XCTAssertTrue(FileRootInput.isRootChange("../src", route: route))
    }

    /// Without a route there is nothing for them to be relative *to*, so they
    /// stay filters rather than resolving against a guess.
    func testARelativePathNeedsARoute() {
        XCTAssertFalse(FileRootInput.isRootChange(".."))
        XCTAssertNil(FileRootInput.expandedPath(".."))
    }

    func testDotDotGoesUpFromTheRoute() {
        XCTAssertEqual(
            FileRootInput.expandedPath("..", route: route),
            "/Users/someone"
        )
        XCTAssertEqual(
            FileRootInput.expandedPath("../Documents", route: route),
            "/Users/someone/Documents"
        )
        XCTAssertEqual(
            FileRootInput.expandedPath("../../shared", route: route),
            "/Users/shared",
            "each leading .. consumes one component of the route"
        )
    }

    func testASingleDotIsTheRouteItself() {
        XCTAssertEqual(
            FileRootInput.expandedPath(".", route: route), route
        )
        XCTAssertEqual(
            FileRootInput.expandedPath("./src", route: route),
            "\(route)/src"
        )
    }

    /// The separator carries the "show me what is inside" meaning the folder
    /// list reads, so resolving must not eat it.
    func testATrailingSeparatorSurvivesResolution() {
        XCTAssertEqual(
            FileRootInput.expandedPath("../", route: route),
            "/Users/someone/"
        )
    }

    /// An interior `..` is left for the filesystem to settle. Standardising the
    /// whole path would also rewrite a symlinked prefix, and every caller here
    /// matches the result against names read from a directory — where a
    /// resolved spelling matches none of them.
    func testAnInteriorDotDotIsLeftAlone() {
        XCTAssertEqual(
            FileRootInput.expandedPath("../a/../b", route: route),
            "/Users/someone/a/../b"
        )
    }

    /// Completion keeps the reader's spelling, exactly as it does for `~`.
    /// Answering with an absolute path would discard the part they chose to say
    /// and change what a following `..` means.
    func testARelativeCompletionStaysRelative() {
        XCTAssertEqual(
            FileRootInput.completion(
                for: "../Doc",
                directories: ["/Users/someone/Documents"],
                route: route
            ),
            "../Documents/"
        )
    }

    func testTheCandidateParentOfARelativePathResolves() {
        XCTAssertEqual(
            FileRootInput.candidateParent(of: "../Doc", route: route),
            "/Users/someone"
        )
    }

    // MARK: - The prefix primitive

    func testLongestCommonPrefix() {
        XCTAssertEqual(
            FileRootInput.longestCommonPrefix(["abcd", "abce"]), "abc"
        )
        XCTAssertEqual(
            FileRootInput.longestCommonPrefix(["abc"]), "abc"
        )
        XCTAssertEqual(
            FileRootInput.longestCommonPrefix(["abc", "xyz"]), ""
        )
        XCTAssertEqual(FileRootInput.longestCommonPrefix([]), "")
    }
}
