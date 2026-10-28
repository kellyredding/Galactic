import XCTest

@testable import Galactic

/// A review is pointed at when it can be kept, and typed in whole when it
/// cannot — and either way `send` runs exactly once.
final class ReviewDeliveryTests: XCTestCase {

    private var stored: [StoredReview] = []
    private var sent: [String] = []

    override func setUp() {
        stored = []
        sent = []
    }

    /// A store that keeps every review and answers `id`.
    private func store(answering id: Int64?, async: Bool = false) -> ReviewStore {
        ReviewStore(
            store: { review, completion in
                self.stored.append(review)
                if async {
                    DispatchQueue.global().async { completion(id) }
                } else {
                    completion(id)
                }
            },
            readCommand: { "read-review \($0)" }
        )
    }

    private func deliver(
        noteCount: Int = 2,
        kind: ReviewDelivery.Kind = .scrollback,
        destination: ReviewDestination?
    ) {
        ReviewDelivery.deliver(
            message: "the whole review",
            noteCount: noteCount,
            kind: kind,
            eventType: "scrollback:reviewed",
            detail: ["pane": "session", "notes": ["a", "b"]],
            destination: destination,
            send: { self.sent.append($0) }
        )
    }

    private func destination(_ store: ReviewStore) -> ReviewDestination {
        ReviewDestination(store: store, sessionID: 789, source: "test/source")
    }

    // MARK: - Kept

    func testAKeptReviewIsSentAsAPointer() {
        deliver(destination: destination(store(answering: 133438)))

        XCTAssertEqual(sent, [
            "I've sent 2 scrollback review notes. Read them with "
                + "`read-review 133438`, then quote each note before you "
                + "respond to it.",
        ])
    }

    func testTheKeptReviewCarriesTheMessageAndItsCount() {
        deliver(destination: destination(store(answering: 1)))

        let review = try! XCTUnwrap(stored.first)
        XCTAssertEqual(review.sessionID, 789)
        XCTAssertEqual(review.eventType, "scrollback:reviewed")
        XCTAssertEqual(review.source, "test/source")
        XCTAssertEqual(review.detail["message"] as? String, "the whole review")
        XCTAssertEqual(review.detail["note_count"] as? Int, 2)
        XCTAssertEqual(review.detail["pane"] as? String, "session")
        XCTAssertEqual(review.detail["notes"] as? [String], ["a", "b"])
    }

    func testAPointerAnsweredOffTheMainQueueIsSentOnIt() {
        let done = expectation(description: "sent")
        ReviewDelivery.deliver(
            message: "the whole review",
            noteCount: 1,
            kind: .file,
            eventType: "files:reviewed",
            destination: destination(store(answering: 7, async: true)),
            send: { text in
                XCTAssertTrue(Thread.isMainThread)
                self.sent.append(text)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sent.count, 1)
    }

    func testAStoreAnsweringTwiceStillSendsOnce() {
        let twice = ReviewStore(
            store: { _, completion in
                completion(5)
                completion(6)
            },
            readCommand: { "read-review \($0)" }
        )
        deliver(destination: destination(twice))

        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("`read-review 5`"))
    }

    // MARK: - Typed in whole

    func testNoDestinationSendsTheReviewWhole() {
        deliver(destination: nil)

        XCTAssertEqual(sent, ["the whole review"])
        XCTAssertTrue(stored.isEmpty)
    }

    func testAStoreThatKeptNothingSendsTheReviewWhole() {
        deliver(destination: destination(store(answering: nil)))

        XCTAssertEqual(sent, ["the whole review"])
    }

    func testAReviewWithNoNotesIsNotKept() {
        deliver(noteCount: 0, destination: destination(store(answering: 1)))

        XCTAssertEqual(sent, ["the whole review"])
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: - Wording

    func testOneNoteIsSingular() {
        XCTAssertEqual(
            ReviewDelivery.pointer(
                noteCount: 1, kind: .file, readCommand: "galaxy-timeline message 9"),
            "I've sent 1 file review note. Read it with "
                + "`galaxy-timeline message 9`, then quote the note before you "
                + "respond to it."
        )
    }

    func testTheCutOffPointerNamesWhatArrived() {
        XCTAssertEqual(
            ReviewDelivery.cutOffPointer(
                receivedCharacters: 5780,
                sentCharacters: 9498,
                readCommand: "galaxy-timeline message 12"
            ),
            "The message I just sent you arrived cut off: only 5780 of its "
                + "9498 characters reached you. Read the full text with "
                + "`galaxy-timeline message 12` and work from that instead of "
                + "what you received."
        )
    }

    func testAPointerIsShortEnoughNotToBeCutOff() {
        let pointer = ReviewDelivery.pointer(
            noteCount: 9999, kind: .scrollback,
            readCommand: "galaxy-timeline message 9999999999")
        // A raw-mode pty takes 1,022 bytes at a time; the losses were in input
        // far larger than one of those.
        XCTAssertLessThan(pointer.utf8.count, 1022)
    }
}
