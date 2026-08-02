# Galactic

A host-agnostic terminal engine bridge for AppKit applications.
Provides a stable seam between a host app's UI chrome and a
concrete terminal emulator library, so the host addresses the
engine through small, well-defined protocols rather than binding
directly to any specific implementation.

## Status

v0.6.0. Began as an engine bridge and is now also the shared
substrate for the applications built on it: pane composition, the
scrollback surface, find, text-entry bindings, and automated
prompt submission. The surface is correspondingly wider than it
once was and still evolving — pin it exactly, and expect breaking
changes in minor versions while the major version is zero.

## Requirements

- macOS 14+
- Swift tools 6.0 (language mode 5)

## Installation

Add Galactic as a Swift Package Manager dependency, pinned to a
released tag:

```swift
.package(
    url: "https://github.com/kellyredding/Galactic.git",
    exact: "0.6.0"
)
```

Then add it to a target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "Galactic", package: "Galactic")
    ]
)
```

## Architecture

Galactic sits between an AppKit host app and a concrete terminal
emulator library:

```
┌────────────────────────────────────────────┐
│                Host App (chrome)           │
│   UI shell, overlays, settings, menus      │
└────────────────────┬───────────────────────┘
                     │ protocols
                     │ (TerminalBackend, ScrollbackSnapshot)
┌────────────────────┴───────────────────────┐
│                  Galactic                  │
│   • Engine interface (protocols)           │
│   • Engine-agnostic data types             │
│   • Concrete engine adapter (internal)     │
└────────────────────┬───────────────────────┘
                     │ vendor API
┌────────────────────┴───────────────────────┐
│                 SwiftTerm                  │
│   PTY lifecycle, terminal emulation        │
└────────────────────────────────────────────┘
```

The boundary separates two concerns:

- **Engine vs chrome.** The terminal emulator (PTY management,
  escape-sequence parsing, cell layout) lives below the seam; UI
  shell (overlays, menus, settings UI) lives above. Neither side
  reaches into the other's internals.
- **Engine implementation vs interface.** Chrome consumes only
  protocol types and engine-agnostic value types. The concrete
  engine is selected via a factory at construction time, leaving
  room to swap in a different emulator without churning chrome.

## Usage

### Constructing a backend

```swift
import Galactic

let backend = TerminalBackendFactory.make(
    engine: .swiftTerm,
    kind: .session,
    frame: NSRect(x: 0, y: 0, width: 800, height: 600)
)
```

### Applying host settings

The host's settings type conforms to `GalacticConfiguration`. If
the property names already match the protocol, the conformance
is empty; otherwise a small adapter maps host-domain names to
the protocol's terminal-domain names.

```swift
struct AppSettings: GalacticConfiguration {
    var terminalColorThemeName: String
    var terminalFontFamily: String
    var defaultTerminalFontSize: CGFloat
    var terminalScrollbackLines: Int
}

backend.applySettings(mySettings)
```

### Launching a shell

```swift
backend.startProcess(
    executable: "/bin/zsh",
    args: ["-l"],
    environment: ProcessInfo.processInfo.environment.map {
        "\($0)=\($1)"
    },
    execName: "zsh",
    currentDirectory: NSHomeDirectory()
)
```

### Capturing scrollback

The snapshot freezes buffer state at capture time. Chrome iterates
cells and renders them in whatever format it owns — HTML overlay,
attributed string, PDF export, etc. No engine types leak through.

```swift
if let snapshot = backend.captureScrollbackSnapshot() {
    for line in 0..<snapshot.lineCount {
        snapshot.enumerateCells(line: line) { cell in
            // chrome renders cell.character using cell.style
        }
    }
}
```

## Public Surface

### Engine

- `TerminalBackend` — protocol the host addresses. Encapsulates
  PTY lifecycle, IO, font/color/cursor configuration, scrollback
  capture, and viewport control.
- `TerminalBackendFactory` — constructs a backend for a given
  engine and pane kind.
- `TerminalEngine` — engine selector (`.swiftTerm` ships today;
  additional engines may be added in future releases).
- `TerminalPaneKind` — pane lifecycle classifier (`.session`,
  `.shell`).

### Pane composition

- `TerminalHostView` / `FocusableTerminalView` — the view a pane
  is mounted in. Owns file drops, focus routing, the find bar, and
  the scrollback overlay's lifecycle.
- `TerminalPane` / `BackendBackedPane` — what a host's pane type
  answers so shared code can drive it without knowing which pane
  it is. A host declines a behaviour by supplying the value that
  turns it off, never by leaving a member out.
- `TerminalPaneRegistry` / `TerminalPaneCoordinator` — pane lookup
  and per-tab lifecycle, so a tab's panes are registered in one
  place rather than once per host.
- `ShellLaunch` — argument and environment recipe for starting a
  login shell in a pane.
- `PaneSplitRatio` / `PaneSplitBounds`, `ShellPaneBar`,
  `TerminalFocus`, `TerminalTabCommands`, `TerminalIdentity` —
  split geometry, pane chrome, focus targets, tab-level key
  commands, and the terminal identity advertised to the child.
- `TerminalVisualBell`, `TerminalBellDebounce`,
  `VisualBellCadence`, `UnreadIndicator`, `TurnInterrupt` — bell
  handling, unread state, and interrupt bookkeeping.

### Agent submission

- `AgentHarness` — what a terminal-hosted agent must answer for a
  host to type at it: the bytes that commit a prompt, the pause
  between text and submit, the bounds on waiting for either, how a
  lost prompt is recovered, and which commands never report
  acceptance. Nothing about *which* agent.
- `ClaudeCodeHarness` / `BareREPLHarness` — the conformers. The
  second exists so one implementation cannot pass for a neutral
  default.
- `TerminalBackend.deliverPrompt(…)` — the whole automated send:
  compose, wait until the agent can read, write, pace, submit,
  watch for acceptance. One place, because it was three and each
  copy lost a different part of it.
- `SubmitVerification` / `SubmitRetryPolicy` — how a host reports
  that a prompt was taken, and whether one found missing is worth
  retyping. Both are values, so declining either is explicit.
- `ClaudeKeybindingsWriter` — reconciles a host's configured
  keystrokes with Claude Code's own keybindings file.

### Text entry

- `TextEntryBindings` — which keystrokes submit and which insert a
  newline, shared by the host's settings and the scrollback
  surface's composer.
- `Keystroke` — a key plus modifiers, with the codec for Claude
  Code's binding spellings and the reserved chord used for
  automated submission.

### Scrollback surface

- `ScrollbackOverlayView` / `ScrollbackFactory` — the frozen
  buffer view a host presents over a live terminal, and its
  construction.
- `ScrollbackWebView` / `ScrollbackDropWebView` /
  `ScrollbackHTMLRenderer` — the web-backed surface, its file-drop
  variant, and the renderer that turns a snapshot into it.
- `AnnotationCoordinator` / `AnnotationMessage` / `ScrollbackNote`
  — annotations on scrollback content and the message protocol
  between the surface and its host.
- `SendToClaudeTarget` — where a surface's send routes, supplied
  by the host so the send inherits the readiness wait and pacing
  rather than reimplementing them.
- `SheetAlert` — host-presented confirmations for the surface.

### Find

- `FindBarView` / `FindBarPanelController` — the find chrome and
  its panel lifecycle.
- `WebViewFindController` — find over the scrollback surface.
- `ModalState` — whether a modal is up, so key handling defers.

### Scrollback capture

- `ScrollbackSnapshot` — frozen buffer state at capture time,
  iterated by chrome to produce any output format.
- `ScrollbackCell` / `ScrollbackCellStyle` — engine-agnostic
  per-cell representation, with character, column width, and
  style triple.
- `ScrollbackColor` — cell color (theme default, default-
  inverted, indexed ANSI 256, or direct 24-bit truecolor).
- `ScrollbackAttributes` — SGR attribute option set (bold,
  italic, underline, inverse, dim, invisible, crossed-out,
  blink).

### Configuration

- `GalacticConfiguration` — protocol the host's settings type
  conforms to. Defines the minimal terminal-domain configuration
  the engine bridge reads at apply time.
- `TerminalColorTheme` — color theme value type with hex-coded
  foreground, background, and 16-entry ANSI palette. Ships with
  thirteen built-in themes.
- `TerminalPaletteColor` — backend-agnostic 16-bit RGB palette
  entry.
- `ShellCursorStyle` — cursor shape selector (block, underline,
  vertical bar) paired at apply time with a blink flag to pick
  the engine's concrete cursor style.

### Utility

- `TerminalDisplayThrottle` — singleton pause primitive for
  suppressing redraw during host-side animations.
- `resolveTerminalFont(family:size:)` — font-family-to-`NSFont`
  resolution with a monospaced fallback for unknown families.
- `ProcessRunner` / `ProcessRunError` — runs a subprocess and
  drains its output without parking a thread for the process's
  lifetime.
- `GalacticLog` — where shared code logs. Discards by default; a
  host installs a sink to route the submission trail into its own
  log, which is the one record distinguishing bytes sent wrongly
  from bytes sent too early.
- `TerminalTimelineRecorder` / `TerminalTimelineEvent` — pane
  lifecycle events a host can record.
- `JavaScriptLiteral` — escaping for values interpolated into the
  scrollback surface's scripts.
- `ApplicationLifecycle`, `TerminalHostBackground`,
  `TerminalFontSizeBounds`, `ScrollToEnterScrollback`,
  `TextInputWarmup` — lifecycle hooks, host background colour,
  zoom bounds, the scroll-to-enter gesture, and first-keystroke
  warmup.

## Dependencies

Galactic depends on
[`kellyredding/SwiftTerm`](https://github.com/kellyredding/SwiftTerm),
a fork of
[`migueldeicaza/SwiftTerm`](https://github.com/migueldeicaza/SwiftTerm)
with patches required for the engine bridge. SwiftTerm is
MIT-licensed.

## License

MIT. See [LICENSE](LICENSE).
