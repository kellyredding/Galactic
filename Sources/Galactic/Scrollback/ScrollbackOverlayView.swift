import AppKit
import Combine

/// Container NSView that holds a ScrollbackWebView and a floating pill
/// indicator. Draws a 2px accent-color border around the entire view.
public class ScrollbackOverlayView: NSView {
    public let scrollbackView: ScrollbackWebView
    private let pillLabel: NSTextField

    /// Cmd+F find controller bound to the inner web view. Reverse
    /// mode flips iteration so the first match presented is the
    /// most-recent occurrence walking up — Terminal.app/iTerm
    /// behavior. Activated by the slice-4 dispatcher via
    /// `activateFind()`.
    public let findController: WebViewFindController

    /// Predicate the host installs at construction time so the
    /// overlay can self-gate whether it currently "owns" the
    /// shared `FindBarPanel`. True when the user is on the
    /// terminal tab AND looking at this overlay's session. The
    /// overlay is an `NSView` deep in the AppKit hierarchy with
    /// no direct view into `SessionManager`'s active-tab /
    /// active-session state; this closure is its hook into them.
    /// Called from the visibility sink and from
    /// `refreshFindBarPanelPresentation()` whenever the host
    /// detects the active surface may have changed.
    private let isActiveSurface: () -> Bool

    private var findVisibilityCancellable: AnyCancellable?

    /// AppKit-level Esc monitor. SwiftUI's
    /// `.keyboardShortcut(.escape)` on the find bar's X button
    /// doesn't reliably fire when the bar is hosted inside an
    /// AppKit subview hierarchy — the TextField's default
    /// cancelOperation: handler eats Esc before the SwiftUI
    /// shortcut sees it. This monitor intercepts Esc at the
    /// app event stream level, gated by find visibility.
    private var findEscapeMonitor: Any?

    /// Alpha applied to the border + pill background when
    /// the overlay's pane has lost focus. Visually de-
    /// emphasizes the inactive overlay so the user can
    /// tell at a glance which scrollback is "live" when
    /// both panes have a scrollback open.
    private static let unfocusedAlpha: CGFloat = 0.55

    /// Width of the accent border drawn around the overlay. The
    /// web view is inset by this amount so the border frames the
    /// content rather than covering its edge.
    public static let borderWidth: CGFloat = 2

    /// Whether the host pane is the focus-holder. Toggled
    /// by `TerminalHostView` via KVO on
    /// `window.firstResponder` while a scrollback is open.
    /// Defaults to true so the overlay reads as "active"
    /// the moment it appears (it almost always becomes
    /// firstResponder immediately).
    public var isPaneFocused: Bool = true {
        didSet {
            guard isPaneFocused != oldValue else { return }
            applyFocusedState()
        }
    }

    public init(
        frame: NSRect,
        scrollbackView: ScrollbackWebView,
        isActiveSurface: @escaping () -> Bool
    ) {
        self.scrollbackView = scrollbackView
        self.pillLabel = NSTextField(labelWithString: "Scrollback · Esc to exit")
        self.findController = WebViewFindController(
            webView: scrollbackView.webView,
            reverse: true
        )
        self.isActiveSurface = isActiveSurface
        super.init(frame: frame)
        wantsLayer = true

        // Add scrollback web view, inset by the border width so the
        // accent border frames the content instead of painting over
        // its first/last row and column. The fixed-margin autoresize
        // mask preserves that inset as the overlay resizes.
        scrollbackView.frame = bounds.insetBy(
            dx: Self.borderWidth, dy: Self.borderWidth
        )
        scrollbackView.autoresizingMask = [.width, .height]
        addSubview(scrollbackView)

        // Configure pill indicator
        configurePill()

        // Configure Cmd+F find bar (hidden until activateFind()
        // is called). Anchored to the same top-right slot as the
        // pill; the pill hides while find is visible to avoid
        // collision and to retire its now-misleading "Esc to exit"
        // hint (Esc closes the find bar instead of the overlay
        // while find is open).
        configureFindBar()
        installFindEscapeMonitor()

        // Draw 2px accent-color border (focus-aware via
        // applyFocusedState so the alpha is honored even on
        // first paint).
        layer?.borderWidth = Self.borderWidth
        applyFocusedState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Pill Indicator

    private func configurePill() {
        pillLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        pillLabel.textColor = contrastingTextColor()
        pillLabel.backgroundColor = NSColor.controlAccentColor
        pillLabel.drawsBackground = true
        pillLabel.isBezeled = false
        pillLabel.isEditable = false
        pillLabel.isSelectable = false
        pillLabel.alignment = .center
        pillLabel.sizeToFit()

        // Tight padding — flush against the top-right corner
        let hPadding: CGFloat = 6
        let vPadding: CGFloat = 2
        let pillWidth = pillLabel.frame.width + hPadding * 2
        let pillHeight = pillLabel.frame.height + vPadding * 2

        // Anchor flush to top-right corner (inside the border)
        pillLabel.frame = NSRect(
            x: bounds.width - pillWidth - 1,
            y: bounds.height - pillHeight - 1,
            width: pillWidth,
            height: pillHeight
        )
        pillLabel.autoresizingMask = [.minXMargin, .minYMargin]

        // Vertically center the text within the pill by using a
        // centered baseline offset via the cell's drawing rect
        (pillLabel.cell as? NSTextFieldCell)?.isScrollable = false

        // Square corners matching the terminal view
        pillLabel.wantsLayer = true
        pillLabel.layer?.cornerRadius = 0

        addSubview(pillLabel, positioned: .above, relativeTo: scrollbackView)
    }

    /// Compute contrasting text color based on accent color luminance.
    /// luma = 0.299*r + 0.587*g + 0.114*b; use black if luma > 0.5, white otherwise.
    private func contrastingTextColor() -> NSColor {
        guard let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return .white
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.5 ? .black : .white
    }

    // MARK: - Event Passthrough

    /// Pill must be transparent to all events (scroll, click, drag) so they
    /// pass through to the ScrollbackWebView underneath.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        // If the hit is on the pill, pass through to the web view
        let pointInPill = pillLabel.convert(point, from: self)
        if pillLabel.bounds.contains(pointInPill) {
            return scrollbackView.hitTest(convert(point, to: scrollbackView))
        }
        return super.hitTest(point)
    }

    // MARK: - Dynamic Accent Color

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Update border + pill colors when accent color
        // changes; preserve the current focus alpha.
        applyFocusedState()
        pillLabel.textColor = contrastingTextColor()
    }

    /// Apply the accent color at the alpha level dictated
    /// by `isPaneFocused`. Single source of truth for the
    /// border + pill background color so focus changes and
    /// appearance changes always agree.
    private func applyFocusedState() {
        let alpha: CGFloat = isPaneFocused
            ? 1.0
            : Self.unfocusedAlpha
        let tinted = NSColor.controlAccentColor
            .withAlphaComponent(alpha)
        layer?.borderColor = tinted.cgColor
        pillLabel.backgroundColor = tinted
    }

    public override func layout() {
        super.layout()
        // The find bar is pinned to this view's corner in screen
        // space, so a change in our own geometry has to move it —
        // a split drag, or a sibling pane opening and shrinking
        // us. The panel controller only watches the window for
        // resizes, and neither of those is one.
        FindBarPanelController.shared.reanchorIfPresenting(
            for: findController, anchorView: self
        )
    }

    // MARK: - Find Bar

    /// Mirror `findController.isVisible` into the panel and the
    /// pill: showing the find panel hides the pill so they don't
    /// compete for the top-right corner; closing the panel
    /// returns the pill. Also tells the page's `ScrollbackManager`
    /// to suspend its document-level keydown handler so Esc and
    /// arrows don't fight the find bar — without this, the JS
    /// would handle Esc as "dismiss scrollback" instead of "close
    /// find." Focus return to the scrollback WebView on close is
    /// handled by `FindBarPanelController.dismiss()` via the
    /// prior-first-responder it captured at present time.
    private func configureFindBar() {
        findVisibilityCancellable = findController.$isVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self = self else { return }

                self.syncFindBarPanel()

                self.pillLabel.isHidden = visible
                self.scrollbackView.webView.evaluateJavaScript(
                    "if (typeof ScrollbackManager !== "
                    + "'undefined') { "
                    + "ScrollbackManager.suspendInput(\(visible)); "
                    + "}"
                )
            }
    }

    /// Re-evaluate whether this overlay should currently hold
    /// the shared `FindBarPanel` and present or yield
    /// accordingly. The visibility sink in `configureFindBar`
    /// calls this when the controller's `isVisible` flips; the
    /// host (`TerminalHostView`) calls it on
    /// `SessionManager.activeTab` / `activeSessionId` changes,
    /// which this `NSView` can't observe directly.
    ///
    /// Yielding uses `dismiss(if:)` so a no-longer-active
    /// overlay can't tear down the panel of whichever surface
    /// just took ownership.
    public func refreshFindBarPanelPresentation() {
        syncFindBarPanel()
    }

    private func syncFindBarPanel() {
        guard isActiveSurface(), findController.isVisible else {
            FindBarPanelController.shared
                .dismiss(if: findController)
            return
        }
        FindBarPanelController.shared.present(
            controller: findController,
            anchorView: self
        )
    }

    /// Bring up the find bar in this overlay. Called by the
    /// Cmd+F dispatcher (slice 4) when this overlay is the
    /// active surface.
    public func activateFind() {
        findController.isVisible = true
    }

    /// Install a local NSEvent monitor that closes the find
    /// bar on Esc when find is visible. Gated by visibility so
    /// the second Esc (with find already closed) falls through
    /// to the WebView, where ScrollbackManager.handleKey
    /// dismisses the overlay as usual.
    ///
    /// Also gated by `isActiveSurface()` so an inactive
    /// overlay's monitor doesn't steal Esc from whichever
    /// surface currently owns the find panel. The monitor is
    /// app-wide (`addLocalMonitorForEvents` isn't view-scoped),
    /// and `findController.isVisible` deliberately survives
    /// tab/session switches so find can restore on return —
    /// without this gate, a backgrounded overlay with a
    /// retained `isVisible == true` would swallow the first
    /// Esc the user types into the foreground find bar.
    private func installFindEscapeMonitor() {
        findEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            // A confirmation sheet owns Escape while it is up, where it already
            // means Cancel. Without this the first Escape closes the find bar
            // behind the sheet and never reaches it, which is what made
            // cancelling a sheet raised over a visible find bar take two.
            guard let self = self,
                  event.keyCode == Keystroke.Key.esc,
                  !SheetAlert.isClaimingKeyboard,
                  self.findController.isVisible,
                  self.isActiveSurface()
            else { return event }
            self.findController.isVisible = false
            return nil
        }
    }

    deinit {
        if let monitor = findEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Yield the shared panel. Without this, any teardown that
        // isn't Esc — send to Claude, session exit, app quit,
        // discarding notes — leaves the bar floating, bound to a
        // web view that no longer exists. The panel retains the
        // controller through its hosting view, which is exactly
        // why it can be stranded.
        //
        // Hopped to the main actor because the panel controller is
        // isolated to it and deinit is not; the controller is
        // captured by value so it survives the hop.
        let controller = findController
        Task { @MainActor in
            FindBarPanelController.shared.dismiss(if: controller)
        }
    }
}
