import Combine
import Foundation
@testable import Galactic

/// A `TerminalPaneRegistry` that honours the contract and records what was
/// asked of it.
///
/// Shared rather than nested, because it serves two purposes that must not
/// drift apart: it is the subject of the contract tests, and it is the registry
/// a shared terminal host is handed when that host is tested without an app
/// around it. If the two were separate doubles, the one the host is tested
/// against would be free to be more forgiving than the one the contract
/// describes.
///
/// Deliberately implemented the way the contract asks rather than the shortest
/// way — the always-asynchronous completion, the equality guard, and the named
/// fallback order are the parts a conformer is most likely to get wrong, so the
/// reference has to get them right to be worth comparing against.
final class StubPaneRegistry: TerminalPaneRegistry {

    // MARK: - Recording

    /// Kinds whose restorer was invoked, in order.
    var restored: [TerminalPaneKind] = []

    /// `kinds` arguments received by `checkUnsavedWork`, in order.
    var asked: [Set<TerminalPaneKind>] = []

    /// Kinds this stub should report as holding unsaved work.
    var kindsWithWork: Set<TerminalPaneKind> = []

    // MARK: - Focus memory

    var lastFocusedPaneKind: TerminalPaneKind = .session

    private var focusRestorers:
        [ObjectIdentifier: (kind: TerminalPaneKind, restore: () -> Void)] = [:]

    func registerFocusRestorer(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        restore: @escaping () -> Void
    ) {
        focusRestorers[key] = (kind: kind, restore: restore)
    }

    func unregisterFocusRestorer(_ key: ObjectIdentifier) {
        focusRestorers.removeValue(forKey: key)
    }

    func restorePreferredPaneFocus() {
        if invokeRestorer(kind: lastFocusedPaneKind) { return }
        // Named in order rather than "whatever is registered": the session pane
        // is the one that always exists, and naming the remainder keeps the
        // outcome independent of dictionary order.
        if invokeRestorer(kind: .session) { return }
        _ = invokeRestorer(kind: .shell)
    }

    func restoreFocus(kind: TerminalPaneKind) {
        _ = invokeRestorer(kind: kind)
    }

    /// Invoke the restorer for `kind`, reporting whether there was one.
    private func invokeRestorer(kind: TerminalPaneKind) -> Bool {
        guard
            let entry = focusRestorers.values.first(where: { $0.kind == kind })
        else { return false }
        restored.append(kind)
        entry.restore()
        return true
    }

    // MARK: - Scrollback state

    @Published private(set) var scrollbackOpenKinds: Set<TerminalPaneKind> = []

    /// Derived, exactly as the real coordinator derives it — a stub that stored
    /// it separately could pass while the two disagreed.
    var sessionPaneScrollbackActive: Bool {
        scrollbackOpenKinds.contains(.session)
    }

    var sessionPaneScrollbackActivePublisher: AnyPublisher<Bool, Never> {
        $scrollbackOpenKinds
            .map { $0.contains(.session) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func setScrollbackOpen(_ open: Bool, kind: TerminalPaneKind) {
        guard scrollbackOpenKinds.contains(kind) != open else { return }
        if open {
            scrollbackOpenKinds.insert(kind)
        } else {
            scrollbackOpenKinds.remove(kind)
        }
    }

    // MARK: - Unsaved work

    private var unsavedWorkCheckers: [
        ObjectIdentifier: (
            kind: TerminalPaneKind,
            check: (@escaping (Bool) -> Void) -> Void
        )
    ] = [:]

    func registerUnsavedWorkChecker(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        checker: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        unsavedWorkCheckers[key] = (kind: kind, check: checker)
    }

    func unregisterUnsavedWorkChecker(_ key: ObjectIdentifier) {
        unsavedWorkCheckers.removeValue(forKey: key)
    }

    func checkUnsavedWork(
        kinds: Set<TerminalPaneKind>,
        completion: @escaping (Set<TerminalPaneKind>) -> Void
    ) {
        asked.append(kinds)

        let entries = unsavedWorkCheckers
            .values
            .filter { kinds.contains($0.kind) }

        guard !entries.isEmpty else {
            // Asynchronous even though the answer is already known — see the
            // protocol. Replying inline here is the failure that survives every
            // test where a pane happens to be registered.
            DispatchQueue.main.async { completion([]) }
            return
        }

        let group = DispatchGroup()
        var withWork: Set<TerminalPaneKind> = []
        let lock = NSLock()

        for entry in entries {
            group.enter()
            entry.check { hasWork in
                if hasWork {
                    lock.lock()
                    withWork.insert(entry.kind)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { completion(withWork) }
    }

    // MARK: - Convenience

    /// Register a checker reporting from `kindsWithWork`, as a pane would.
    func registerPane(_ owner: AnyObject, kind: TerminalPaneKind) {
        registerUnsavedWorkChecker(
            ObjectIdentifier(owner),
            kind: kind
        ) { [weak self] completion in
            completion(self?.kindsWithWork.contains(kind) ?? false)
        }
        registerFocusRestorer(ObjectIdentifier(owner), kind: kind) {}
    }
}
