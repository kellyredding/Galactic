# Maintaining Galactic

## Purpose

Galactic is a host-agnostic terminal engine bridge for AppKit
applications. This document is for **maintainers** — people landing
changes on this repo or bumping its underlying terminal-emulator
dependency. Consumers don't need to read this; they just pin a
released Galactic tag.

Galactic owns three things on behalf of its consumers:

- The public API surface (`TerminalBackend`, `ScrollbackSnapshot`,
  `GalacticConfiguration`, the color theme value types, …)
- The pin to its underlying terminal emulator — currently the
  Galactic fork of SwiftTerm
- The patch story behind that fork: why it exists, what it carries,
  and how to bump it

## The dependency chain

```
  kellyredding/SwiftTerm  (fork of migueldeicaza/SwiftTerm)
          │
          │  exact-version SPM pin
          ▼
  kellyredding/Galactic   ← this repo
          │
          │  exact-version SPM pin
          ▼
  consumer apps           (AppKit hosts: Galaxy and friends)
```

Each link in the chain pins the layer above with an exact tag, so
resolution is deterministic across consumers and CI. SwiftTerm is
transitive from a consumer's perspective — only Galactic depends on
the fork directly.

## Why a SwiftTerm fork at all?

Upstream SwiftTerm doesn't expose every primitive the Galactic chrome
seam needs, and a few rendering behaviors don't quite match what an
AppKit chrome layer wants for visual parity with native overlays. The
fork carries a small, focused patch set on top of upstream tagged
releases.

| Patch | Purpose |
|-------|---------|
| `galacticBoldForegroundColor` | Per-theme bold-text foreground override exposed at the boundary |
| Auto-follow rendering invariants | Keep the viewport pinned to live output unless the user has scrolled up; defend against trackpad inertia rebound at the bottom edge |
| `makeBackingLayer` visibility | Allow cross-module overrides for hosts that need to customize the rendering layer |
| Pixel-snap skip + FillStroke tune | Visual parity with WebKit-rendered scrollback overlays in chrome |

Detailed per-release notes — including patches dropped because
upstream landed an equivalent fix — live in the fork's `PATCHES.md`.

The fork tracks upstream tagged releases; it is not continuously
rebased against upstream `main`. Bumps are deliberate operations
triggered by a specific upstream version that Galactic wants to
adopt.

## Bumping the SwiftTerm pin

When upstream SwiftTerm ships a new version that Galactic wants to
adopt, the bump is a three-repo dance: fork → Galactic → consumers.

### Step 1 — Bump the fork

Follow the workflow in
[kellyredding/SwiftTerm's MAINTAINING.md](https://github.com/kellyredding/SwiftTerm/blob/main/MAINTAINING.md).
That process produces a new immutable tag of the form
`v<upstream-version>-galactic.<rev>`.

### Step 2 — Update Galactic's pin

Edit `Package.swift`:

```swift
.package(
    url: "https://github.com/kellyredding/SwiftTerm.git",
    exact: "<new-tag>"
)
```

### Step 3 — Verify Galactic builds and tests

```bash
swift build
swift test
```

The package tests are a minimal public-surface smoke check; they
catch missing-public-surface regressions but not behavior changes.
The real behavior verification happens in Step 4.

### Step 4 — Smoke-test through a consumer

Galactic's tests cannot exercise the AppKit chrome path because the
test target doesn't host a view hierarchy. Pin a consumer app's
Galactic dependency at the bump-branch commit and run the consumer's
full smoke checklist (session opens, scrollback auto-follow, text
selection + copy, window resize, theme switch, font-size change,
sidebar animation throttle).

If anything regresses, fix on the bump branch in Galactic before
promoting to `main`. The fork's patches are the most common source
of subtle behavior change between upstream releases — if a smoke
test fails, the fork's per-release `PATCHES.md` entry is usually the
first place to look.

### Step 5 — Commit on `main` and cut a release

Once the smoke test passes, commit the `Package.swift` change on
Galactic's `main` branch and cut a new release tag (see the next
section).

## Cutting a Galactic release tag

Releases follow [Semantic Versioning](https://semver.org/):

| Bump | When |
|------|------|
| **Patch** (`0.1.0` → `0.1.1`) | SwiftTerm pin bump or internal refactor with no public-API change |
| **Minor** (`0.1.0` → `0.2.0`) | Additive public-API change (new types, new protocol members with defaults, new factory cases) |
| **Major** (`0.1.0` → `1.0.0`) | Breaking public-API change (renamed protocol member, removed type, changed factory signature) |

```bash
git tag v<next>
git push origin main
git push origin v<next>
```

Then notify consumers — each consumer app updates its own
`Package.swift` or `project.yml` pin to the new Galactic tag.

## Safety rules

### NEVER re-point a published Galactic release tag

Once `v<X>.<Y>.<Z>` has been pushed and consumed by anyone — a
downstream app, a teammate's checkout, even your own local SwiftPM
cache — that tag is **immutable**. SwiftPM records `(URL, version) →
revision` in its manifest cache and rejects any resolve that returns
a different revision for the same tag.

If a typo or doc fix needs to ship on what would otherwise be a
re-tag, bump the patch version instead (`v<X>.<Y>.<Z+1>`). If the
original tag never made it past your local box, delete it locally
and from origin before anyone consumes it.

This rule cascades: the SwiftTerm fork follows the same rule for
its `-galactic.<rev>` tags, and consumer apps inherit the
deterministic-resolution guarantee.

### NEVER bump the SwiftTerm pin without consumer-side smoke testing

Galactic's package tests verify the public surface is callable; they
cannot verify rendering behavior, auto-follow invariants, focus
handling, or anything else that needs a hosted view hierarchy. The
fork's patches encode subtle behaviors that upstream tests don't
cover. Skipping consumer-side smoke testing means shipping
regressions that won't surface until a user sees them.

### NEVER widen the public surface casually

The chrome-engine boundary is what makes the extraction worth
having. Every new `public` type, method, or property is a long-term
support obligation — and a potential vector for chrome to bind to
engine specifics rather than the abstract seam. When a consumer
seems to need something new across the boundary, prefer extending
an existing protocol over exposing a new concrete type.

## Troubleshooting

### `Revision X does not match previously recorded value Y`

SwiftPM caches `(repo URL, version) → revision` globally and rejects
a resolve that returns a different revision for the same version
tag. This happens after a re-pointed tag (see the immutability rule
above) or when local SPM state predates the current tag.

```bash
rm -rf ~/Library/Caches/org.swift.swiftpm
```

If working in a consumer project, also wipe the project-local SPM
state:

```bash
rm -rf .build
# Xcode-based consumers also need:
rm -rf <project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
```

Then resolve and rebuild.

### Galactic's package tests build but a consumer fails to compile

Almost always a missing `public` modifier on a type, property,
method, or protocol member that the consumer reaches but the package
tests don't. The visibility audit doc lives implicitly in
`Tests/GalacticTests/GalacticPublicSurfaceTests.swift` — add a test
that touches the missing symbol so the regression is caught at the
package boundary next time.

### Bumping SwiftTerm breaks consumer rendering even though `swift test` passes

The fork's patches encode behaviors not covered by SwiftTerm's own
test suite (auto-follow invariants, FillStroke rendering, custom
scroller). Re-read the fork's `PATCHES.md` entry for the bumped
release — the most likely cause is either:

- An upstream change that superseded one of our patches in a way
  that subtly differs from the patch's intent
- A patch that didn't apply cleanly during the fork's bump and was
  rebased onto upstream's new line numbers but lost a semantic
  detail in translation

Roll back to the previous fork tag, reproduce the regression, then
work the diff between fork releases to isolate which patch hunk
changed behavior.
