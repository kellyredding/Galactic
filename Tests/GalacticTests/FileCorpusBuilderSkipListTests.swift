import XCTest

@testable import Galactic

/// The skip list belongs to the root, not to whoever opened it.
///
/// Two applications sharing one index used to each supply their own, which made
/// the same corpus mean different things depending on who built it — the same
/// shard published with different contents, each rewalk undoing the other's,
/// with nothing recording that they disagreed.
final class FileCorpusBuilderSkipListTests: XCTestCase {

    func testAHomeRootSkipsMoreThanARepositoryDoes() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let list = FileCorpusBuilder.skipList(forRoot: home)

        XCTAssertTrue(list.contains("Library"))
        XCTAssertTrue(list.contains("Photos Library.photoslibrary"))
        XCTAssertTrue(list.contains("OrbStack"))
        XCTAssertTrue(
            list.isSuperset(of: FileCorpusBuilder.defaultSkipList),
            "the project noise still has to be skipped inside a home directory"
        )
    }

    /// A repository may hold a directory called `Library`, and skipping it there
    /// would hide real source — which is why the home entries are not simply
    /// merged into the default list.
    func testARepositoryRootDoesNotSkipLibrary() {
        let repository = URL(fileURLWithPath: "/tmp/some-checkout")
        let list = FileCorpusBuilder.skipList(forRoot: repository)

        XCTAssertFalse(list.contains("Library"))
        XCTAssertEqual(list, FileCorpusBuilder.defaultSkipList)
    }

    /// The point of deriving it: the same root gives the same answer to every
    /// caller, so two applications cannot disagree about one corpus.
    func testTheAnswerDependsOnlyOnTheRoot() {
        let root = URL(fileURLWithPath: NSHomeDirectory())
        XCTAssertEqual(
            FileCorpusBuilder.skipList(forRoot: root),
            FileCorpusBuilder.skipList(forRoot: root)
        )
        // And a trailing slash is the same root.
        XCTAssertEqual(
            FileCorpusBuilder.skipList(forRoot: root),
            FileCorpusBuilder.skipList(
                forRoot: URL(fileURLWithPath: NSHomeDirectory() + "/")
            )
        )
    }

    func testARootAboveTheHomeDirectoryAlsoCoversIt() {
        XCTAssertTrue(
            FileCorpusBuilder.coversHomeDirectory("/"),
            "the root of the volume takes in the home directory"
        )
        XCTAssertTrue(
            FileCorpusBuilder.coversHomeDirectory(
                FilePaths.canonical(
                    URL(fileURLWithPath: NSHomeDirectory())
                        .deletingLastPathComponent()
                )
            ),
            "the directory holding every user takes in this one"
        )
        XCTAssertFalse(
            FileCorpusBuilder.coversHomeDirectory("/tmp/some-checkout")
        )
    }
}
