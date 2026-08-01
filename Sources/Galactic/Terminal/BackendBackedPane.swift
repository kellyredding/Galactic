import AppKit
import Combine

/// A pane that owns a terminal backend, and so can answer most of the pane
/// contract by asking it.
///
/// `TerminalPane` deliberately says nothing about where a pane's answers come
/// from — a pane that adapts some other object's terminal is a legitimate
/// conformer, and both apps have one. But a pane that *owns* a backend answers
/// a dozen of those members by forwarding a single call, and writing those
/// forwards out per pane per app is four copies of the same file's worth of
/// one-liners.
///
/// So this narrows the contract to the case where the answers are the backend's,
/// and supplies them. What a conformer still has to say for itself is the part
/// that is genuinely its own: which backend, what its font size is, how to push
/// that size down, and what the configured default is.
///
/// Adapter panes deliberately do not conform. Forwarding to a session model
/// rather than to a backend is the seam between the two apps, and it is the one
/// thing here that cannot be shared.
public protocol BackendBackedPane: TerminalPane {

    /// The backend this pane owns. Every default below is a call on it.
    var backend: TerminalBackend { get }

    /// Where this pane reads configuration and hears about changes to it.
    ///
    /// A source rather than a value, because a pane has to react to a change as
    /// well as read the current state — and the only way to hear about one used
    /// to be to name the host's settings singleton, which is exactly the name
    /// that cannot move.
    var settings: GalacticConfigurationSource { get }

    /// Whether the pane's process is running.
    ///
    /// Gates both closing it — there is nothing to signal otherwise — and
    /// accepting file drops, since a path pasted into a dead shell goes nowhere.
    ///
    /// Settable because both transitions belong to the defaults below rather
    /// than to a conformer: starting a shell sets it and the process exiting
    /// clears it, and those were the only two writes either pane had. A
    /// conformer typically publishes it, so the write announces itself.
    var isRunning: Bool { get set }

    /// This pane's own font size, which zooming moves.
    ///
    /// Settable because the zoom defaults below write it. A conformer typically
    /// publishes it, so the write announces itself to whatever is drawing.
    var fontSize: CGFloat { get set }

    /// The zoom window. Defaults to the shared one; a conformer overrides only
    /// to differ from it deliberately.
    var fontSizeBounds: TerminalFontSizeBounds { get }
}

public extension BackendBackedPane {

    // MARK: - The backend's answers

    var view: NSView { backend.view }

    var hasScrollbackContent: Bool { backend.hasScrollbackContent }

    var viewportRow: Int { backend.viewportRow }

    var font: NSFont { backend.font }

    var cellHeight: CGFloat { backend.cellHeight }

    /// Forwarded rather than stored, so a host adopting scroll-to-enter assigns
    /// a closure the engine will actually call. Stored, it would accept one and
    /// never invoke it, and the omission would be invisible from outside.
    var onScrollUp: ((NSEvent) -> Bool)? {
        get { backend.onScrollUp }
        set { backend.onScrollUp = newValue }
    }

    func clearSelection() { backend.clearSelection() }

    func redraw() { backend.redraw() }

    func snapViewportToBottom() { backend.snapViewportToBottom() }

    func trimBuffer() { backend.trimBuffer() }

    func reflowBuffer() { backend.reflowBuffer() }

    func reassertFollowIfIntended() { backend.reassertFollowIfIntended() }

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        backend.captureScrollbackSnapshot()
    }

    func send(text: String, asPaste: Bool) {
        backend.send(text: text, asPaste: asPaste)
    }

    func focus() { backend.focus() }

    var acceptsFileDrops: Bool { isRunning }

    // MARK: - Zoom

    var fontSizeBounds: TerminalFontSizeBounds { .standard }

    /// The size resetting zoom returns to — the configured default, held inside
    /// the window in case a stored value predates a narrower one.
    var defaultFontSize: CGFloat {
        settings.configuration.defaultTerminalFontSize
    }

    /// Push this pane's own size to the backend.
    ///
    /// Only the font: a zoom has no business rebuilding the colour table or
    /// reallocating scrollback, which a full settings re-apply would do. The
    /// family comes from configuration because a size alone does not name a
    /// font, and the family is never per-pane.
    func applyFontSize() {
        backend.setFont(
            resolveTerminalFont(
                family: settings.configuration.terminalFontFamily,
                size: fontSize
            )
        )
    }

    func increaseFontSize() {
        fontSize = fontSizeBounds.increased(from: fontSize)
        applyFontSize()
    }

    func decreaseFontSize() {
        fontSize = fontSizeBounds.decreased(from: fontSize)
        applyFontSize()
    }

    func resetFontSize() {
        fontSize = fontSizeBounds.clamped(defaultFontSize)
        applyFontSize()
    }

    var canIncreaseFontSize: Bool {
        fontSizeBounds.canIncrease(from: fontSize)
    }

    var canDecreaseFontSize: Bool {
        fontSizeBounds.canDecrease(from: fontSize)
    }

    // MARK: - Lifecycle

    /// Ask the process to exit.
    ///
    /// SIGHUP rather than SIGTERM: it is the canonical terminal-hangup signal,
    /// so a shell exits gracefully and flushes its history in response, and the
    /// backend escalates to the harsher signals for anything that ignores it.
    /// Exit arrives back through the process-terminated callback, which is what
    /// prompts teardown — this only asks.
    func requestClose() {
        guard isRunning else { return }
        backend.terminateProcess(signal: SIGHUP)
    }

    /// Start a shell in this pane.
    ///
    /// Everything the two applications disagreed about is in the value handed
    /// in; what is left is the order, which neither had any reason to differ on.
    /// Settings go on before the process starts so the first thing painted is
    /// already the right size and colour — applying afterwards makes a shell
    /// visibly reflow as its prompt appears.
    func startShell(_ launch: ShellLaunch) {
        applyCurrentSettings()
        backend.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment,
            execName: launch.executableName,
            currentDirectory: launch.workingDirectory
        )
        isRunning = true
        GalacticLog.debug(
            "shell-pane",
            "started \(launch.executable) in \(launch.workingDirectory)"
        )
    }

    /// Let the backend's process exit reach this pane and anything watching it.
    ///
    /// Hopped to main rather than delivered wherever the process happened to
    /// die on, because the flag it clears is published and the observer it
    /// calls redraws.
    func forwardProcessExit() {
        backend.onProcessTerminated = { [weak self] exitCode in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.onProcessExit?(exitCode)
            }
        }
    }

    /// Push the whole configuration to the backend, at this pane's own size.
    ///
    /// The caret is shown explicitly because a terminal-hosted program relies on
    /// the terminal to draw its cursor, and the engine's default has been false
    /// only by luck of initialisation — one app asserted it and the other did
    /// not, which is precisely the kind of difference this being shared removes.
    ///
    /// The cursor needs its own call: the engine fuses shape and blink into one
    /// style, so it is not part of the configuration surface `applySettings`
    /// reads.
    func applyCurrentSettings() {
        let configuration = settings.configuration
        backend.applySettings(configuration, fontSize: fontSize)
        backend.setCaretHidden(false)
        backend.applyCursor(
            style: configuration.terminalCursorStyle,
            blink: configuration.terminalCursorBlink
        )
    }

    /// Re-apply configuration to the backend whenever it changes, storing the
    /// subscription in `cancellables`.
    ///
    /// Takes the store rather than owning one because a protocol extension has
    /// nowhere to keep it, and the pane's lifetime is the right lifetime for it
    /// anyway.
    ///
    /// One subscription, not two. Both apps ran a second stream purely to
    /// deduplicate the cursor pair, because two independent subscriptions would
    /// each push a cursor on their first emission. A single already-deduplicated
    /// source removes the reason for it.
    func observeSettings(storingIn cancellables: inout Set<AnyCancellable>) {
        settings.configurationChanges
            .sink { [weak self] configuration in
                guard let self else { return }
                self.backend.applySettings(
                    configuration, fontSize: self.fontSize
                )
                self.backend.applyCursor(
                    style: configuration.terminalCursorStyle,
                    blink: configuration.terminalCursorBlink
                )
            }
            .store(in: &cancellables)
    }
}
