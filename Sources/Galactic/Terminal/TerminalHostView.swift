import AppKit
import Combine
import SwiftUI

/// SwiftUI wrapper that mounts a terminal pane's NSView.
///
/// Accepts any `TerminalPane` conformer, so a session pane and a shell pane
/// share one SwiftUI→AppKit bridge without branching. The host owns the
/// scrollback overlay's lifecycle, so it takes the whole pane rather than just
/// its view.
///
/// Everything an application has to decide arrives here as a value. Nothing is
/// reached for, and nothing is left out: an application that does not want a
/// behaviour supplies `nil` or `false` and the wiring stays present, so
/// adopting it later is a value change rather than an integration.
public struct FocusableTerminalView: NSViewRepresentable, Equatable {

    /// The pane whose surface this hosts.
    public let pane: TerminalPane

    /// Where the host's terminal events are recorded, or nil to record
    /// nothing.
    ///
    /// Supplied by the application rather than reached for, so the host
    /// describes what happened without knowing what stores it — and so an
    /// application with nothing to store into supplies nil and the describing
    /// stays put.
    public let timelineRecorder: TerminalTimelineRecorder?

    /// Where the host reads configuration, and hears that it changed.
    ///
    /// Supplied for the same reason as the recorder: a settings store is one of
    /// the names shared code cannot carry, and a behaviour an application turns
    /// off is a value read through here rather than code that is absent.
    public let settings: GalacticConfigurationSource

    /// Told each time the user asks to find within this surface.
    public let findActivations: FindActivations

    /// Told each time the user asks to open a scrollback over this surface.
    public let scrollbackActivations: ScrollbackActivations

    /// How an interrupted turn gets recorded, or nil for a surface where turns
    /// do not happen — a shell pane beside an agent being exactly that.
    public let turnInterrupt: TurnInterrupt?

    /// The registry this pane's host coordinates through, or nil for a pane
    /// with no session behind it.
    public let paneRegistry: (any TerminalPaneRegistry)?

    /// Told when whatever is behind this surface has ended, so anything left
    /// open over it can be closed. `.never` for a surface nothing ends.
    public let surfaceEndings: SurfaceEndings

    /// Told when something that could block sending has changed.
    public let sendBlockerChanges: SendBlockerChanges

    /// Whether this pane belongs to the session the user selected.
    ///
    /// Drives hiding and drag registration — the questions that really are
    /// about which session owns the pane. An application hosting one session
    /// answers `true` always, and both behaviours fall out inert.
    public let isActiveSession: Bool

    /// Whether this pane is the surface the user is actually looking at: the
    /// selected session *and* the terminal tab. Drives focus, scrollback entry
    /// and find.
    ///
    /// Separate from `isActiveSession` because a terminal tab can stay mounted
    /// while another tab shows — switched by opacity rather than torn down. A
    /// pane reading only the session believes it is in front of the user while
    /// a reader is showing, and takes the caret back from whatever the user was
    /// typing in.
    public let isVisibleSurface: Bool

    /// Whether this host should give up first responder now.
    ///
    /// The two applications reach this moment from different facts and must
    /// keep doing so. One hides a pane whose session is not selected, so for it
    /// the moment is the session being deselected. The other never hides
    /// anything, so for it the moment is the terminal tab ceasing to show. Same
    /// answer to the same question, arrived at differently — which is why the
    /// application states it rather than the host inferring it from the two
    /// flags above and being wrong for one of them.
    public let shouldResignFocus: Bool

    public init(
        pane: TerminalPane,
        timelineRecorder: TerminalTimelineRecorder?,
        settings: GalacticConfigurationSource,
        findActivations: FindActivations,
        scrollbackActivations: ScrollbackActivations,
        turnInterrupt: TurnInterrupt?,
        paneRegistry: (any TerminalPaneRegistry)?,
        surfaceEndings: SurfaceEndings,
        sendBlockerChanges: SendBlockerChanges,
        isActiveSession: Bool,
        isVisibleSurface: Bool,
        shouldResignFocus: Bool
    ) {
        self.pane = pane
        self.timelineRecorder = timelineRecorder
        self.settings = settings
        self.findActivations = findActivations
        self.scrollbackActivations = scrollbackActivations
        self.turnInterrupt = turnInterrupt
        self.paneRegistry = paneRegistry
        self.surfaceEndings = surfaceEndings
        self.sendBlockerChanges = sendBlockerChanges
        self.isActiveSession = isActiveSession
        self.isVisibleSurface = isVisibleSurface
        self.shouldResignFocus = shouldResignFocus
    }

    public func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(
            pane: pane,
            timelineRecorder: timelineRecorder,
            settings: settings,
            findActivations: findActivations,
            scrollbackActivations: scrollbackActivations,
            turnInterrupt: turnInterrupt,
            paneRegistry: paneRegistry,
            surfaceEndings: surfaceEndings,
            sendBlockerChanges: sendBlockerChanges
        )
    }

    public func updateNSView(_ nsView: TerminalHostView, context: Context) {
        let wasVisible = nsView.isVisibleSurface
        let sessionChanged = nsView.isActiveSession != isActiveSession

        // Setting the session flag refreshes drag registration when it flips,
        // so only refresh explicitly when it did not — the case where the
        // pane's own accepting-input state may have changed instead. Avoids
        // paying for two register/unregister cycles per transition.
        nsView.isActiveSession = isActiveSession
        nsView.isVisibleSurface = isVisibleSurface
        if !sessionChanged {
            nsView.refreshDragRegistration()
        }

        if shouldResignFocus {
            nsView.resignFocusIfHeld()
        }

        // Skip the write when the value already matches — NSView.setHidden does
        // KVO and layer-dirty work even on no-op assignments, and after
        // SwiftUI's per-row short-circuit only the transition rows need it. An
        // application that hosts one session never hides anything, because the
        // flag it computes this from is always true.
        let shouldHide = !isActiveSession
        if nsView.isHidden != shouldHide {
            nsView.isHidden = shouldHide
        }

        // Take focus only on the transition into visible, never on every
        // re-render. An unconditional grab steals first responder from whatever
        // the user is actually typing in, and with two panes both hosts would
        // race — the loser overwriting the focus memory that decides where
        // focus belongs. The preference gate settles it.
        if isVisibleSurface && !wasVisible {
            nsView.requestFocusIfPreferred()
        }
    }

    /// Identity equality over the whole of this view's input, so `.equatable()`
    /// at a call site lets SwiftUI skip `updateNSView` — and with it a focus
    /// re-assert and a drag re-registration — on renders where nothing changed.
    ///
    /// Compared by reference rather than left to SwiftUI's memberwise diff,
    /// which is not guaranteed to compare a protocol-typed property by
    /// reference. A pane's reference flips exactly when a stop-and-resume
    /// builds a new backend behind it, which is when an update is wanted.
    public static func == (
        lhs: FocusableTerminalView,
        rhs: FocusableTerminalView
    ) -> Bool {
        lhs.pane === rhs.pane
            && lhs.paneRegistry === rhs.paneRegistry
            && lhs.isActiveSession == rhs.isActiveSession
            && lhs.isVisibleSurface == rhs.isVisibleSurface
            && lhs.shouldResignFocus == rhs.shouldResignFocus
    }
}

/// Host view that holds a terminal surface, paints the inset strip around it,
/// forwards focus to the terminal, answers file drops, and owns the scrollback
/// overlay's lifecycle.
///
/// The pane abstracts the engine underneath, so this never has to know which
/// one is rendering; every application-owned answer arrives as a value at
/// `init`, so this never has to know which application it is running in.
public final class TerminalHostView: NSView {

    /// Readable from outside so a ⌘W interceptor walking up from the first
    /// responder can ask which kind of pane a host is showing.
    public let pane: TerminalPane

    /// The pane registry this host coordinates through.
    ///
    /// Handed in rather than resolved through the pane: the answers it holds
    /// belong to one session, and one application keeps a registry per session
    /// where a static would answer about whichever was asked about last.
    /// Optional because a pane can exist with no session behind it, which is
    /// the same window in which none of these answers exist either.
    private let paneRegistry: (any TerminalPaneRegistry)?

    /// Where this host's terminal events go, or nil to record nothing.
    private let timelineRecorder: TerminalTimelineRecorder?

    /// Where this host reads configuration, and hears that it changed.
    private let settings: GalacticConfigurationSource

    /// Told each time the user asks to find within this surface.
    private let findActivations: FindActivations

    /// Told each time the user asks to open a scrollback over this surface.
    private let scrollbackActivations: ScrollbackActivations

    /// How an interrupted turn gets recorded, or nil where turns do not happen.
    private let turnInterrupt: TurnInterrupt?

    /// Told when whatever was behind this surface has ended.
    private let surfaceEndings: SurfaceEndings

    /// Told when something that could block sending has changed.
    private let sendBlockerChanges: SendBlockerChanges

    /// Which pane this host is showing, as the pane itself reports it.
    private var paneKind: TerminalPaneKind { pane.paneKind }

    /// Is this pane's session the selected one? Controls drag registration and
    /// hiding.
    var isActiveSession: Bool = false {
        didSet {
            guard isActiveSession != oldValue else { return }
            refreshDragRegistration()
        }
    }

    /// Is this pane the surface in front of the user — selected session and
    /// terminal tab both? Supplied by the representable; see its declaration
    /// for why this is not the same question as `isActiveSession`.
    var isVisibleSurface: Bool = false {
        didSet {
            guard oldValue != isVisibleSurface else { return }
            // An open overlay holds the shared find panel only while its
            // surface is the one in front of the user, and it is an NSView deep
            // in the hierarchy with no way to learn that it no longer is. The
            // host is the only thing that knows, and this is the moment it
            // finds out. Left unsaid, the panel stays up over whatever the user
            // moved to, bound to a surface that is no longer showing.
            scrollbackOverlay?.refreshFindBarPanelPresentation()
        }
    }

    private var didSetUp = false

    /// Uniform inset between the host's bounds and the inner terminal view,
    /// scrollback overlay and drag highlight. The host's layer is painted in
    /// the current theme colour so the strip reads as part of the pane rather
    /// than as chrome around it.
    private static let terminalPadding: CGFloat = 4

    /// Alpha applied to the pane's view when focus sits outside it. Tuned so an
    /// unfocused pane reads as clearly inactive without making its text hard to
    /// scan at a glance.
    private static let unfocusedPaneAlpha: CGFloat = 0.70

    /// How long to let the responder chain settle before the first focus
    /// request. The view has just been put in a window, sibling panes may be
    /// mounting in the same turn, and a restored session can be rebuilding
    /// several at once — asking too early lands the caret nowhere.
    private static let initialFocusDelay: TimeInterval = 0.2

    /// Container that hosts the live terminal full-bleed inside a
    /// `terminalPadding` inset. SwiftTerm clips its leftmost column whenever
    /// the terminal view's own frame origin is offset from (0,0) of its
    /// superview, so the inset lives on the container, never on the terminal.
    private var terminalContainer: GalacticTerminalContainerView?

    /// Drop-zone highlight, drawn above the terminal surface and shown while a
    /// file drag hovers.
    private var dragHighlightView: DragHighlightView?

    /// Whether a file drag is currently hovering — drives the highlight.
    private var isReceivingDrag = false {
        didSet { dragHighlightView?.isHighlighted = isReceivingDrag }
    }

    /// Local key monitor translating Ctrl+←/→ into line-navigation controls,
    /// and noticing Esc pressed during a turn.
    private var keyEventMonitor: Any?

    // MARK: - Scrollback state

    /// Why a scrollback surface closed, as its exit event reports it.
    private enum ScrollbackExitReason: String {
        case dismissed
        case reviewed
        case sessionEnded = "session-ended"
        case appQuit = "app-quit"
    }

    /// The live scrollback overlay, or nil when not in scrollback mode.
    private var scrollbackOverlay: ScrollbackOverlayView?

    /// True while the scrollback overlay is up.
    var isScrollbackActive: Bool { scrollbackOverlay != nil }

    /// Pairs the entered and exited events for one visit, so a reader can time
    /// the span. Generated on open, consumed on teardown.
    private var scrollbackDurationId: String?

    /// The frozen buffer behind an open overlay, held so a theme or font change
    /// can render it again rather than re-capturing — re-capturing would swap
    /// what the reader is looking at for whatever the live terminal has since
    /// become. Released on teardown.
    private var currentSnapshot: ScrollbackSnapshot?

    /// One-shot: set when ⌘F is what opened the scrollback, consumed by
    /// `onReady` so the bar appears once the page has actually painted.
    private var pendingFindActivation = false

    /// Whether a scroll-up opens the scrollback overlay, and the post-dismiss
    /// cooldown that stops the tail of the dismissing gesture from re-opening
    /// it. Both answers come from configuration, so the whole behaviour is one
    /// value away from off.
    private let scrollEntry = ScrollToEnterScrollback()

    /// Subscriptions whose lifetime is this host's.
    private var cancellables = Set<AnyCancellable>()

    /// Subscriptions live only while an overlay is open, driving the Send
    /// button's enabled state. Cleared on teardown so nothing keeps firing at a
    /// button that is gone.
    private var sendButtonStateCancellables = Set<AnyCancellable>()

    /// KVO on `window.firstResponder`, driving the focus dim and the record of
    /// which pane the user was last in. Its lifetime is this view's, not the
    /// scrollback's, because the dim applies whether or not one is open. Bound
    /// in `viewDidMoveToWindow`, invalidated in `deinit`.
    private var firstResponderObservation: NSKeyValueObservation?

    init(
        pane: TerminalPane,
        timelineRecorder: TerminalTimelineRecorder?,
        settings: GalacticConfigurationSource,
        findActivations: FindActivations,
        scrollbackActivations: ScrollbackActivations,
        turnInterrupt: TurnInterrupt?,
        paneRegistry: (any TerminalPaneRegistry)?,
        surfaceEndings: SurfaceEndings,
        sendBlockerChanges: SendBlockerChanges
    ) {
        self.pane = pane
        self.timelineRecorder = timelineRecorder
        self.settings = settings
        self.findActivations = findActivations
        self.scrollbackActivations = scrollbackActivations
        self.turnInterrupt = turnInterrupt
        self.paneRegistry = paneRegistry
        self.surfaceEndings = surfaceEndings
        self.sendBlockerChanges = sendBlockerChanges
        super.init(frame: .zero)
        wantsLayer = true
        // Drag types are registered dynamically, from the accepting state —
        // never here.
        setupKeyEventMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        cancellables.removeAll()
        firstResponderObservation?.invalidate()
        let key = ObjectIdentifier(self)
        paneRegistry?.unregisterUnsavedWorkChecker(key)
        paneRegistry?.unregisterFocusRestorer(key)
        paneRegistry?.unregisterFocusResigner(key)
        // Going away with a scrollback still open would strand the state, and
        // with it leave a sibling shell's Send disabled for good.
        if scrollbackOverlay != nil {
            paneRegistry?.setScrollbackOpen(false, kind: paneKind)
        }
    }

    // MARK: - Setup

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if !didSetUp && window != nil {
            setupTerminal()
            didSetUp = true
        }

        // Rebind the first-responder observer to the current window. Handles
        // both add and remove, so it exists only while actually in a window and
        // can never leak across a reattachment.
        startObservingFirstResponder()
    }

    private func setupTerminal() {
        mountTerminalSurface()
        observeScrollUp()
        observeFontSize()
        registerWithPaneRegistry()
        observeSurfaceEnding()
        observeSettingsChanges()
        observeAppTermination()
        observeScrollbackActivation()
        observeFindActivation()
        observeWindowBecameKey()
        observeKeyWindowChanges()

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.initialFocusDelay
        ) { [weak self] in
            self?.requestFocus()
        }
    }

    /// Paint the host strip, mount the terminal inside its inset container, and
    /// lay the drag highlight over the top.
    private func mountTerminalSurface() {
        // Paint before the container goes in, so the strip its inset leaves
        // exposed reads as part of the terminal rather than as a gap around it.
        applyHostBackgroundColor()

        // The container fills the host and lays the terminal out full-bleed
        // within the inset, so SwiftTerm never sees an offset frame.
        // Autoresizing is off so `layout()` stays the single source of truth.
        let container = GalacticTerminalContainerView(
            terminalView: pane.view,
            inset: Self.terminalPadding
        )
        container.frame = bounds
        container.autoresizingMask = []
        addSubview(container)
        terminalContainer = container

        // Above the container, so it orders over the terminal nested inside it.
        let highlight = DragHighlightView(frame: paddedBounds())
        highlight.autoresizingMask = []
        addSubview(highlight, positioned: .above, relativeTo: container)
        dragHighlightView = highlight

        refreshDragRegistration()
    }

    private func observeScrollUp() {
        // Pane-generic: both kinds route scroll-up through the pane contract,
        // so scrollback is entered uniformly.
        pane.onScrollUp = { [weak self] event in
            self?.handleScrollUp(event: event) ?? false
        }
    }

    private func observeFontSize() {
        // Re-lay the frozen buffer when the type changes underneath it —
        // otherwise a zoom leaves frozen cells misaligned against the live ones
        // behind. Host-lifetime rather than per-overlay: the size is published
        // and replays to every new subscriber, so subscribing per open would
        // deliver that replay against a page that has not finished loading, and
        // the re-render would read a scroll position that is not there yet.
        // Subscribed once here, the replay lands with no overlay open and the
        // re-render declines.
        pane.fontSizePublisher
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)
    }

    /// Register this host's unsaved-work checker and focus restorer on the
    /// registry, each tagged with its pane kind so callers can filter to the
    /// panes whose loss matters in their context. Paired with `deinit`.
    private func registerWithPaneRegistry() {
        guard let registry = paneRegistry else { return }
        let kind = paneKind
        let key = ObjectIdentifier(self)

        // Let close and quit ask this pane whether discarding its scrollback
        // would lose anything.
        registry.registerUnsavedWorkChecker(key, kind: kind) {
            [weak self] completion in
            guard let self = self else {
                completion(false)
                return
            }
            self.checkScrollbackUnsavedWork(completion: completion)
        }

        // Let cross-pane callers put focus back into this pane. Routed through
        // `requestFocus()` rather than the backend, which is what lets an open
        // scrollback overlay keep focus instead of the live terminal under it.
        registry.registerFocusRestorer(key, kind: kind) { [weak self] in
            self?.requestFocus()
        }

        // And the way back out. Without it the caret stays in this pane
        // after the app switches to a surface that has nothing to do with
        // it, and every modifier-less key equivalent loses to a terminal
        // the user cannot see.
        registry.registerFocusResigner(key) { [weak self] in
            self?.resignFocusIfHeld()
        }
    }

    private func observeSurfaceEnding() {
        // Close an open scrollback when whatever was behind this surface ends.
        // The overlay would otherwise stay up over a surface with nothing left
        // behind it, offering to send notes nowhere — which is also why there
        // is no note confirmation on this path: asking would offer a choice
        // that cannot be taken.
        //
        // Deliberately no `receive(on:)`; the reason is recorded on the signal.
        surfaceEndings
            .sink { [weak self] in
                self?.performScrollbackTeardown(reason: .sessionEnded)
            }
            .store(in: &cancellables)
    }

    private func observeSettingsChanges() {
        // Font family changes — re-render an open scrollback so it keeps
        // matching the live terminal underneath it.
        //
        // The prepend/dropFirst pair seeds a baseline for the dedupe rather
        // than replaying a value: the source deliberately does not resend the
        // current configuration, so with nothing to compare against the first
        // change of any kind would read as a font change and re-render for
        // nothing. No `receive(on:)` — the source guarantees main.
        settings.configurationChanges
            .map { $0.terminalFontFamily }
            .prepend(settings.configuration.terminalFontFamily)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Colour theme changes — repaint the padded host strip so it tracks the
        // theme, and re-render any open scrollback. Same baseline treatment. An
        // application whose theme is fixed never emits a change here, so this
        // costs it one dedupe and nothing else.
        settings.configurationChanges
            .map { $0.terminalColorThemeName }
            .prepend(settings.configuration.terminalColorThemeName)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyHostBackgroundColor()
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)
    }

    private func observeAppTermination() {
        // Close an open scrollback as the application quits, so its exit event
        // fires with a duration rather than the surface just vanishing with
        // notes still in it. The no-hop rule this depends on is documented
        // where the signal is.
        ApplicationLifecycle.willTerminate
            .sink { [weak self] in
                self?.performScrollbackTeardown(reason: .appQuit)
            }
            .store(in: &cancellables)
    }

    private func observeScrollbackActivation() {
        scrollbackActivations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.enterScrollbackFromMenu()
            }
            .store(in: &cancellables)
    }

    private func observeFindActivation() {
        // If a scrollback is already open here, bring up its find bar;
        // otherwise open one at the current viewport and queue the bar for
        // after the page paints.
        findActivations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.activateFindOnScrollback()
            }
            .store(in: &cancellables)
    }

    private func observeWindowBecameKey() {
        // The engine stops refreshing its display while the window is inactive,
        // so coming back can show cells that are several updates stale. Only
        // the pane the user was last in re-asserts focus — without that gate
        // both hosts race on every application switch and whichever ran last
        // takes focus regardless of where the user actually was.
        NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.isVisibleSurface else { return }
                guard let window = notification.object as? NSWindow,
                      window === self.window else { return }
                self.pane.redraw()
                guard self.isPreferredPane else { return }
                // Only when nothing in this pane already holds the caret.
                //
                // Compared against the whole view tree rather than the live
                // terminal alone, because a pane with a scrollback open holds
                // focus through the overlay's web view — which is not
                // `pane.view`, so testing that one view reads a focused pane as
                // an unfocused one and re-asserts over it.
                //
                // Harmless while the pane was the only claimant, and not
                // harmless once a sibling is being focused deliberately: this
                // notification also fires when the find panel hands key back to
                // its parent, which is exactly when a pane-directed command is
                // in flight. The re-assert would then land a hop after that
                // command and take the caret straight back to the pane the bar
                // was over.
                // Never while a sheet is attached. Raising one makes its parent
                // key, which arrives here — and answering by pulling the caret
                // into the pane takes it from the sheet that was just raised,
                // leaving its default button nothing to hear Return through.
                // The sheet's own focus loop re-makes the parent key on every
                // pass, so this would fire again for as long as that loop runs:
                // the correction and the theft share a trigger.
                guard window.attachedSheet == nil else { return }
                guard !self.holdsFirstResponder else { return }
                self.requestFocus()
            }
            .store(in: &cancellables)
    }

    /// Re-evaluate the focus dim whenever any window takes or gives up key.
    ///
    /// The find bar lives in its own panel, so it taking key moves focus out of
    /// this view without changing any first responder here — the KVO that
    /// normally drives the dim sees nothing at all. Deliberately unfiltered by
    /// window: the panel is not this view's window, and which window is
    /// involved is precisely what must not be assumed.
    private func observeKeyWindowChanges() {
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFocusState() }
                .store(in: &cancellables)
        }
    }

    /// Translate Ctrl+← / Ctrl+→ into start-of-line and end-of-line controls,
    /// matching Terminal.app; the shell's readline and an agent's input both
    /// understand these where the bare arrows do not. Also notice a bare Esc
    /// pressed during a turn, which is the user stopping it.
    ///
    /// Guarding on this pane's terminal holding first responder is what keeps
    /// each host's monitor to its own pane, and what makes it inert while a
    /// scrollback is open — the web view holds focus then, so the keys reach
    /// the page instead of the process, and no interrupt is recorded.
    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return event }
            guard self.window?.firstResponder === self.pane.view else {
                return event
            }

            // Deliberately not consumed: Esc still has to reach the terminal,
            // since aborting the stream is the far end's own job.
            self.turnInterrupt.recordIfInterrupting(event)

            // Control alone. Option or Command in the mix means the user is
            // asking for something else entirely.
            let controlOnly = event.modifierFlags
                .intersection([.control, .option, .command]) == .control
            guard controlOnly else { return event }

            switch event.keyCode {
            case 123:  // Left arrow → start of line, as Ctrl-A
                self.pane.send(text: "\u{01}", asPaste: false)
                return nil
            case 124:  // Right arrow → end of line, as Ctrl-E
                self.pane.send(text: "\u{05}", asPaste: false)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let inner = paddedBounds()
        // The container fills the host and lays the terminal out full-bleed
        // inside its inset; overlays align to that inset rect.
        terminalContainer?.frame = bounds
        dragHighlightView?.frame = inner
        // The scrollback overlay carries no autoresizing mask, so this is the
        // only thing that resizes it. Without it the overlay keeps whatever
        // size it was born at: opening a shell shrinks this host, and a stale,
        // too-tall overlay then extends up past the top of the pane.
        scrollbackOverlay?.frame = inner
    }

    /// Current bounds inset by the terminal padding. Used for every subview's
    /// frame so the host layer's colour shows through as a uniform strip.
    private func paddedBounds() -> NSRect {
        bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
    }

    /// Paint the host's layer in the current theme's background colour. Called
    /// at setup and on theme changes.
    private func applyHostBackgroundColor() {
        TerminalHostBackground.apply(
            to: self,
            themeNamed: settings.configuration.terminalColorThemeName
        )
    }

    // MARK: - Focus

    /// Whether this pane is the one the registry remembers the user typing in.
    ///
    /// The gate that keeps two panes of one session from both answering a
    /// command meant for whichever the user was actually in.
    private var isPreferredPane: Bool {
        (paneRegistry?.lastFocusedPaneKind ?? .session) == paneKind
    }

    /// Whether the caret is anywhere inside this pane.
    ///
    /// Descendants count, not just the live terminal: with a scrollback open the
    /// overlay's web view is what holds first responder, and it is no less this
    /// pane for being a different view. A test against `pane.view` alone reports
    /// a pane the user is reading and searching as having no focus at all.
    private var holdsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView
        else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    func requestFocus() {
        TerminalFocus.request(
            in: window,
            isVisibleSurface: isVisibleSurface,
            resolveTarget: { [weak self] in
                guard let self else { return nil }
                // With a scrollback open, focus belongs to the overlay's web
                // view rather than the live terminal behind it — otherwise
                // scrollback is visible but keyboard-dead, and Esc has nowhere
                // to go.
                if let webView =
                    self.scrollbackOverlay?.scrollbackView.webView
                {
                    return TerminalFocusTarget(
                        responder: webView, isLivePane: false
                    )
                }
                return TerminalFocusTarget(
                    responder: self.pane.view, isLivePane: true
                )
            },
            onFocusedLivePane: { [weak self] in
                // Friendly re-pin on focus gain: if the user intends to follow
                // the live tail, snap back to the bottom. A no-op when already
                // pinned, and never reached while parked in scrollback.
                self?.pane.reassertFollowIfIntended()
            }
        )
    }

    /// Take focus only when this pane is the one the user was last typing in.
    /// Without the gate both hosts grab on every activation and whichever runs
    /// last wins, overwriting the very memory that was meant to decide it.
    func requestFocusIfPreferred() {
        guard isPreferredPane else { return }
        requestFocus()
    }

    /// Give up first responder if this host holds it, and close the find bar.
    ///
    /// Called as this surface stops being somewhere the user can type; when
    /// that is depends on the application, which is why it says so rather than
    /// this working it out. The order matters enough that the reason is
    /// recorded on the shared implementation.
    func resignFocusIfHeld() {
        TerminalFocus.resignIfHeld(
            in: window,
            host: self,
            paneView: pane.view,
            findController: scrollbackOverlay?.findController
        )
    }

    /// (Re)bind the first-responder observer. Idempotent — the prior
    /// observation is invalidated first, and leaving a window simply leaves it
    /// torn down until the view is attached again.
    private func startObservingFirstResponder() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil
        guard let window = window else { return }
        firstResponderObservation = window.observe(
            \.firstResponder, options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.refreshFocusState()
        }
    }

    /// Dim this pane when focus is elsewhere, and record it as the last focused
    /// pane when focus is here. "Here" means this host or anything inside it,
    /// which covers the terminal surface, an open scrollback overlay, and
    /// anything nested nobody has thought of.
    private func refreshFocusState() {
        var isFocusInPane = holdsFirstResponder

        // The find bar is this pane's own UI even though AppKit puts it in a
        // separate window, so searching a scrollback must not read as having
        // left the pane — otherwise the pane dims and its overlay tints down
        // while the user is looking straight at it. Asserted rather than
        // inferred from first responder: which window holds focus while a child
        // panel is key is AppKit's business, and this does not need to depend
        // on getting that right.
        //
        // Gated on the bar actually holding key, not merely being open, so that
        // clicking into the sibling pane still dims this one.
        if !isFocusInPane,
           let findController = scrollbackOverlay?.findController,
           FindBarPanelController.shared.isKeyWindow(for: findController) {
            isFocusInPane = true
        }

        // Animate the dim so focus changes do not snap. 150ms matches the
        // cadence AppKit uses for a window's own active/inactive transition.
        let target: CGFloat = isFocusInPane ? 1.0 : Self.unfocusedPaneAlpha
        if pane.view.alphaValue != target {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                pane.view.animator().alphaValue = target
            }
        }

        // An open scrollback covers the view that just dimmed, so it carries
        // the same signal itself — otherwise two open scrollbacks look
        // identical and neither says which one is taking keys.
        scrollbackOverlay?.isPaneFocused = isFocusInPane

        // Record on entry only. Focus leaving for a field elsewhere keeps the
        // memory pointing at the pane the user was actually typing in, so
        // coming back lands them where they left off. Guarded on the value
        // actually changing: this is driven by KVO with `.initial`, so it fires
        // on every responder change in the window, and a registry that
        // publishes would otherwise invalidate every view observing it on each
        // one.
        if isFocusInPane, paneRegistry?.lastFocusedPaneKind != paneKind {
            paneRegistry?.lastFocusedPaneKind = paneKind
        }
    }

    // Let the terminal own first responder; clicks focus it.
    public override var acceptsFirstResponder: Bool { false }

    public override func mouseDown(with event: NSEvent) {
        requestFocus()
        super.mouseDown(with: event)
    }

    // MARK: - File drag-and-drop (bracketed paste)

    /// Drops are accepted only while the hosted pane belongs to the selected
    /// session and is willing to take them — for a session pane, while the
    /// session behind it is running.
    private var canAcceptDrop: Bool {
        isActiveSession && pane.acceptsFileDrops
    }

    /// Register for file drops only while accepting, and unregister otherwise,
    /// so a stopped or unselected pane is not a drop target.
    func refreshDragRegistration() {
        if canAcceptDrop {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    public override func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        // Refuse drops while any modal is presenting over our window:
        // application-modal windows or window-modal sheets. Prevents the
        // stale-render case where a drop accepts the paste bytes but the
        // terminal does not repaint until a later event wakes it. Do not gate
        // on isKeyWindow — for a drag from another application the source stays
        // active, so neither of our windows is key during the drag, which would
        // reject every legitimate drop.
        guard !ModalState.isPresenting(over: window) else {
            NSCursor.operationNotAllowed.set()
            return []
        }

        // A file drag dismisses scrollback; if notes are unsaved, confirm first
        // rather than auto-dismissing.
        if isScrollbackActive {
            if scrollbackOverlay?.scrollbackView.hasNotes == true {
                showDismissConfirmation()
                return []
            }
            performScrollbackTeardown(reason: .dismissed)
        }

        guard canAcceptDrop else {
            // "Not allowed" cursor for a stopped session.
            NSCursor.operationNotAllowed.set()
            return []
        }

        // Accept only file URLs.
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }

        isReceivingDrag = true
        NSCursor.dragCopy.set()
        return .copy
    }

    public override func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard !ModalState.isPresenting(over: window), canAcceptDrop else {
            NSCursor.operationNotAllowed.set()
            return []
        }
        NSCursor.dragCopy.set()
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    public override func performDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        isReceivingDrag = false
        NSCursor.arrow.set()

        // Defence in depth: the same guards as `draggingEntered`. AppKit may
        // not route here when entered returned [] — but if it does, refuse
        // cleanly.
        guard !ModalState.isPresenting(over: window), canAcceptDrop else {
            return false
        }

        // Bring the application and window forward when a file is dropped.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        // Deduplicate by standardized path — some drag sources duplicate.
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []
        for url in urls {
            let path = url.standardized.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                uniqueURLs.append(url)
            }
        }

        // Raw space-joined paths, as a paste would arrive, so an agent gives
        // them its file treatment.
        let pathsText =
            uniqueURLs.map { $0.path }.joined(separator: " ") + " "

        // Bracketed paste, no submit — the user reads the paths back and
        // presses Return themselves. Straight to the pane: routing it through
        // the chrome added a name and decided nothing.
        pane.send(text: pathsText, asPaste: true)

        // Kick a repaint before asking for focus. A drop can arrive from
        // another application, so this window was never key and the engine's
        // display refresh has been idle — without this the pasted paths can sit
        // unpainted until something else moves.
        pane.redraw()
        requestFocus()
        return true
    }

    // MARK: - Scrollback lifecycle

    /// Handle scroll-wheel-up on the live terminal. Returns true when the event
    /// was consumed by opening a scrollback, false to let the scroll proceed.
    private func handleScrollUp(event: NSEvent) -> Bool {
        guard scrollEntry.shouldEnter(
            configuration: settings.configuration,
            isSurfaceOpen: isScrollbackActive,
            hasContent: pane.hasScrollbackContent
        ) else { return false }

        let scrollPosition = pane.viewportRow
        pane.clearSelection()
        createScrollback(initialScrollLine: scrollPosition)
        return true
    }

    /// Enter scrollback from the menu action. Only the pane the user is
    /// actually typing into should answer — with a split open, both hosts hear
    /// the same signal.
    ///
    /// Unlike `handleScrollUp` this does not require buffer content: it is a
    /// deliberate user action, and even with an empty buffer entering lets the
    /// user annotate what is currently visible. The scroll path stays strict to
    /// avoid spawning an overlay on an ordinary gesture.
    private func enterScrollbackFromMenu() {
        guard isVisibleSurface else { return }
        guard !isScrollbackActive else { return }
        guard window?.firstResponder === pane.view else { return }

        // Capture the live viewport — the overlay opens at this position. Clear
        // any selection now, but defer snapping the live view to the bottom
        // until the page is visible, which avoids a flash of it jumping.
        let scrollPosition = pane.viewportRow
        pane.clearSelection()

        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Route ⌘F to this pane's scrollback, opening one at the current viewport
    /// if none is up and deferring the bar until the page is ready.
    ///
    /// Both hosts hear the signal, so exactly one has to answer, and focus
    /// memory decides which. Deliberately not a first-responder check: once the
    /// find panel takes key no pane holds first responder, and a re-press would
    /// then reach nobody.
    private func activateFindOnScrollback() {
        // An overlay survives a switch away from the terminal tab, so without
        // this it answers ⌘F pressed elsewhere and binds the shared find panel
        // to a surface nobody is looking at.
        guard isVisibleSurface else { return }
        guard isPreferredPane else { return }
        if let overlay = scrollbackOverlay {
            overlay.activateFind()
            return
        }
        // Opening a fresh scrollback is the one path that does want the
        // terminal focused, so a background pane cannot spawn one.
        guard window?.firstResponder === pane.view else { return }

        let scrollPosition = pane.viewportRow
        pane.clearSelection()

        pendingFindActivation = true
        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Build the scrollback overlay over an HTML rendering of the frozen
    /// terminal buffer.
    private func createScrollback(initialScrollLine: Int? = nil) {
        // The pane produces an opaque snapshot — chrome never reaches into
        // engine types to render it, which is what lets the same frozen buffer
        // be rendered again on a theme or font change.
        let configuration = settings.configuration
        guard let opened = ScrollbackFactory.open(
            pane: pane,
            theme: TerminalColorTheme.theme(
                named: configuration.terminalColorThemeName
            ),
            textEntry: configuration.textEntry.jsPayload,
            initialScrollLine: initialScrollLine
        ) else { return }

        currentSnapshot = opened.snapshot
        let webView = opened.webView

        webView.onDismiss = { [weak self] in
            self?.dismissScrollback(reason: .dismissed)
        }
        webView.onReady = { [weak self] in
            guard let self = self else { return }
            // Snap the live terminal to the bottom now that the overlay is
            // visible — prevents a flash of the live view jumping.
            self.pane.snapViewportToBottom()

            // Restore note cards if this is a re-render.
            webView.restoreNoteState()

            // Push the initial Send-button state and wire the live
            // subscriptions. The initial push matters because an overlay can
            // open with a blocker already in effect.
            self.refreshSendButtonState()
            self.subscribeToSendButtonStateChanges()

            // Seed the overlay's focus tint. The KVO observer is already
            // running — its lifetime is this view's, not the scrollback's — but
            // this overlay has only just appeared.
            self.refreshFocusState()

            // If ⌘F is what opened this scrollback, bring the bar up now that
            // there is a painted page to search. One-shot, so a later open from
            // the menu or a scroll does not spuriously activate find.
            if self.pendingFindActivation {
                self.pendingFindActivation = false
                self.scrollbackOverlay?.activateFind()
            }
        }
        webView.onConfirmDismiss = { [weak self] in
            self?.showDismissConfirmation()
        }
        webView.onSendToClaude = { [weak self] message in
            guard let self = self else { return }
            // Through the owning pane's target: an agent pane sends into
            // itself, a shell sends into the agent. Re-checking the gate here
            // covers the gap between the button being drawn and the click
            // arriving — the page should have disabled it already.
            guard let target = self.pane.sendToClaudeTarget,
                  target.disabledReason() == nil
            else { return }

            // Record before teardown destroys the web view and its notes. No
            // session check: the recorder declines a session it cannot
            // attribute, so asking first would be asking twice.
            if let overlay = self.scrollbackOverlay {
                let notes = overlay.scrollbackView.notes
                let expandedNotes: [[String: Any]] = notes.map { note in
                    [
                        "start_line": note.startLine,
                        "end_line": note.endLine,
                        "line_content": note.lineContent,
                        "note": note.content,
                    ] as [String: Any]
                }

                let detailData: [String: Any] = [
                    "pane": self.paneKind.rawValue,
                    "note_count": notes.count,
                    "message": message,
                    "notes": expandedNotes,
                ]

                self.timelineRecorder.record(
                    sessionID: self.pane.ledgerSessionId
                ) { id, recorder in
                    TerminalTimelineEvent(
                        sessionID: id,
                        type: "scrollback:reviewed",
                        paneKind: self.paneKind,
                        source: recorder.terminalSource,
                        detail: detailData,
                        detailMayBeLarge: true
                    )
                }
            }

            self.performScrollbackTeardown(reason: .reviewed)
            // The target owns the whole sequence — wait for the child to be
            // able to read, then type, pace and submit.
            target.send(message)
        }
        webView.onConfirmDiscardForm = { [weak self] in
            self?.showDiscardNoteFormConfirmation()
        }
        webView.onConfirmDiscardEdit = { [weak self] in
            self?.showDiscardNoteEditConfirmation()
        }
        webView.onConfirmDragReplace = { [weak self] startLine, endLine in
            self?.showDragReplaceNoteConfirmation(
                startLine: startLine, endLine: endLine
            )
        }
        webView.onConfirmSendWithUnsavedComment = { [weak self] in
            self?.showSendWithUnsavedCommentConfirmation()
        }
        webView.onNoteChanged = { [weak self] action, detailData in
            guard let self = self else { return }
            self.timelineRecorder.record(
                sessionID: self.pane.ledgerSessionId
            ) { id, recorder in
                TerminalTimelineEvent(
                    sessionID: id,
                    type: "scrollback.note:\(action)",
                    paneKind: self.paneKind,
                    source: recorder.scrollbackSource,
                    detail: detailData
                )
            }
        }

        // Sized to `paddedBounds()` so the overlay aligns exactly with the live
        // terminal's position inside the padded host — avoiding the shift on
        // enter and exit that happened when it was sized to the full bounds.
        //
        // The find bar's panel is shared, so an overlay has to be able to say
        // whether it is still the surface entitled to hold it. Left to the
        // default, an overlay claims it always is — and an overlay outlives a
        // switch away from the terminal tab, so it would put the bar up over
        // whatever the user moved to.
        let overlay = ScrollbackOverlayView(
            frame: paddedBounds(),
            scrollbackView: webView,
            isActiveSurface: { [weak self] in
                self?.isVisibleSurface ?? false
            }
        )
        overlay.autoresizingMask = []

        // Above the drag highlight, so while scrollback is open the overlay's
        // own web view intercepts file drags over itself and this host's
        // handlers are the safety path for drags reaching the live region.
        addSubview(overlay, positioned: .above, relativeTo: dragHighlightView)
        scrollbackOverlay = overlay

        // Say which pane just froze. Every pane reports: the cross-pane Send
        // gate reads only the agent's answer, but a reference sheet asks about
        // whichever surface the user is reading, and a shell that stayed silent
        // was the one pane it got wrong. Asked of the pane rather than by
        // testing its class, which is the same question with one fewer name.
        paneRegistry?.setScrollbackOpen(true, kind: paneKind)

        let durationId = "scrollback--\(UUID().uuidString)"
        scrollbackDurationId = durationId
        timelineRecorder.record(sessionID: pane.ledgerSessionId) { id, recorder in
            TerminalTimelineEvent(
                sessionID: id,
                type: "scrollback:entered",
                paneKind: paneKind,
                source: recorder.terminalSource,
                durationIdentifier: durationId
            )
        }

        // Make the page first responder so it takes keyboard events.
        window?.makeFirstResponder(webView.webView)
    }

    /// Dismiss scrollback with a reason. When the reason is `.dismissed` and
    /// unsaved notes exist, confirm instead of tearing down immediately.
    private func dismissScrollback(reason: ScrollbackExitReason) {
        guard let overlay = scrollbackOverlay else { return }

        // Guard against losing unsaved notes — only for a user-initiated
        // dismiss, never for a review or an ending.
        if reason == .dismissed && overlay.scrollbackView.hasNotes {
            showDismissConfirmation()
            return
        }

        performScrollbackTeardown(reason: reason)
    }

    /// Unconditional teardown. Fires the exit event, destroys the web view,
    /// nils the overlay and starts the re-entry cooldown. Idempotent — safe
    /// from every exit path.
    private func performScrollbackTeardown(reason: ScrollbackExitReason) {
        // Never let a stale flag outlive the overlay it was set for. Cleared
        // ahead of the guard so a no-op teardown clears it too.
        pendingFindActivation = false

        guard let overlay = scrollbackOverlay else { return }

        // Close find before tearing anything down. The bar is anchored to this
        // overlay, and the responder restore below should not race a panel that
        // is about to lose its web view. Synchronous, where the overlay's own
        // deinit safety net has to hop to the main actor.
        overlay.findController.isVisible = false

        timelineRecorder.record(sessionID: pane.ledgerSessionId) { id, recorder in
            let notes = overlay.scrollbackView.notes

            // Three shapes of the same event. A review already recorded its
            // notes in full, so this one only counts them; an exit with nothing
            // written has nothing to count; an exit that discards notes carries
            // them so they can be recovered, which is what makes its payload
            // unbounded.
            var detail: [String: Any] = ["reason": reason.rawValue]
            var mayBeLarge = false
            if reason == .reviewed {
                detail["note_count"] = notes.count
            } else if !notes.isEmpty {
                detail["note_count"] = notes.count
                detail["discarded_notes"] = notes.map { note in
                    [
                        "start_line": note.startLine,
                        "end_line": note.endLine,
                        "line_content": note.lineContent,
                        "note": note.content,
                    ] as [String: Any]
                }
                mayBeLarge = true
            }

            return TerminalTimelineEvent(
                sessionID: id,
                type: "scrollback:exited",
                paneKind: paneKind,
                source: recorder.terminalSource,
                durationIdentifier: scrollbackDurationId,
                detail: detail,
                detailMayBeLarge: mayBeLarge
            )
        }

        // Hand first responder back to the live terminal only if the web view
        // currently owns it, so nothing else has focus stolen from it.
        if window?.firstResponder === overlay.scrollbackView.webView {
            window?.makeFirstResponder(pane.view)
        }

        // Clear the Send-button subscriptions before the overlay goes away —
        // the button they push at is about to stop existing. The first-responder
        // observation stays alive: its lifetime is this view's, since it also
        // drives the always-on pane dim.
        sendButtonStateCancellables.removeAll()

        // Explicit teardown breaks the web view's retain cycle so its process
        // is freed immediately rather than leaking.
        overlay.scrollbackView.teardown()
        overlay.removeFromSuperview()
        scrollbackOverlay = nil
        scrollbackDurationId = nil
        currentSnapshot = nil

        // Mirror the open path.
        paneRegistry?.setScrollbackOpen(false, kind: paneKind)

        // Ignore the tail of the gesture that dismissed this, or it re-opens
        // what the user just closed.
        scrollEntry.beginCooldown(configuration: settings.configuration)
    }

    /// Render the frozen buffer again against the current theme and type.
    ///
    /// A full rebuild rather than a restyle: inline span styles are baked from
    /// the theme the page was built with. The scroll position is preserved.
    private func applySettingsToScrollback() {
        guard let overlay = scrollbackOverlay,
              let snapshot = currentSnapshot else { return }
        let configuration = settings.configuration
        overlay.reRender(
            snapshot: snapshot,
            theme: TerminalColorTheme.theme(
                named: configuration.terminalColorThemeName
            ),
            // The font the surface is actually showing, not the family that was
            // asked for. They differ whenever a configured family does not
            // resolve and the pane fell back, and rendering the snapshot in a
            // font the terminal is not using is visible as a seam at the
            // boundary between the two.
            fontFamily: pane.font.fontName,
            fontSize: pane.fontSize,
            textEntry: configuration.textEntry.jsPayload
        )
    }

    // MARK: - Send button

    /// Push the pane's current Send availability into the open overlay. A no-op
    /// when no overlay is up.
    ///
    /// The reason text is escaped before interpolation so wording containing an
    /// apostrophe or a backslash can never break the inline script.
    private func refreshSendButtonState() {
        guard let overlay = scrollbackOverlay else { return }
        let target = pane.sendToClaudeTarget
        let reason = target?.disabledReason()
        let enabled = (target != nil && reason == nil)
        let escaped = (reason ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        overlay.scrollbackView.webView.evaluateJavaScript(
            "window.GalaxySendBar.setState(\(enabled), '\(escaped)')"
        )
    }

    /// Subscribe to whatever can block this pane's Send, so the button enables
    /// and disables while the overlay is open rather than being judged once
    /// when it opened. Cleared on teardown.
    private func subscribeToSendButtonStateChanges() {
        sendButtonStateCancellables.removeAll()

        // Both panes ultimately write into the same agent, so both care whether
        // it is there to write to. What counts as "there" is the application's
        // to say, and it says so through this. One subscription rather than a
        // branch per pane kind: the two used to be the same expression twice.
        sendBlockerChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshSendButtonState() }
            .store(in: &sendButtonStateCancellables)

        // Only a shell is additionally blocked by the agent pane's own
        // scrollback being frozen open. Read from the registry, which outlives
        // the stop-and-resume cycles that destroy and rebuild this view — and
        // which shared code can reach without being handed anything.
        if paneKind == .shell {
            paneRegistry?.sessionPaneScrollbackActivePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshSendButtonState() }
                .store(in: &sendButtonStateCancellables)
        }
    }

    // MARK: - Confirmations

    private func showDismissConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmDiscardNotes(
            in: window,
            onDiscard: { [weak self] in
                self?.performScrollbackTeardown(reason: .dismissed)
            },
            onCancel: { [weak self] in self?.requestFocus() }
        )
    }

    private func showDiscardNoteFormConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmDiscardNoteForm(in: window) { [weak self] in
            self?.requestFocus()
        }
    }

    private func showDiscardNoteEditConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmDiscardNoteEdit(in: window) { [weak self] in
            self?.requestFocus()
        }
    }

    private func showDragReplaceNoteConfirmation(
        startLine: Int, endLine: Int
    ) {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmReplaceSelection(
            in: window, startLine: startLine, endLine: endLine
        )
    }

    private func showSendWithUnsavedCommentConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmSendWithUnsavedComment(in: window) { [weak self] in
            self?.requestFocus()
        }
    }

    // MARK: - Unsaved scrollback work

    /// Ask this pane's open scrollback whether it holds work that closing would
    /// discard. No overlay means nothing to lose. The answer lives in the
    /// page's own note state, so it has to be fetched from JavaScript — which
    /// is why the whole checker chain is asynchronous.
    private func checkScrollbackUnsavedWork(
        completion: @escaping (Bool) -> Void
    ) {
        guard let overlay = scrollbackOverlay else {
            completion(false)
            return
        }
        overlay.scrollbackView.webView.evaluateJavaScript(
            "ScrollbackManager.notes.hasUnsavedWork()"
        ) { result, _ in
            let hasWork = result as? Bool ?? false
            DispatchQueue.main.async {
                completion(hasWork)
            }
        }
    }
}
