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
/// These run against `TerminalPaneCoordinator` — the implementation both
/// applications actually hold — rather than against a double written to agree
/// with the protocol. Until there was one shared implementation there was
/// nothing else to point them at; now that there is, a double passing these
/// would have proved only that the double was right.
/// Main-actor isolated because the focus-restoring members are: they surrender
/// the find bar before restoring, and the panel that holds it is isolated. The
/// unsaved-work cases here deliver their completions on main regardless, so the
/// annotation costs them nothing.
@MainActor
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
        let registry = TerminalPaneCoordinator()
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
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
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
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
        harness.registerPane(.shell, on: registry)
        harness.kindsWithWork = [.shell]
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
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
        harness.registerPane(.shell, on: registry)
        harness.kindsWithWork = [.session, .shell]
        var reported: Set<TerminalPaneKind>?

        registry.checkUnsavedWork(kinds: [.shell]) { reported = $0 }
        settle()

        XCTAssertEqual(
            reported, [.shell],
            "a stopped session's own pane is gone; only the caller knows that"
        )
    }

    func testAWithdrawnCheckerIsNotAsked() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        let pane = harness.registerPane(.shell, on: registry)
        harness.kindsWithWork = [.shell]
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
        let registry = TerminalPaneCoordinator()
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
        let registry = TerminalPaneCoordinator()

        registry.setSessionPaneScrollbackActive(true)

        XCTAssertTrue(registry.sessionPaneScrollbackActive)
    }

    // MARK: - Focus restoration

    func testThePreferredPaneIsRestoredWhenItIsRegistered() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
        harness.registerPane(.shell, on: registry)
        registry.lastFocusedPaneKind = .shell

        registry.restorePreferredPaneFocus()

        XCTAssertEqual(harness.restored, [.shell])
    }

    /// The fallback that must not read whatever the storage yields first.
    func testAnAbsentPreferredPaneFallsBackToTheSessionPane() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
        registry.lastFocusedPaneKind = .shell

        registry.restorePreferredPaneFocus()

        XCTAssertEqual(
            harness.restored, [.session],
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
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.shell, on: registry)
        registry.lastFocusedPaneKind = .session

        registry.restorePreferredPaneFocus()

        XCTAssertEqual(harness.restored, [.shell])
    }

    func testRestoringWithNothingRegisteredIsANoOp() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()

        registry.restorePreferredPaneFocus()
        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(harness.restored, [])
    }

    /// Restoring focus surrenders the find bar first, and with no bar up that
    /// has to cost nothing.
    ///
    /// Whether the surrender actually moves the keyboard needs a key window and
    /// so is manual, but every restoration in the app takes this path and almost
    /// all of them take it with no bar presenting. The guard reporting false is
    /// what makes that case a no-op rather than a teardown of state it does not
    /// own — and it is why the restoration cases above still describe the
    /// behaviour they did before the surrender existed.
    func testSurrenderingWithNoFindBarUpIsInert() {
        XCTAssertFalse(
            FindBarPanelController.shared.surrenderForFocusChange(),
            "surrender reported standing a bar down when none was presenting"
        )

        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)

        registry.restoreFocus(kind: .session)

        XCTAssertEqual(
            harness.restored, [.session],
            "the surrender interfered with an ordinary focus restore"
        )
    }

    /// Naming a pane makes it the remembered one, immediately.
    ///
    /// Not bookkeeping: surrendering the find bar hands key back to the parent
    /// window, which wakes each host's became-key observer, and that observer
    /// re-asserts focus for whichever pane this memory names. Both it and the
    /// restore itself land a runloop hop later, so a stale memory lets the
    /// previous pane take the caret back after the requested one received it.
    func testRestoringByKindBecomesTheRememberedPane() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
        harness.registerPane(.shell, on: registry)
        registry.lastFocusedPaneKind = .session

        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(
            registry.lastFocusedPaneKind, .shell,
            "the pane the caller asked for did not become the remembered one"
        )
    }

    /// A kind with nothing registered moved no caret, so it may not claim the
    /// memory either — otherwise a command naming a closed pane would redirect
    /// the next window activation to a pane that is not there.
    func testRestoringAnAbsentKindLeavesTheMemoryAlone() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
        registry.lastFocusedPaneKind = .session

        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(
            registry.lastFocusedPaneKind, .session,
            "an unregistered kind overwrote the focus memory"
        )
        XCTAssertEqual(harness.restored, [])
    }

    func testRestoringByKindTargetsThatKind() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.session, on: registry)
        harness.registerPane(.shell, on: registry)
        registry.lastFocusedPaneKind = .session

        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(
            harness.restored, [.shell],
            "an explicit kind ignores the focus memory"
        )
    }

    func testAWithdrawnRestorerIsNotInvoked() {
        let registry = TerminalPaneCoordinator()
        let harness = PaneHarness()
        let pane = harness.registerPane(.shell, on: registry)
        registry.unregisterFocusRestorer(ObjectIdentifier(pane))

        registry.restoreFocus(kind: .shell)

        XCTAssertEqual(
            harness.restored, [],
            "a stale entry restores focus into a pane that is gone"
        )
    }

    /// A host that appears, goes away and appears again must not accumulate.
    func testRegisteringTwiceUnderOneKeyReplaces() {
        let registry = TerminalPaneCoordinator()
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
        let first = TerminalPaneCoordinator()
        let second = TerminalPaneCoordinator()
        let harness = PaneHarness()
        harness.registerPane(.shell, on: first)
        first.lastFocusedPaneKind = .shell
        first.setSessionPaneScrollbackActive(true)

        XCTAssertEqual(second.lastFocusedPaneKind, .session)
        XCTAssertFalse(second.sessionPaneScrollbackActive)

        second.restoreFocus(kind: .shell)
        XCTAssertEqual(
            harness.restored, [],
            "a consumer fetching a registry from a static would pass this "
                + "wrongly in an app that keeps one per session"
        )
    }
}

/// Drives a registry the way panes do, and records what came back.
///
/// The two conveniences the old test double provided — registering on behalf of
/// a pane, and remembering which restorers fired — live here instead, so the
/// subject of these tests can be the shipped implementation. Panes are retained
/// because a registration is keyed by object identity, and a deallocated pane
/// would free an address a later one could reuse.
private final class PaneHarness {
    private(set) var restored: [TerminalPaneKind] = []
    var kindsWithWork: Set<TerminalPaneKind> = []
    private var panes: [NSObject] = []

    /// Register a pane of `kind` for both focus restoration and unsaved-work
    /// reporting, as a real host does. Returns the object it registered under
    /// so a test can withdraw that registration.
    @discardableResult
    func registerPane(
        _ kind: TerminalPaneKind, on registry: TerminalPaneRegistry
    ) -> NSObject {
        let pane = NSObject()
        panes.append(pane)
        let key = ObjectIdentifier(pane)
        registry.registerFocusRestorer(key, kind: kind) { [weak self] in
            self?.restored.append(kind)
        }
        registry.registerUnsavedWorkChecker(key, kind: kind) {
            [weak self] answer in
            answer(self?.kindsWithWork.contains(kind) ?? false)
        }
        return pane
    }
}
