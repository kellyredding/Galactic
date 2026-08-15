import AppKit
import Combine
import Foundation

/// Presentation state for the inbox modal: whether it is up, and whose queue it
/// is showing.
///
/// An in-window overlay mounted by the host, on the `CheatSheetPresenter`
/// pattern — a floating panel would reopen the key-window questions a host's own
/// panels already cost it, and this needs none of what a panel buys:
///
/// ```swift
/// @ObservedObject private var inboxModal = AgentInboxPresenter.shared
///
/// .overlay {
///     if inboxModal.isPresented { AgentInboxView().transition(.opacity) }
/// }
/// .animation(.easeInOut(duration: 0.12), value: inboxModal.isPresented)
/// ```
///
/// ### Where this parts company with the cheat sheet
///
/// The sheet takes a snapshot as it opens and holds it, because its own search
/// field steals first responder and a later read would report "the user is
/// typing" and dim every row. Nothing here is derived from focus, and the thing
/// being shown *moves on its own*: a queue drains at turn end whether or not
/// anyone is looking at it. So only the choice of queue is resolved at open
/// time. The queue's contents stay live, and a message leaving while the reader
/// watches is the modal doing its job rather than going stale.
@MainActor
public final class AgentInboxPresenter: ObservableObject {
    public static let shared = AgentInboxPresenter()

    @Published public private(set) var isPresented = false

    /// The queue on show. Nil when the host has no session to speak of, which
    /// the view states in words rather than rendering as an empty queue — "no
    /// agent running" and "nothing waiting" are different answers and a reader
    /// acts on them differently.
    @Published public private(set) var inbox: AgentInbox?

    /// Which queue to show, asked as the modal opens.
    ///
    /// A closure because the answer is live: a host running many sessions
    /// resolves the active one, and a host running one still has to say whether
    /// it exists yet. Threaded through here rather than through `present()` so
    /// the menu item and the keystroke do not each have to know about it.
    public var inboxProvider: () -> AgentInbox? = { nil }

    /// The consumer draining the queue on show, when there is one.
    ///
    /// Separate from `inbox` because they answer to different owners: the queue
    /// is a value the host stores, while the consumer is bound to a live agent
    /// and is the only object that knows both whether a unit is already out and
    /// whether the agent could read another. A row's Send Now needs all of
    /// that, and none of it is reachable from the queue alone.
    @Published public private(set) var consumer: AgentInboxConsumer?

    /// Which consumer to show, asked as the modal opens — the companion to
    /// `inboxProvider`, resolved at the same moment so the two cannot disagree
    /// about which session is on screen.
    public var consumerProvider: () -> AgentInboxConsumer? = { nil }

    /// Set while a confirmation sheet is up, to stand the Escape monitor down.
    ///
    /// An `NSAlert` run as a window-modal sheet still dispatches its key events
    /// through `NSApp`, so the monitor below sees the reader's Escape, treats it
    /// as "close the inbox", and tears the modal out from under the sheet that
    /// asked the question. Escape belongs to the sheet for as long as one is up,
    /// where it already means Cancel.
    var isConfirming = false

    /// Whether the modal is claiming the keyboard.
    ///
    /// Read as a stand-down gate by every other local key monitor that answers
    /// an unmodified key — same contract, and same hard-won reason, as
    /// `CheatSheetPresenter.isClaimingKeyboard`: AppKit does not contract the
    /// order local monitors run in, so "mine installed last" is not something
    /// to build on.
    public static var isClaimingKeyboard: Bool { shared.isPresented }

    /// Live only while the modal is up. Internal so a test can assert the
    /// monitor lasts exactly as long as the modal does.
    var escapeMonitor: Any?

    /// Who held the keyboard when the modal opened. Weak, both: this must never
    /// be the reason a window or a view outlives its host's intention.
    weak var priorWindow: NSWindow?
    weak var priorResponder: NSResponder?

    /// Internal, so this package's tests can exercise an instance without
    /// mutating the singleton every other test shares. Hosts use `shared`.
    init() {}

    public func toggle() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    /// Open on the host's current queue. A no-op when already open.
    ///
    /// Opening on an absent queue is supported and deliberate: a reader who
    /// asks what is waiting deserves an answer when the answer is "nothing, and
    /// there is no agent" — refusing to open would leave them guessing whether
    /// the keystroke worked.
    public func present() {
        guard !isPresented else { return }
        inbox = inboxProvider()
        consumer = consumerProvider()
        captureFocus()
        isPresented = true
        installEscapeMonitor()
    }

    public func dismiss() {
        isPresented = false
        removeEscapeMonitor()
    }

    private func captureFocus() {
        priorWindow = NSApp.keyWindow
        priorResponder = priorWindow?.firstResponder
    }

    /// Give the keyboard back to whoever had it when the modal opened.
    ///
    /// Called by `AgentInboxView` as it disappears, not by `dismiss`, for the
    /// reason spelled out on `CheatSheetPresenter.restoreFocus`: an overlay in
    /// the host's own view tree goes away when SwiftUI says so, and restoring
    /// before it has gone puts the caret back only for SwiftUI to clear it a
    /// pass later while tearing the overlay down.
    func restoreFocus() {
        let window = priorWindow
        let responder = priorResponder
        priorWindow = nil
        priorResponder = nil

        guard let window, let responder else { return }
        // A view that has left the window it was saved from must not be dragged
        // back into focus — the host is free to end a session or switch a tab
        // while the modal is up.
        if let view = responder as? NSView, view.window !== window { return }
        if !window.isKeyWindow { window.makeKey() }
        _ = window.makeFirstResponder(responder)
    }

    /// Escape closes the modal.
    ///
    /// A local monitor rather than `.onExitCommand`, because this floats over
    /// surfaces that claim Escape for themselves — a terminal pane swallows it
    /// outright — so a SwiftUI handler never sees the key.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self, self.isPresented, !self.isConfirming,
                event.keyCode == Keystroke.Key.esc
            else { return event }
            self.dismiss()
            return nil  // consumed: it must not also reach the terminal
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
