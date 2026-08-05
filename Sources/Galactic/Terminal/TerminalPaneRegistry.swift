import Combine

/// The panes of one terminal tab, addressable as a unit.
///
/// A terminal tab holds more than one pane, and three things about them are
/// nobody's individually: which pane the user was last in, whether one pane's
/// scrollback is blocking an action in another, and which panes are holding
/// unsaved work when something wants to close them. Each pane knows its own
/// answer; none can answer for the tab.
///
/// So the panes register what they can answer, and this registry fans the
/// question out. Hosts register on appearing and unregister on going away,
/// which means the set of registrants is the set of panes actually on screen —
/// the registry never has to be told a pane was destroyed.
///
/// It exists as a protocol so a terminal host can be written once, against
/// this, instead of once per app against each app's own session type. That is
/// the name a shared host cannot otherwise avoid, and removing it is what makes
/// the host movable at all.
///
/// ### Never reach for a shared instance
///
/// A conforming app may keep exactly one of these, or one per session. A
/// consumer that fetches the registry from a static works in the first case and
/// silently answers about the wrong session in the second — the failure being a
/// quit sheet that names panes belonging to a session other than the one
/// closing. Consumers are therefore **handed** their registry, resolved through
/// the pane they are serving, and never look it up.
///
/// `AnyObject` because registration is identity-keyed: a registrant hands over
/// an `ObjectIdentifier` of itself and withdraws with the same one, so the
/// registry holds a key it can compare without holding the object it names. A
/// registry must not retain its registrants — a pane that cannot be
/// deinitialised cannot unregister, and the entry then outlives the pane it
/// describes.
///
/// ### Threading
///
/// Main-thread only, by expectation rather than by annotation, and completions
/// are delivered on main.
///
/// Mostly not `@MainActor`: no conformer synchronises its storage today and
/// every caller is already on main, so a blanket annotation would fix no defect
/// while forcing `await` on every call site. Recorded here so a later reader can
/// tell this was decided rather than overlooked — if a caller ever does arrive
/// off main, the annotation is the fix, not a lock.
///
/// The two focus-restoring members are the exception and *are* annotated,
/// because putting the caret in a pane means first taking the keyboard back
/// from the find bar, whose panel is main-actor isolated. There the annotation
/// carries a real requirement rather than restating a convention — the same
/// distinction `TerminalFocus` draws between `request` and `resignIfHeld`. It
/// cost no call site an `await`: everything that asks for pane focus is a menu
/// action or a SwiftUI event handler, already isolated.
public protocol TerminalPaneRegistry: AnyObject {

    // MARK: - Focus memory

    /// The kind of pane the user was most recently focused in.
    ///
    /// Read to decide which pane a tab-level gesture belongs to when more than
    /// one could claim it — restoring focus on returning to the tab, and
    /// electing which pane answers a find. Written by whichever host observes
    /// itself taking focus.
    ///
    /// Plain and settable rather than a publisher, because nothing routes on
    /// changes to it — every consumer reads it at the moment it needs to decide
    /// something. A conformer that wants to publish anyway may, since a
    /// published property satisfies this; but writers should guard on
    /// inequality before assigning. The write is typically driven by
    /// first-responder observation, which fires on every responder change in
    /// the window rather than only on pane switches, so an unguarded assignment
    /// turns a quiet signal into a continuous one.
    var lastFocusedPaneKind: TerminalPaneKind { get set }

    /// Register `restore` as the way to put focus back into a pane of `kind`.
    ///
    /// `key` identifies the registrant so it can withdraw later, and should be
    /// `ObjectIdentifier(self)` from whatever host is registering. Registering
    /// twice under the same key replaces the entry rather than accumulating,
    /// which is what makes a host's re-appearance idempotent.
    func registerFocusRestorer(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        restore: @escaping () -> Void
    )

    /// Withdraw a previously registered restorer. Call from the registrant's
    /// `deinit`; a stale entry restores focus into a pane that is gone.
    func unregisterFocusRestorer(_ key: ObjectIdentifier)

    /// Put focus into whichever pane the user was last in.
    ///
    /// Falls back when that pane is not registered — the preferred kind may
    /// name a pane that has since closed, and a tab returning to focus still
    /// has to land the caret somewhere.
    ///
    /// **The fallback order must be deterministic and named.** Reaching for
    /// "any registered restorer" reads an unordered collection, so which pane
    /// receives focus becomes a function of hash order: stable enough to look
    /// correct while being developed, and free to differ per launch. Prefer the
    /// kind that always exists, then name the remainder explicitly.
    ///
    /// Unlike `restoreFocus`, this leaves the find bar alone — see the note
    /// there. Putting the caret back where it already was is not a request to
    /// type somewhere new, and a tab returning to the front runs through here,
    /// where the bar is expected to restore rather than to be stood down.
    func restorePreferredPaneFocus()

    /// Put focus into the registered pane of exactly `kind`, if there is one.
    ///
    /// One method taking the kind rather than one method per kind: every call
    /// site knows statically which pane it means, so the kind is an argument
    /// they already hold, and a third pane kind would otherwise mean a third
    /// method on this protocol and both conformers.
    ///
    /// Surrenders the find bar before restoring, because naming a pane is the
    /// user asking to type in it. The bar holds the keyboard from its own panel,
    /// so a responder set in the parent window while it is up succeeds and still
    /// leaves the caret in the find field — a command that reports success and
    /// does nothing.
    ///
    /// Main-actor isolated where the rest of this protocol is not, and for the
    /// same reason `TerminalFocus.resignIfHeld` is: the panel it stands down is
    /// itself main-actor isolated, so the requirement is the type system's
    /// rather than a comment's.
    @MainActor
    func restoreFocus(kind: TerminalPaneKind)

    // MARK: - Scrollback state

    /// Which panes currently have a scrollback overlay open.
    ///
    /// Here rather than on either pane because the pane that answers is often
    /// not the pane that asks, and because it has to survive a pane being torn
    /// down and rebuilt.
    ///
    /// Per-kind because two different questions are asked of it. One is
    /// cross-pane — may a shell send into the agent — and cares only about the
    /// session pane. The other is about the surface the user is reading, and
    /// cares about whichever pane that is. A single session-pane flag answered
    /// the first and was quietly wrong for the second.
    var scrollbackOpenKinds: Set<TerminalPaneKind> { get }

    /// Whether the session pane currently has a scrollback overlay open.
    ///
    /// The narrow cross-pane question, kept as its own member because that is
    /// what the consumer actually asks and a caller should not have to know
    /// which kind stands for "the agent". Derivable from
    /// `scrollbackOpenKinds`, and a conformer should derive it rather than
    /// store it twice.
    var sessionPaneScrollbackActive: Bool { get }

    /// Emits when `sessionPaneScrollbackActive` changes.
    ///
    /// Separate from the property because the consumer is a pane that has to
    /// re-evaluate a button's enablement, and polling would mean re-evaluating
    /// on every draw. Conformers holding the flag as a published property
    /// satisfy this by erasing its projected value.
    var sessionPaneScrollbackActivePublisher: AnyPublisher<Bool, Never> { get }

    /// Set whether the scrollback of a pane of `kind` is open.
    ///
    /// **Assign only on an actual change.** Conformers publish this, and it is
    /// written on every overlay open and close from more than one site, so an
    /// unguarded assignment sends a no-op change to every observer of the
    /// conforming object — which, for a conformer that is also the app's
    /// session model, is considerably more than the subscribers this has.
    ///
    /// A method rather than a settable property so the guard lives in one place
    /// and the stored state can stay read-only to the outside.
    ///
    /// Every pane reports, not only the agent's. The gate that used to sit at
    /// the call sites — write this only from the session pane — was correct for
    /// the one consumer that existed and became a silent wrong answer for the
    /// second. A pane saying what it is doing is not the place to encode which
    /// callers care.
    ///
    /// **Where it is reset on teardown is deliberately unspecified.** A registry
    /// that outlives its host has to clear the flag when the process exits,
    /// while one owned by its host clears it as the host goes away. Mandating
    /// either double-resets the first or strands the second — and a stranded
    /// flag leaves the other pane's action disabled permanently, with nothing
    /// on screen explaining why.
    func setScrollbackOpen(_ open: Bool, kind: TerminalPaneKind)

    // MARK: - Unsaved work

    /// Register `checker` as the way to ask a pane of `kind` whether it is
    /// holding unsaved work.
    ///
    /// The checker is asynchronous — it takes a completion rather than
    /// returning — because the pane it speaks for may have to ask a web view,
    /// and an answer that had to be synchronous would have to be a guess.
    ///
    /// Same key discipline as `registerFocusRestorer`: `ObjectIdentifier(self)`
    /// in, the same value out, replace rather than accumulate.
    func registerUnsavedWorkChecker(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        checker: @escaping (@escaping (Bool) -> Void) -> Void
    )

    /// Withdraw a previously registered checker. Call from the registrant's
    /// `deinit`; a stale entry reports unsaved work in a pane that has already
    /// gone, which blocks a quit that should have been allowed.
    func unregisterUnsavedWorkChecker(_ key: ObjectIdentifier)

    /// Ask every registered pane whose kind is in `kinds` whether it holds
    /// unsaved work, and complete with the kinds that said yes.
    ///
    /// Answers *which* panes rather than *whether any* pane, because the
    /// caller's next move is usually to name them in a confirmation — and a
    /// caller holding only a boolean cannot recover the names, while one
    /// holding the set reduces to the boolean with `isEmpty`. The reverse
    /// conversion is the one that is impossible, so the richer answer is the
    /// one to carry.
    ///
    /// The set is unordered; a caller presenting the names should impose its
    /// own order rather than enumerate what it receives.
    ///
    /// `kinds` is the caller's to supply, and this registry deliberately has no
    /// opinion on it. Which panes are worth asking depends on session lifecycle
    /// — a stopped session's own pane is gone while its shell pane may still
    /// hold notes — and that is knowledge the registry does not have and should
    /// not acquire.
    ///
    /// ### The completion must always be asynchronous
    ///
    /// Including, and especially, when no checker matches and the answer is
    /// already known.
    ///
    /// A quit is the caller that makes this a requirement: it answers AppKit
    /// with `terminateLater` and *then* replies from this completion. Completing
    /// inline replies before that return, out of the order AppKit documents.
    ///
    /// Completing inline only on the empty path is the worse version of the
    /// same bug, and the one to watch for, because it gives one method two
    /// reentrancy semantics chosen by whether anything happens to be registered
    /// — correct through every test where a pane exists, wrong on the launch
    /// where none does yet.
    func checkUnsavedWork(
        kinds: Set<TerminalPaneKind>,
        completion: @escaping (Set<TerminalPaneKind>) -> Void
    )
}
