import XCTest

@testable import Galactic

/// What each prompt actually says.
///
/// The sheet itself is not worth testing — a test that clicked Discard would be
/// testing `NSAlert`. The sentence is, because wording is the part of a
/// destructive path that rots: a count that reads "1 notes", a prompt that
/// stops mentioning the file it is about, or a promise of recoverability that
/// was never true. Each of those ships silently.
final class FileConfirmationsTests: XCTestCase {

    func testTheCountReadsAsEnglishAtOne() {
        XCTAssertEqual(FileConfirmations.notesPhrase(1), "1 note")
        XCTAssertEqual(FileConfirmations.notesPhrase(2), "2 notes")
        XCTAssertEqual(FileConfirmations.notesPhrase(0), "0 notes")
    }

    /// Every prompt has to carry the finality, because none of these is
    /// recoverable and a reader is entitled to assume an undo exists otherwise.
    func testEveryPromptSaysTheNotesCannotComeBack() {
        let details = [
            FileConfirmations.closeDetail(fileName: "user.rb", count: 2),
            FileConfirmations.reloadDetail(fileName: "user.rb", count: 2),
            FileConfirmations.quitDetail(count: 2, fileCount: 1),
            FileConfirmations.switchSetDetail(setName: "Default", count: 2),
        ]
        for detail in details {
            XCTAssertTrue(
                detail.contains("cannot be recovered"),
                "a prompt that does not say so: \(detail)"
            )
        }
    }

    /// Closing takes one file's notes, so the prompt names that file. A reader
    /// with notes on four files needs to know which they are about to lose.
    func testClosingNamesTheFileAndItsOwnCount() {
        let detail = FileConfirmations.closeDetail(
            fileName: "user.rb", count: 3
        )

        XCTAssertTrue(detail.contains("user.rb"))
        XCTAssertTrue(detail.contains("3 notes"))
    }

    /// Rereading has to explain *why* the notes cannot survive it, or it reads
    /// as an arbitrary refusal to keep them.
    func testRereadingExplainsWhyTheNotesGo() {
        let detail = FileConfirmations.reloadDetail(
            fileName: "user.rb", count: 1
        )

        XCTAssertTrue(detail.contains("1 note"))
        XCTAssertTrue(detail.contains("as they were read"))
        XCTAssertTrue(detail.contains("replaces those lines"))
    }

    /// At quit the reader cannot see the strip, so notes alone do not tell them
    /// how much work this is.
    func testQuittingCountsFilesAsWellAsNotes() {
        XCTAssertTrue(
            FileConfirmations.quitDetail(count: 5, fileCount: 2)
                .contains("5 notes across 2 files")
        )
        XCTAssertTrue(
            FileConfirmations.quitDetail(count: 1, fileCount: 1)
                .contains("1 note across 1 file")
        )
    }

    func testSwitchingSetsNamesTheSetBeingLeft() {
        XCTAssertTrue(
            FileConfirmations.switchSetDetail(setName: "auth", count: 2)
                .contains("in auth")
        )
    }
}
