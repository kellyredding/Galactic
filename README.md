# Galactic

A host-agnostic terminal engine bridge for AppKit applications.
Provides a stable seam between a host app's UI chrome and a
concrete terminal emulator library, so the host addresses the
engine through small, well-defined protocols rather than binding
directly to any specific implementation.

## Status

v0.1.0 — initial release. The public API surface is intentionally
small and may evolve as additional use cases come online.

## Requirements

- macOS 14+
- Swift tools 6.3 (language mode 5)

## Installation

Add Galactic as a Swift Package Manager dependency, pinned to a
released tag:

```swift
.package(
    url: "https://github.com/kellyredding/Galactic.git",
    exact: "0.1.0"
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

### Scrollback

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

## Dependencies

Galactic depends on
[`kellyredding/SwiftTerm`](https://github.com/kellyredding/SwiftTerm),
a fork of
[`migueldeicaza/SwiftTerm`](https://github.com/migueldeicaza/SwiftTerm)
with patches required for the engine bridge. SwiftTerm is
MIT-licensed.

## License

MIT. See [LICENSE](LICENSE).
