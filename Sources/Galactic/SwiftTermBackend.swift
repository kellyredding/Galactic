import AppKit
import Combine
import SwiftTerm

/// Resolve a Galaxy font-family setting to a concrete `NSFont`
/// at the given point size. SF Mono resolves via the system
/// monospaced API (`.medium` weight matches Terminal.app's
/// rendering more closely than `.regular`, which Apple maps
/// to an unexpectedly light weight for SF Mono). Everything
/// else resolves via `NSFont(name:size:)` with a monospaced
/// fallback, so an invalid family name yields a usable
/// terminal font instead of a system default proportional
/// font. Free function rather than a backend method so
/// pane-side consumers (Session, ShellTerminalPane) can apply
/// per-pane font-size overrides without naming a concrete
/// backend type.
public func resolveTerminalFont(
    family: String, size: CGFloat
) -> NSFont {
    if family == "SF Mono" {
        return NSFont.monospacedSystemFont(
            ofSize: size, weight: .medium
        )
    }
    return NSFont(name: family, size: size)
        ?? NSFont.monospacedSystemFont(
            ofSize: size, weight: .regular
        )
}

/// `TerminalBackend` implementation backed by Galaxy's
/// `GalacticSwiftTermView` — a `LocalProcessTerminalView`
/// subclass that intercepts scroll events, suppresses the
/// default bell NSBeep, and exposes focus-event quenching.
///
/// The Shell pane reaches the SwiftTerm engine through this
/// backend. The Session pane currently constructs
/// `GalacticSwiftTermView` directly via `Session.swift`; that
/// path will migrate to a `TerminalBackend` reference in a
/// follow-up slice of the terminal-backend unification work.
final class SwiftTermBackend: NSObject, TerminalBackend,
    LocalProcessTerminalViewDelegate {

    private let terminalView: GalacticSwiftTermView

    var view: NSView { terminalView }
    var onProcessTerminated: ((Int32) -> Void)?

    /// Set once we've notified our owner that the child
    /// exited. Either SwiftTerm's natural delegate path or
    /// our explicit-terminate failsafe will reach
    /// `fireProcessTerminatedOnce`; whichever wins, the
    /// other becomes a no-op.
    private var hasFiredProcessTerminated = false

    var onScrollUp: ((NSEvent) -> Bool)? {
        get { terminalView.onScrollUp }
        set { terminalView.onScrollUp = newValue }
    }

    var hasScrollbackContent: Bool {
        terminalView.terminal.displayBuffer.yBase > 0
    }

    var viewportRow: Int {
        terminalView.terminal.displayBuffer.yDisp
    }

    func clearSelection() {
        terminalView.selection.selectNone()
    }

    var font: NSFont { terminalView.font }

    var cellHeight: CGFloat {
        // SwiftTerm computes cellDimension lazily on first
        // layout — it's effectively never nil after the
        // surface has been shown. Force-unwrap matches the
        // existing chrome read site that this method
        // replaces; if the assumption ever breaks we'll see
        // it here, in one place, instead of scattered.
        terminalView.cellDimension!.height
    }

    func redraw() {
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    func snapViewportToBottom() {
        let buf = terminalView.terminal.displayBuffer
        terminalView.terminal.userScrolling = false
        buf.yDisp = buf.yBase
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    /// Forward to the subclass's stored property so
    /// `bell(source:)` can fire it directly without a
    /// backend back-reference. Mirrors `onScrollUp`.
    var onBell: (() -> Void)? {
        get { terminalView.onBell }
        set { terminalView.onBell = newValue }
    }

    /// Subscription to `TerminalDisplayThrottle.shared`
    /// that mediates between the chrome-driven throttle
    /// signal and the view's invalidation behavior. Lives
    /// on the backend (rather than inside the view) so
    /// `GalacticSwiftTermView` doesn't need to know that the
    /// throttle, SidebarPreferences, or Combine exist —
    /// the view exposes a backend-agnostic `displayPaused`
    /// flag, and this subscription is what flips it. A
    /// future libghostty backend would have an analogous
    /// subscription in its own init translating
    /// `$isPaused` into whatever its rendering layer
    /// supports.
    private var displayThrottleCancellable: AnyCancellable?

    init(frame: NSRect) {
        self.terminalView = GalacticSwiftTermView(frame: frame)
        super.init()
        // Conform to LPTV directly — process-lifecycle
        // callbacks land on `processTerminated(source:exitCode:)`
        // below.
        self.terminalView.processDelegate = self
        observeDisplayThrottle()
    }

    /// Mirror `TerminalDisplayThrottle.shared.isPaused`
    /// into the view's `displayPaused` flag, and on the
    /// trailing edge (paused → resumed) fire a single
    /// catch-up redraw covering the full bounds. Because
    /// the catch-up runs *after* `displayPaused` flips
    /// false, the override in `GalacticSwiftTermView`
    /// forwards that single `setNeedsDisplay` to super,
    /// rendering whatever buffer changes accumulated
    /// during the pause.
    private func observeDisplayThrottle() {
        displayThrottleCancellable =
            TerminalDisplayThrottle.shared.$isPaused
                .receive(on: DispatchQueue.main)
                .sink { [weak self] paused in
                    guard let self = self else { return }
                    self.terminalView.displayPaused = paused
                    if !paused {
                        // Catch-up redraw covers any cell
                        // changes that accumulated while
                        // the override was suppressing
                        // setNeedsDisplay calls.
                        self.terminalView.setNeedsDisplay(
                            self.terminalView.bounds
                        )
                    }
                }
    }

    // MARK: - Process

    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        execName: String,
        currentDirectory: String
    ) {
        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory
        )
    }

    /// Terminate the running subprocess with internal
    /// escalation. The caller passes the *first* signal to
    /// send; the backend handles bounded escalation if the
    /// process doesn't exit:
    ///
    /// - `SIGHUP`  → escalate to `SIGTERM` after 0.5s, then
    ///   `SIGKILL` after 1.0s.
    /// - `SIGTERM` → escalate to `SIGKILL` after 0.5s.
    /// - Any other signal: send once, no escalation.
    ///
    /// `kill(pid, 0)` checks process liveness without
    /// signaling, so each escalation step is a no-op if the
    /// process already exited from a prior signal. We bypass
    /// SwiftTerm's `terminate()` (which hard-codes SIGTERM)
    /// and send the signals ourselves via
    /// `terminalView.process.shellPid` so the caller's
    /// initial-signal choice is honored exactly.
    ///
    /// SwiftTerm's exit-detection — `DispatchSourceProcess`
    /// on the forkpty path, the `await Subprocess.run`
    /// continuation on the Subprocess path — does not
    /// reliably fire after an explicit kill. The downstream
    /// chain (`onProcessTerminated` → `ShellTerminalPane` →
    /// `SplitState.closeShell`) hangs on the missed callback,
    /// so the pane stays visible after Cmd+W even though the
    /// kill went through. We schedule a guaranteed delegate
    /// fire after a short grace period; SwiftTerm's natural
    /// path dedupes via `fireProcessTerminatedOnce` if it
    /// wins the race.
    func terminateProcess(signal: Int32) {
        let pid = terminalView.process.shellPid
        guard pid > 0 else {
            NSLog(
                "SwiftTermBackend: no shellPid to terminate"
            )
            return
        }

        // Initial signal — caller's choice.
        kill(pid, signal)

        // Escalation timeline. Empty for signals other than
        // SIGHUP/SIGTERM, so an explicit SIGKILL caller is a
        // single-shot.
        let escalations:
            [(deadline: TimeInterval, signal: Int32)] = {
            switch signal {
            case SIGHUP:
                return [(0.5, SIGTERM), (1.0, SIGKILL)]
            case SIGTERM:
                return [(0.5, SIGKILL)]
            default:
                return []
            }
        }()

        for (deadline, escalateSignal) in escalations {
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + deadline) {
                    [weak self] in
                    guard self != nil else { return }
                    // `kill(pid, 0)` — liveness check.
                    // Returns 0 if the process exists; non-
                    // zero (errno=ESRCH) if it has already
                    // exited from a prior signal in this
                    // escalation chain.
                    guard kill(pid, 0) == 0 else { return }
                    kill(pid, escalateSignal)
                }
        }

        // Failsafe: ensure processTerminated fires even if
        // SwiftTerm's natural exit-detection misses.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.3
        ) { [weak self] in
            self?.fireProcessTerminatedOnce(exitCode: 0)
        }
    }

    // MARK: - IO

    func send(bytes: [UInt8]) {
        terminalView.send(bytes)
    }

    func send(text: String, asPaste: Bool) {
        if asPaste, terminalView.terminal.bracketedPasteMode {
            terminalView.send(
                Array(EscapeSequences.bracketedPasteStart)
            )
            terminalView.send(txt: text)
            terminalView.send(
                Array(EscapeSequences.bracketedPasteEnd)
            )
        } else {
            terminalView.send(txt: text)
        }
    }

    // MARK: - Buffer / appearance

    func changeHistorySize(_ lines: Int) {
        terminalView.terminal.changeHistorySize(lines)
    }

    func installColors(_ palette: [TerminalPaletteColor]) {
        let swiftTermPalette = palette.map {
            SwiftTerm.Color(
                red: $0.red, green: $0.green, blue: $0.blue
            )
        }
        terminalView.installColors(swiftTermPalette)
    }

    func setForegroundColor(_ color: NSColor) {
        terminalView.nativeForegroundColor = color
    }

    func setBackgroundColor(_ color: NSColor) {
        terminalView.nativeBackgroundColor = color
    }

    func setBoldForegroundColor(_ color: NSColor) {
        terminalView.galacticBoldForegroundColor = color
    }

    func applySettings(_ settings: GalacticConfiguration) {
        // Theme.
        let theme = TerminalColorTheme.theme(
            named: settings.terminalColorThemeName
        )
        setForegroundColor(theme.foregroundColor)
        setBackgroundColor(theme.backgroundColorValue)
        setBoldForegroundColor(theme.boldForegroundColor)
        installColors(theme.terminalPalette)

        // Font (uses the global default size; per-pane size
        // overrides are applied separately by the consumer
        // that owns the override — Session via
        // `applyPerSessionFontSize`, ShellTerminalPane via
        // `applyPerPaneFontSize`).
        setFont(
            resolveTerminalFont(
                family: settings.terminalFontFamily,
                size: settings.defaultTerminalFontSize
            )
        )

        // Scrollback.
        changeHistorySize(settings.terminalScrollbackLines)

        // NOTE: cursor styling is intentionally NOT applied
        // here. `shellCursorStyle` / `shellCursorBlink` are
        // Shell-only — the Shell pane subscribes to those via
        // its own deduplication wrapper. The Session pane
        // keeps SwiftTerm's caret hidden (Claude Code self-
        // renders the cursor), so applying cursor settings on
        // every Session-pane settings change would be churn at
        // best, and risks the cursor-style delegate hook
        // re-touching caret view state we want to stay hidden.
    }

    var suppressFocusEvents: Bool {
        get { terminalView.suppressFocusEvents }
        set { terminalView.suppressFocusEvents = newValue }
    }

    func feed(text: String) {
        terminalView.feed(text: text)
    }

    func setFont(_ font: NSFont) {
        terminalView.font = font
    }

    func applyCursor(
        style: ShellCursorStyle, blink: Bool
    ) {
        // Collapse Galaxy's two orthogonal toggles into
        // SwiftTerm's 6-case `CursorStyle` enum. Setting
        // via `terminal.setCursorStyle` fires the delegate
        // hook which updates `MacCaretView`'s shape and
        // toggles the blink animation off the CALayer
        // opacity keypath.
        let mapped: SwiftTerm.CursorStyle = {
            switch (style, blink) {
            case (.block, true):        return .blinkBlock
            case (.block, false):       return .steadyBlock
            case (.underline, true):    return .blinkUnderline
            case (.underline, false):   return .steadyUnderline
            case (.verticalBar, true):  return .blinkBar
            case (.verticalBar, false): return .steadyBar
            }
        }()
        terminalView.terminal.setCursorStyle(mapped)
    }

    func setCaretHidden(_ hidden: Bool) {
        terminalView.caretView.isHidden = hidden
    }

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        // SwiftTerm's `snapshotBuffer(_:)` is non-optional —
        // it deep-copies whatever buffer is handed in. The
        // protocol return type stays optional so future
        // backends (or pane-teardown races) can still bow
        // out cleanly.
        let buffer = terminalView.terminal.snapshotBuffer(
            terminalView.terminal.buffer
        )
        return SwiftTermScrollbackSnapshot(
            buffer: buffer,
            terminal: terminalView.terminal
        )
    }

    // MARK: - Focus

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(
        source: TerminalView,
        exitCode: Int32?
    ) {
        fireProcessTerminatedOnce(exitCode: exitCode ?? 0)
    }

    /// Idempotent delegate fire. Either SwiftTerm's natural
    /// `processTerminated` delegate or the
    /// `terminateProcess` failsafe reaches here; the second
    /// caller is a no-op.
    private func fireProcessTerminatedOnce(
        exitCode: Int32
    ) {
        guard !hasFiredProcessTerminated else { return }
        hasFiredProcessTerminated = true
        onProcessTerminated?(exitCode)
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {
        // No-op — SwiftTerm reflows internally.
    }

    func setTerminalTitle(
        source: LocalProcessTerminalView,
        title: String
    ) {
        // No-op — Shell pane doesn't display a title.
    }

    func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {
        // No-op — Shell pane doesn't track cwd.
    }
}

/// `ScrollbackSnapshot` impl over a SwiftTerm `Buffer +
/// Terminal` pair. Captures both at construction so the
/// underlying state is frozen — even if the live terminal
/// moves on, the snapshot keeps yielding the same captured
/// cells.
///
/// `Terminal` is captured because cell iteration needs
/// `terminal.getCharacter(for:)` for extended grapheme
/// lookup (CharData.code values >= maxRune). Both the buffer
/// and terminal references are kept private — chrome
/// consumers see only the engine-agnostic `ScrollbackCell`
/// stream yielded through `enumerateCells(line:visit:)`,
/// without any reach-through into SwiftTerm types.
final class SwiftTermScrollbackSnapshot: ScrollbackSnapshot {
    private let buffer: Buffer
    private let terminal: Terminal

    let cols: Int
    let yDisp: Int

    var lineCount: Int { buffer.lines.count }

    init(buffer: Buffer, terminal: Terminal) {
        self.buffer = buffer
        self.terminal = terminal
        self.cols = buffer.cols
        self.yDisp = buffer.yDisp
    }

    func enumerateCells(
        line lineIndex: Int,
        visit: (ScrollbackCell) -> Void
    ) {
        guard lineIndex >= 0, lineIndex < buffer.lines.count else {
            return
        }
        let line = buffer.lines[lineIndex]
        let cellCount = min(cols, line.count)
        for col in 0..<cellCount {
            let cell = line[col]
            visit(Self.convert(cell: cell, terminal: terminal))
        }
    }

    /// Convert one SwiftTerm `CharData` cell into the engine-
    /// agnostic `ScrollbackCell` representation. Resolves
    /// extended grapheme clusters via the captured terminal
    /// and translates SwiftTerm's `Attribute` shape into
    /// `ScrollbackColor` + `ScrollbackAttributes`.
    private static func convert(
        cell: CharData, terminal: Terminal
    ) -> ScrollbackCell {
        // Character resolution. Null cells become a single
        // space; in-range codepoints become the corresponding
        // Unicode scalar; out-of-range codes are extended
        // grapheme clusters fetched from the terminal.
        let character: String
        if cell.code == 0 && cell.width == 1 {
            character = " "
        } else if cell.code < Int32(CharData.maxRune) {
            if let scalar = Unicode.Scalar(UInt32(cell.code)) {
                character = String(Character(scalar))
            } else {
                character = " "
            }
        } else {
            character = String(terminal.getCharacter(for: cell))
        }

        let attr = cell.attribute
        let style = ScrollbackCellStyle(
            foreground: convert(color: attr.fg),
            background: convert(color: attr.bg),
            attributes: convert(style: attr.style)
        )
        return ScrollbackCell(
            character: character,
            columnWidth: Int(cell.width),
            style: style
        )
    }

    private static func convert(
        color: Attribute.Color
    ) -> ScrollbackColor {
        switch color {
        case .defaultColor:
            return .defaultColor
        case .defaultInvertedColor:
            return .defaultInvertedColor
        case .ansi256(let code):
            return .ansi256(code)
        case .trueColor(let r, let g, let b):
            return .trueColor(red: r, green: g, blue: b)
        }
    }

    private static func convert(
        style: CharacterStyle
    ) -> ScrollbackAttributes {
        var out: ScrollbackAttributes = []
        if style.contains(.bold)       { out.insert(.bold) }
        if style.contains(.italic)     { out.insert(.italic) }
        if style.contains(.underline)  { out.insert(.underline) }
        if style.contains(.inverse)    { out.insert(.inverse) }
        if style.contains(.dim)        { out.insert(.dim) }
        if style.contains(.invisible)  { out.insert(.invisible) }
        if style.contains(.crossedOut) { out.insert(.crossedOut) }
        if style.contains(.blink)      { out.insert(.blink) }
        return out
    }
}
