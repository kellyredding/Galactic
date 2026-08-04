import AppKit
import XCTest
@testable import Galactic

/// Smoke test for Galactic's public surface. Exercises the
/// chrome-facing types from outside the module to confirm
/// the visibility audit caught everything chrome consumes.
/// Add real engine-level tests here as the module grows.
final class GalacticPublicSurfaceTests: XCTestCase {
    func testColorThemeLookup() {
        let theme = TerminalColorTheme.theme(named: "galaxy-default")
        XCTAssertEqual(theme.id, "galaxy-default")
        XCTAssertFalse(theme.ansiColors.isEmpty)
        XCTAssertEqual(theme.ansiColors.count, 16)
    }

    func testColorThemeBuiltInsNonEmpty() {
        XCTAssertFalse(TerminalColorTheme.builtIn.isEmpty)
    }

    func testNsColorFromHex() {
        let color = TerminalColorTheme.nsColor(from: "#FF0000")
        XCTAssertNotNil(color)
    }

    func testShellCursorStyleAllCases() {
        XCTAssertEqual(ShellCursorStyle.allCases.count, 3)
        XCTAssertEqual(ShellCursorStyle.block.displayName, "Block")
    }

    func testScrollbackAttributesOptionSet() {
        let combined: ScrollbackAttributes = [.bold, .italic]
        XCTAssertTrue(combined.contains(.bold))
        XCTAssertTrue(combined.contains(.italic))
        XCTAssertFalse(combined.contains(.underline))
    }

    func testScrollbackColorEquality() {
        XCTAssertEqual(
            ScrollbackColor.ansi256(15), ScrollbackColor.ansi256(15)
        )
        XCTAssertNotEqual(
            ScrollbackColor.defaultColor,
            ScrollbackColor.defaultInvertedColor
        )
    }

    func testTerminalDisplayThrottleShared() {
        XCTAssertNotNil(TerminalDisplayThrottle.shared)
    }

    func testTerminalContainerInsetsContent() {
        let terminal = NSView()
        let container = GalacticTerminalContainerView(
            terminalView: terminal, inset: 4
        )
        container.frame = NSRect(x: 0, y: 0, width: 100, height: 80)

        XCTAssertTrue(container.terminalView === terminal)
        XCTAssertEqual(container.contentInsets.left, 4)
        // Content rect is the container's bounds inset on every edge —
        // the rect the terminal fills and overlays align to.
        XCTAssertEqual(
            container.contentFrame,
            NSRect(x: 4, y: 4, width: 92, height: 72)
        )
    }

    /// The registry is reached as an existential, never as a concrete type —
    /// that is the whole point of it being a protocol, so the surface test
    /// exercises the form the hosts actually hold.
    func testPaneRegistryIsReachableAsAnExistential() {
        let registry: any TerminalPaneRegistry = StubPaneRegistry()

        registry.lastFocusedPaneKind = .shell
        registry.setSessionPaneScrollbackActive(true)

        XCTAssertEqual(registry.lastFocusedPaneKind, .shell)
        XCTAssertTrue(registry.sessionPaneScrollbackActive)
        XCTAssertNotNil(registry.sessionPaneScrollbackActivePublisher)
    }

    /// A public struct's memberwise init is internal, so the explicit one is
    /// what makes the bar reachable by a host app at all. Constructing it here
    /// is a weaker check than it looks — this target imports the module
    /// `@testable` — so the real proof of the surface is both apps compiling.
    func testShellPaneBarTakesItsFourCallbacks() {
        let bar = ShellPaneBar(
            onDragBegan: {}, onDrag: { _ in },
            onDragEnded: {}, onResetSplit: {}
        )

        XCTAssertNotNil(bar)
    }

    /// The one branch in the bar worth pinning: a double-click resets the
    /// split, and must not also be read as the start of a drag. Getting that
    /// wrong leaves the divider mid-drag with no mouseUp coming.
    func testADoubleClickResetsRatherThanBeginningADrag() throws {
        var began = 0
        var reset = 0
        let view = ShellPaneBarNSView()
        view.onDragBegan = { began += 1 }
        view.onResetSplit = { reset += 1 }

        view.mouseDown(with: try mouseDown(clickCount: 2))

        XCTAssertEqual(reset, 1, "a double-click resets the split")
        XCTAssertEqual(began, 0, "and must not also begin a drag")
    }

    func testASingleClickBeginsADrag() throws {
        var began = 0
        var reset = 0
        let view = ShellPaneBarNSView()
        view.onDragBegan = { began += 1 }
        view.onResetSplit = { reset += 1 }

        view.mouseDown(with: try mouseDown(clickCount: 1))

        XCTAssertEqual(began, 1)
        XCTAssertEqual(reset, 0)
    }

    private func mouseDown(clickCount: Int) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            )
        )
    }

    /// The strip left by the container's inset has to end up the terminal's own
    /// colour, or it reads as a seam between the terminal and the chrome above.
    func testTheHostBackgroundTakesTheThemeColour() {
        let view = NSView()
        let theme = TerminalColorTheme.theme(named: "galaxy-default")

        TerminalHostBackground.apply(to: view, themeNamed: "galaxy-default")

        XCTAssertTrue(
            view.wantsLayer,
            "the paint is meaningless unbacked, so it turns backing on rather "
                + "than assuming it"
        )
        XCTAssertEqual(
            view.layer?.backgroundColor, theme.backgroundColorValue.cgColor
        )
    }

    func testPaneKindCarriesAStableIdentifier() {
        XCTAssertEqual(TerminalPaneKind.session.rawValue, "session")
        XCTAssertEqual(TerminalPaneKind.shell.rawValue, "shell")
        // Hashable by synthesis, which is what lets the registry take a Set.
        XCTAssertEqual(Set<TerminalPaneKind>([.shell, .shell]).count, 1)
    }

    /// A host reaches scroll entry through three members and nothing else: it
    /// builds one, asks it, and tells it a surface was dismissed.
    func testScrollEntryAnswersAHostThroughItsConfiguration() {
        var configuration = StubConfiguration()
        configuration.scrollToEnterScrollback = true
        let entry = ScrollToEnterScrollback()

        XCTAssertTrue(
            entry.shouldEnter(
                configuration: configuration,
                isSurfaceOpen: false,
                hasContent: true
            )
        )

        entry.beginCooldown(configuration: configuration)

        XCTAssertFalse(
            entry.shouldEnter(
                configuration: configuration,
                isSurfaceOpen: false,
                hasContent: true
            )
        )
    }

    // MARK: - The terminal host

    /// The host takes every application-owned answer as a value, and an
    /// application that has none of them can still supply all of them.
    ///
    /// This is the whole claim the move rests on, so it is asserted rather than
    /// described: nil recorder, nil turn interrupt, nil registry and a surface
    /// nothing ends are a complete set of arguments. An application adopting any
    /// of these later changes a value here, not the host.
    func testAHostIsBuiltEntirelyFromValuesAnAppSupplies() {
        let pane = StubPane()
        let host = TerminalHostView(
            pane: pane,
            timelineRecorder: nil,
            settings: StubConfigurationSource(),
            findActivations: .never,
            scrollbackActivations: .never,
            turnInterrupt: nil,
            paneRegistry: nil,
            surfaceEndings: .never,
            sendBlockerChanges: .never
        )

        // The one member an application reads back off the host, when a ⌘W
        // interceptor walks up from the first responder asking whose pane this
        // is.
        XCTAssertTrue(host.pane === pane)
        XCTAssertFalse(host.isScrollbackActive)

        // Both flags start false, so a host that is never told is never treated
        // as the surface in front of the user — the safe way round for a
        // question whose wrong answer steals the caret.
        XCTAssertFalse(host.isActiveSession)
        XCTAssertFalse(host.isVisibleSurface)
    }

    /// The representable's equality is what `.equatable()` at a call site
    /// depends on to skip an update, and skipping one wrongly means a focus
    /// re-assert that does not happen.
    func testTheRepresentableComparesIdentityAndActivity() {
        let pane = StubPane()
        let registry = StubPaneRegistry()
        let settings = StubConfigurationSource()

        func view(
            pane: TerminalPane = pane,
            isActiveSession: Bool = true,
            isVisibleSurface: Bool = true,
            shouldResignFocus: Bool = false
        ) -> FocusableTerminalView {
            FocusableTerminalView(
                pane: pane,
                timelineRecorder: nil,
                settings: settings,
                findActivations: .never,
                scrollbackActivations: .never,
                turnInterrupt: nil,
                paneRegistry: registry,
                surfaceEndings: .never,
                sendBlockerChanges: .never,
                isActiveSession: isActiveSession,
                isVisibleSurface: isVisibleSurface,
                shouldResignFocus: shouldResignFocus
            )
        }

        XCTAssertEqual(view(), view())
        XCTAssertNotEqual(view(), view(pane: StubPane()))
        XCTAssertNotEqual(view(), view(isActiveSession: false))
        XCTAssertNotEqual(view(), view(isVisibleSurface: false))
        XCTAssertNotEqual(view(), view(shouldResignFocus: true))
    }

    // MARK: - Search

    func testFuzzyMatchIsReachableWithBothScopes() {
        XCTAssertNotNil(FuzzyMatch.result("Clear session", query: "clear"))
        XCTAssertNotNil(
            FuzzyMatch.score("Clear session", query: "cle", scope: .terms)
        )
        XCTAssertTrue(
            FuzzyMatch.matches("Clear session", query: ""),
            "an empty query is a match, which is what an unfiltered list is"
        )
    }

    // MARK: - The cheat sheet

    /// A public struct's memberwise init is internal, so these explicit ones
    /// are the entire seam — a host that cannot build a row cannot use the
    /// sheet at all.
    func testACheatSheetSectionIsBuiltFromValuesAHostSupplies() {
        let section = CheatSheetSection(
            id: "terminal",
            title: "Terminal & Agent",
            rows: [
                CheatSheetRow(
                    id: "terminal.0",
                    keys: "⇧⌘⌫",
                    label: "Clear session",
                    condition: "while a terminal pane is focused",
                    isActive: false
                )
            ]
        )

        XCTAssertEqual(section.id, "terminal")
        XCTAssertEqual(section.rows.first?.label, "Clear session")
        XCTAssertFalse(
            section.rows.first?.isActive ?? true,
            "the host resolved availability; nothing here re-decides it"
        )
        // Aliases are optional at the seam: a host with no synonyms of its own
        // says nothing and still gets its glyphs spelled by the view.
        XCTAssertEqual(section.rows.first?.aliases, "")
    }

    /// Identity is the host's to supply and has to be unique across the whole
    /// sheet, not per section: one container holds every row, and a repeated id
    /// is what puts rows under the wrong header.
    func testCheatSheetRowsAreIdentifiableAndComparable() {
        let a = CheatSheetRow(
            id: "terminal.0", keys: "⌘K", label: "Clear",
            condition: "", isActive: true
        )
        let b = CheatSheetRow(
            id: "lists.0", keys: "⌘K", label: "Clear",
            condition: "", isActive: true
        )

        XCTAssertEqual(a, a)
        XCTAssertNotEqual(
            a, b, "two rows that render alike still differ by id"
        )
    }

    func testCheatSheetSearchIsCallableFromOutsideItsView() {
        let hits = CheatSheetSearch.hits(
            [
                CheatSheetSearch.Candidate(
                    label: "Clear session", keys: "⇧⌘⌫",
                    section: "Terminal", condition: "",
                    aliases: CheatSheetGlyphs.spelled("⇧⌘⌫")
                )
            ],
            query: "shift")

        XCTAssertNotNil(hits.first ?? nil)
    }

    /// The three members a host reaches: the shared presenter, the static gate
    /// its key monitors read, and the view it mounts.
    @MainActor
    func testTheCheatSheetIsReachedThroughItsSharedPresenter() {
        let presenter = CheatSheetPresenter.shared
        // Restored to the default rather than left set — it is the same
        // closure, but the next test in this target should not inherit one.
        defer {
            presenter.dismiss()
            presenter.sectionsProvider = { [] }
        }
        presenter.sectionsProvider = { [] }

        presenter.toggle()

        XCTAssertTrue(presenter.isPresented)
        XCTAssertTrue(CheatSheetPresenter.isClaimingKeyboard)
        XCTAssertNotNil(CheatSheetView())
    }

    @MainActor
    func testTextEntryBindingsSpellTheirConfiguredKeystrokes() {
        XCTAssertEqual(
            TextEntryBindings.default.displayLabels(for: .submit), ["Enter"]
        )
    }
}
