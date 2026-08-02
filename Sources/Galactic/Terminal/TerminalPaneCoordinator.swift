import Combine
import Foundation

/// The panes of one terminal tab, addressable as a unit — the implementation
/// of `TerminalPaneRegistry` both applications use.
///
/// **Ownership is the app's; the mechanism is not.** One application keeps one
/// of these per session, because its quit sheet names *sessions* holding
/// unsaved work and a single app-wide answer cannot say which session a note
/// belongs to. The other keeps exactly one, because it embeds exactly one
/// session and the per-session dimension collapses. That difference is real and
/// it stays with the applications; everything below it — the registries, the
/// fallback order, the debounce on the cross-pane flag, the fan-out — was
/// written twice and identically, which is what this file ends.
///
/// Deliberately **not** an `ObservableObject`. The one piece of state anything
/// observes exposes a publisher explicitly. Conforming would mean every write
/// to the focus memory — driven by first-responder observation, so firing on
/// every responder change in the window — invalidated every view holding this
/// object. One application had that behaviour when these registries lived on
/// its session model, for no subscriber at all.
///
/// A registrant is held by `ObjectIdentifier` and never retained: a pane that
/// cannot be deinitialised cannot unregister, and its entry would then outlive
/// the pane it describes.
///
/// Main-thread only, by expectation rather than annotation — see
/// `TerminalPaneRegistry` for why that is a decision rather than an oversight.
public final class TerminalPaneCoordinator: TerminalPaneRegistry {

    public init() {}

    // MARK: - Focus memory

    /// Which pane was most recently the first responder, so tab-switch,
    /// session-switch and window-becomes-key restoration land the user back on
    /// whichever pane they were last typing in.
    ///
    /// Plain rather than published: nothing routes on changes to it — every
    /// consumer reads it at the moment it has a decision to make.
    public var lastFocusedPaneKind: TerminalPaneKind = .session

    /// Per-host restoration closures, keyed by the registering host's identity
    /// and tagged with the kind of pane each restores.
    ///
    /// This exists because SwiftUI hides an inactive tab by switching opacity,
    /// which never fires `updateNSView` — so AppKit quietly drops first
    /// responder and nothing puts it back. Restoring through the host rather
    /// than the backend also lets the host redirect focus into an open
    /// scrollback overlay instead of the live terminal hidden beneath it.
    private var focusRestorers: [
        ObjectIdentifier: (kind: TerminalPaneKind, restore: () -> Void)
    ] = [:]

    public func registerFocusRestorer(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        restore: @escaping () -> Void
    ) {
        focusRestorers[key] = (kind: kind, restore: restore)
    }

    public func unregisterFocusRestorer(_ key: ObjectIdentifier) {
        focusRestorers.removeValue(forKey: key)
    }

    /// Restore focus to the pane matching `lastFocusedPaneKind`, falling back
    /// when that pane is not registered — the user may remember being in a
    /// shell that has since closed.
    ///
    /// Every tier names its kind, so which pane wins never depends on the order
    /// the storage happens to yield. With two kinds an unordered read happens
    /// to give the same answer; it would stop doing so the moment a third
    /// exists, and the bug would look like a launch-to-launch flicker.
    public func restorePreferredPaneFocus() {
        if restoreIfRegistered(kind: lastFocusedPaneKind) { return }
        // The session pane wins the fallback: it is the one that always exists.
        if restoreIfRegistered(kind: .session) { return }
        _ = restoreIfRegistered(kind: .shell)
    }

    /// Restore focus to the pane of exactly `kind`, ignoring the focus memory.
    public func restoreFocus(kind: TerminalPaneKind) {
        _ = restoreIfRegistered(kind: kind)
    }

    /// Invoke the restorer for `kind`, reporting whether there was one.
    private func restoreIfRegistered(kind: TerminalPaneKind) -> Bool {
        guard
            let entry = focusRestorers.values.first(where: { $0.kind == kind })
        else { return false }
        entry.restore()
        return true
    }

    // MARK: - Cross-pane scrollback state

    /// True while the session pane's scrollback overlay is open.
    ///
    /// The shell pane's Send to Claude reads it: sending into the agent while
    /// its buffer is frozen open would land text the user cannot see arriving.
    /// Held here rather than on either pane so neither has to know the other
    /// exists, and so it survives a pane being torn down and rebuilt.
    @Published public private(set) var sessionPaneScrollbackActive = false

    public var sessionPaneScrollbackActivePublisher: AnyPublisher<Bool, Never> {
        $sessionPaneScrollbackActive.eraseToAnyPublisher()
    }

    /// Guarded on inequality: this is written on every overlay open and close
    /// from more than one site, and an unguarded assignment publishes a no-op
    /// change to every observer each time.
    public func setSessionPaneScrollbackActive(_ active: Bool) {
        guard sessionPaneScrollbackActive != active else { return }
        sessionPaneScrollbackActive = active
    }

    // MARK: - Unsaved work

    /// Per-host checks for unsaved scrollback work — committed notes not yet
    /// sent, an open note form with text, an edit in progress.
    ///
    /// Asynchronous because the answer lives in the scrollback overlay's web
    /// view and has to be fetched from JavaScript. Tagged by pane kind so a
    /// caller can ask about the panes whose loss actually matters to it.
    private var unsavedWorkCheckers: [
        ObjectIdentifier: (
            kind: TerminalPaneKind,
            check: (@escaping (Bool) -> Void) -> Void
        )
    ] = [:]

    public func registerUnsavedWorkChecker(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        checker: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        unsavedWorkCheckers[key] = (kind: kind, check: checker)
    }

    public func unregisterUnsavedWorkChecker(_ key: ObjectIdentifier) {
        unsavedWorkCheckers.removeValue(forKey: key)
    }

    /// Ask the panes matching `kinds` whether they hold unsaved work and report
    /// the subset that does, so a caller can name them. Checks run
    /// concurrently; the completion lands on main.
    ///
    /// Which kinds are worth asking about is the caller's to say: stopping a
    /// session only loses the session pane's notes because the shell process
    /// keeps running, while quitting loses both — and for an already-stopped
    /// session, only its shell pane can still be open.
    public func checkUnsavedWork(
        kinds: Set<TerminalPaneKind>,
        completion: @escaping (Set<TerminalPaneKind>) -> Void
    ) {
        let entries = unsavedWorkCheckers.values
            .filter { kinds.contains($0.kind) }

        guard !entries.isEmpty else {
            // Deliberately asynchronous even though the answer is already
            // known. Quit answers AppKit that it will terminate later and then
            // replies from a completion below this one; answering inline would
            // reply before that return, out of the order AppKit documents.
            // Every other path out of here lands on `group.notify`, and one
            // method with two reentrancy semantics — chosen by whether a pane
            // happens to be registered — is the harder bug to find.
            DispatchQueue.main.async { completion([]) }
            return
        }

        let group = DispatchGroup()
        var panesWithWork: Set<TerminalPaneKind> = []
        let lock = NSLock()

        for entry in entries {
            group.enter()
            entry.check { hasWork in
                if hasWork {
                    lock.lock()
                    panesWithWork.insert(entry.kind)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(panesWithWork)
        }
    }
}
