import Combine
import XCTest
@testable import Galactic

/// The parts of the pane-registry contract the type system cannot hold.
///
/// Three of its requirements are semantic — the completion is always
/// asynchronous, the scrollback setter assigns only on a change, and the focus
/// fallback is ordered by name rather than by whatever the storage yields first.
/// A conformer that gets any of them wrong still compiles, and the reentrancy
/// one fails in a direction that looks correct while being developed, because it
/// needs an empty registry to show itself.
///
/// Two of the three are held here, verified by mutation: breaking the async path
/// or the equality guard fails a test. **The ordering requirement is not**, and
/// cannot be with only two pane kinds — see
/// `testTheLastResortFindsTheOnlyRemainingPane`. It rests on the protocol's doc
/// comment and on review until a third kind exists.
///
/// These test the reference conformer. They do not prove either app conforms
/// correctly — that is what the apps' own adoption and QA are for — but they
/// pin what "correctly" means in executable form, which prose alone did not.
final class TerminalPaneRegistryTests: XCTestCase {

    /// Let the main queue drain.
    private func settle() {
        let done = expectation(description: "settle")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: - The completion is always asynchronous

    /// The requirement's whole point: the path where the answer is already
    /// known is the one that must still not answer inline.
    func testTheCompletionIsAsynchronousWithNothingRegistered() {
        let registry = StubPaneRegistry()
        var completed = false

        registry.checkUnsavedWork(kinds: [.session, .shell]) { _ in
            completed = true
        }

        XCTAssertFalse(
            completed,
            "an empty registry must not answer before returning — a quit "
                + "replies from this completion after saying terminateLater"
        )
        settle()
        XCTAssertTrue(completed, "and it must still answer")
    }

    /// The same requirement on the populated path, so a conformer cannot pass
    /// by being async only when it has work to do.
    func testTheCompletionIsAsynchronousWithPanesRegistered() {
        let registry = StubPaneRegistry()
        let pane = NSObject()
        registry.registerPane(pane, kind: .session)
        var completed = false

        registry.checkUnsavedWork(kinds: [.session]) { _ in completed = true }

        XCTAssertFalse(
            completed,
            "both paths must have the same reentrancy semantics; one method "
                + "with two is the harder bug"
        )
        settle()
        XCTAssertTrue(completed)
    }

    // MARK: - Which panes, not whether any

    func testTheCompletionNamesThePanesHoldingWork() {
        let registry = StubPaneRegistry()
        let session = NSObject()
        let shell = NSObject()
        registry.registerPane(session, kind: .session)
        registry.registerPane(shell, kind: .shell)
        registry.kindsWithWork = [.shell]
        var reported: Set<TerminalPaneKind>?

        registry.checkUnsavedWork(kinds: [.session, .shell]) { reported = $0 }
        settle()

        XCTAssertEqual(
            reported, [.shell],
            "a caller naming panes in a sheet cannot recover the name from a "
                + "boolean"
        )
    }

    func testKindsNotAskedAboutAreNotReported() {
        let registry = StubPaneRegistry()
        let session = NSObject()
        let shell = NSObject()
        registry.registerPane(session, kind: .session)
        registry.registerPane(shell, kind: .shell)
        registry.kindsWithWork = [.session, .shell]
        var reported: Set<TerminalPaneKind>?

        registry.checkUnsavedWork(kinds: [.shell]) { reported = $0 }
        settle()

        XCTAssertEqual(
            reported, [.shell],
            "a stopped session's own pane is gone; only the caller knows that"
        )
    }

    func testAWithdrawnCheckerIsNotAsked() {
        let registry = StubPaneRegistry()
        let pane = NSObject()
        registry.registerPane(pane, kind: .shell)
        registry.kindsWithWork = [.shell]
        registry.unregisterUnsavedWorkChecker(ObjectIdentifier(pane))
        var reported: Set<TerminalPaneKind>?

        registry.checkUnsavedWork(kinds: [.shell]) { reported = $0 }
        settle()

        XCTAssertEqual(
            reported, [],
            "a stale entry blocks a quit that should have been allowed"
        )
    }

    // MARK: - The setter assigns only on a change

    func testTheScrollbackFlagPublishesOnlyRealChanges() {
        let registry = StubPaneRegistry()
        var seen: [Bool] = []
        let subscription = registry.sessionPaneScrollbackActivePublisher
            .sink { seen.append($0) }
        defer { subscription.cancel() }

        registry.setSessionPaneScrollbackActive(true)
        registry.setSessionPaneScrollbackActive(true)
        registry.setSessionPaneScrollbackActive(false)

        XCTAssertEqual(
            seen, [false, true, false],
            "the initial value, then one emission per actual change — a no-op "
                + "write reaches every observer of the conforming object"
        )
    }

    func testTheScrollbackFlagReadsBackWhatWasSet() {
        let registry = StubPaneRegistry()

        registry.setSessionPaneScrollbackActive(true)

        XCTAssertTrue(registry.sessionPaneScrollbackActive)
    }

    // MARK: - Focus restoration

    func testThePreferredPaneIsRestoredWhenItIsRegistered() {
        let registry = StubPaneRegistry()
        let session = NSObject()
        let shell = NSObject()
        registry.registerPane(session, kind: .session)
        registry.registerPane(shell, kind: .shell)
        registry.lastFocusedPaneKind = .shell

        registry.restorePreferredPaneFocus()

        XCTAssertEqual(registry.restored, [.shell])
    }

    /// The fallback that must not read whatever the storage yields first.
    func testAnAbsentPreferredPaneFallsBackToTheSessionPane() {
        let registry = StubPaneRegistry()
        let session = NSObject()
        registry.registerPane(session, kind: .session)
        registry.lastFocusedPaneKind = .shell

        registry.restorePreferredPaneFocus()

        XCTAssertEqual(
            registry.restored, [.session],
            "the pane that always exists is the named fallback"
        )
    }

    /// The last resort finds the remaining pane — which is all this can check.
    ///
    /// It does **not** verify that the fallback is *ordered*, and cannot: with
    /// two pane kinds, reaching the last resort means the preferred kind and the
    /// session pane are both absent, so exactly one registrant is left and
    /// "named kind" and "whatever the storage yields first" agree by
    /// construction. Confirmed by mutation — replacing the named branch with
    /// `focusRestorers.values.first` leaves this passing.
    ///
    /// The ordering requirement in the protocol is therefore insurance against a
    /// third pane kind rather than something under test today. A third kind
    /// makes it falsifiable, and this is the test that should grow when one
    /// arrives.
    func testTheLastResortFindsTheOnlyRemainingPane() {
        let registry = StubPaneRegistry()
        let shell = NSObject()
        registry.registerPane(shell, kind: .shell)
        registry.lastFocusedPaneKind = .session

        registry.restorePreferredPaneFocus()

        XCTAssertEqual(registry.restored, [.shell])
    }

    func testRestoringWithNothingRegisteredIsANoOp() {
        let registry = StubPaneRegistry()

        registry.restorePreferredPaneFocus()
        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(registry.restored, [])
    }

    func testRestoringByKindTargetsThatKind() {
        let registry = StubPaneRegistry()
        let session = NSObject()
        let shell = NSObject()
        registry.registerPane(session, kind: .session)
        registry.registerPane(shell, kind: .shell)
        registry.lastFocusedPaneKind = .session

        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(
            registry.restored, [.shell],
            "an explicit kind ignores the focus memory"
        )
    }

    func testAWithdrawnRestorerIsNotInvoked() {
        let registry = StubPaneRegistry()
        let pane = NSObject()
        registry.registerPane(pane, kind: .shell)
        registry.unregisterFocusRestorer(ObjectIdentifier(pane))

        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(
            registry.restored, [],
            "a stale entry restores focus into a pane that is gone"
        )
    }

    /// A host that appears, goes away and appears again must not accumulate.
    func testRegisteringTwiceUnderOneKeyReplaces() {
        let registry = StubPaneRegistry()
        let pane = NSObject()
        var firstRan = false
        var secondRan = false
        registry.registerFocusRestorer(
            ObjectIdentifier(pane), kind: .shell
        ) { firstRan = true }
        registry.registerFocusRestorer(
            ObjectIdentifier(pane), kind: .shell
        ) { secondRan = true }

        registry.restoreFocus(kind: .shell)

        XCTAssertFalse(firstRan, "the replaced entry must not survive")
        XCTAssertTrue(secondRan)
    }

    // MARK: - Addressability

    /// The constraint that makes a shared consumer safe in an app holding one
    /// registry per session: two registries answer independently, so a consumer
    /// handed the wrong one is wrong in a way a test can see.
    func testTwoRegistriesDoNotShareState() {
        let first = StubPaneRegistry()
        let second = StubPaneRegistry()
        let pane = NSObject()
        first.registerPane(pane, kind: .shell)
        first.lastFocusedPaneKind = .shell
        first.setSessionPaneScrollbackActive(true)

        XCTAssertEqual(second.lastFocusedPaneKind, .session)
        XCTAssertFalse(second.sessionPaneScrollbackActive)

        second.restoreFocus(kind: .shell)
        XCTAssertEqual(
            second.restored, [],
            "a consumer fetching a registry from a static would pass this "
                + "wrongly in an app that keeps one per session"
        )
    }
}
