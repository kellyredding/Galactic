import AppKit
import SwiftUI

/// Borderless `NSPanel` that hosts the find bar in a separate
/// window from the parent surface.
///
/// **Why a panel and not an inline overlay?** AppKit's
/// `NSAutoFillHeuristicController` queues a synchronous
/// password-autofill check whenever a text field becomes first
/// responder. The check walks the entire window's keyboard focus
/// loop, recursing through the SwiftUI hierarchy and performing
/// `AnyHashable.==` comparisons at every node. With Galaxy's
/// per-session view fan-out, that walk takes 2–3 seconds on
/// first Cmd+F per session — pinned via thread sampling to
/// `_NSComputeFirstKeyViewVisuallyInDirection` traversing tens
/// of thousands of SwiftUI views.
///
/// Hosting the find bar in its own panel scopes the heuristic's
/// walk to the panel's view tree, which contains only the find
/// bar's three buttons and the text field — about five focusable
/// views total. The heuristic still fires, but its walk completes
/// in single-digit milliseconds. This is the same pattern Apple
/// uses for `NSTextFinder` and the find UIs in Safari, Pages,
/// and Xcode.
///
/// The panel is non-activating and floats above the parent
/// window as a child window, so it tracks parent moves
/// automatically. Resizes are handled by re-anchoring on
/// `windowDidResize` notifications.
final class FindBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    public init(contentView: NSView) {
        super.init(
            contentRect: NSRect(
                origin: .zero, size: contentView.fittingSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.isMovable = false
        self.hasShadow = true
        self.hidesOnDeactivate = false
        // Becomes key only when its content needs key (i.e., the
        // text field accepts text input). Lets the parent window
        // stay key when find isn't active, which is what every
        // single-control panel in AppKit wants.
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.contentView = contentView
    }
}

/// Orchestrates the lifecycle of a single shared `FindBarPanel`
/// for a parent main window. Surfaces (artifact reader, snapshot
/// reader, scrollback overlay) call `present(...)` when their
/// `WebViewFindController` becomes visible and `dismiss()` when
/// it hides. Only one panel is alive at a time per main window;
/// switching surfaces while find is open dismisses-and-presents
/// to rebind the SwiftUI host to the new controller.
@MainActor
public final class FindBarPanelController {
    public static let shared = FindBarPanelController()

    private var panel: FindBarPanel?
    private var hostingView: NSView?

    /// Whether a find bar is on screen right now. Read by `ModalState` so
    /// drag targets treat the bar as a presentation to refuse drops under,
    /// the same way they treat a sheet.
    public var isPresenting: Bool { panel != nil }

    /// Whether the bar belongs to `controller` *and* currently holds key.
    ///
    /// A pane treats this as its own focus. Both halves matter: merely being
    /// on screen is not enough, or the pane that opened find would stay lit
    /// while the user typed in the other one.
    public func isKeyWindow(for controller: WebViewFindController) -> Bool {
        panel?.isKeyWindow == true && currentController === controller
    }
    private weak var parentWindow: NSWindow?
    private weak var priorParentResponder: NSResponder?
    private weak var currentController: WebViewFindController?
    private var resizeObserver: NSObjectProtocol?

    /// Insets from the surface's top-right corner to the panel's
    /// top-right corner. Anchored to the WebView (not the
    /// surrounding reader chrome), so the bar already lands
    /// below the reader's header bar without needing a top
    /// offset to clear it. A few pixels keep the panel from
    /// looking flush against the WebView edge.
    private static let topInset: CGFloat = 4
    private static let trailingInset: CGFloat = 4

    /// Type sizes for the bar, asked for each time one is presented.
    ///
    /// A closure rather than a stored value because a host that scales its
    /// chrome does so from a live setting, and the bar has to pick up a change
    /// made while the app is running. Set once at launch; a host with no such
    /// setting leaves it alone and gets the defaults.
    ///
    /// Threaded through here rather than through `present` so that call sites —
    /// of which there are ten in one app — do not each have to know about it.
    public var metricsProvider: () -> FindBarView.Metrics = { .default }

    private init() {}

    /// Show the find bar panel anchored to `anchorView`'s
    /// top-right corner, bound to `controller`. Idempotent: if
    /// the panel is already visible bound to the same
    /// controller, no-op (just re-anchor in case layout
    /// shifted); otherwise dismiss-and-re-present.
    public func present(
        controller: WebViewFindController,
        anchorView: NSView
    ) {
        guard let parent = anchorView.window else { return }

        if currentController === controller, panel != nil {
            // Find bar already up for this controller. Re-anchor
            // in case the surface's layout shifted, then re-key
            // the panel and re-focus the field — the user just
            // pressed Cmd+F, so they want the bar focused even
            // if focus had drifted (e.g., they clicked into the
            // WebView). Standard macOS find-UI behavior.
            reanchor(to: anchorView, in: parent)
            if let p = self.panel, let hosting = self.hostingView {
                p.makeKeyAndOrderFront(nil)
                focusFirstTextField(in: hosting, panel: p)
            }
            return
        }

        // Read where focus should return to *before* any teardown. `dismiss`
        // puts first responder back where the outgoing bar found it, so
        // reading it afterwards captures that stale value — the pane the
        // previous bar belonged to — instead of the one the user is in now.
        let incomingPriorResponder = parent.firstResponder

        let previousController = currentController
        if panel != nil {
            // Hand over without restoring focus at all. The restore is
            // pointless here, since the new bar is about to take focus, and
            // harmful: it briefly moves first responder into the outgoing
            // pane, which is enough for the focus observers to record that
            // pane as the one the user was last in.
            priorParentResponder = nil
            dismiss()
        }

        priorParentResponder = incomingPriorResponder
        parentWindow = parent
        currentController = controller

        // Retire whoever held the bar before. Two panes can each have a
        // scrollback open, so two controllers can each believe they are
        // visible — but there is one panel, so the loser would be left with
        // highlights, a true `isVisible`, and nothing on screen to close it
        // with. Ordered after `currentController` is reassigned so the old
        // controller's own visibility sink finds the panel already handed
        // over and leaves it alone.
        if previousController !== controller {
            previousController?.isVisible = false
        }

        let rootView = FindBarView(
            controller: controller, metrics: metricsProvider()
        )
        let hosting = NSHostingView(rootView: rootView)
        // Coax SwiftUI into laying out by giving the hosting
        // view a non-zero initial frame. Without this,
        // fittingSize on a fresh NSHostingView returns zero
        // until it's been in a sized window for a layout pass.
        hosting.frame = NSRect(
            x: 0, y: 0, width: 480, height: 40
        )

        let p = FindBarPanel(contentView: hosting)
        // Inherit the parent window's effective appearance so
        // SwiftUI's dynamic colors (controlBackgroundColor,
        // labelColor, etc.) resolve under the same dark/light
        // mode as the surrounding chrome instead of the panel's
        // platform default.
        p.appearance = parent.effectiveAppearance
        // Hide while we let SwiftUI do its first layout pass.
        // NSHostingView doesn't produce a valid fittingSize
        // until it's been added to a window AND given a layout
        // tick; without this the first present lands with
        // stale (zero or default) geometry and the user sees
        // the panel pop in mis-anchored, then jump to the
        // correct spot a frame later when SwiftUI catches up.
        p.alphaValue = 0
        panel = p
        hostingView = hosting

        parent.addChildWindow(p, ordered: .above)
        p.makeKeyAndOrderFront(nil)

        // After SwiftUI has had a runloop tick to lay out
        // inside the now-windowed hosting view, read the real
        // intrinsic size, set the panel's content size to
        // match, position correctly, focus the text field, and
        // then fade in. Doing focus AFTER layout ensures the
        // NSTextField subview exists in the hosting tree and
        // is a valid target for makeFirstResponder.
        DispatchQueue.main.async { [weak self, weak anchorView, weak parent, weak p, weak hosting] in
            MainActor.assumeIsolated {
                guard let self = self,
                      let anchorView = anchorView,
                      let parent = parent,
                      let p = p,
                      let hosting = hosting,
                      self.panel === p
                else { return }
                hosting.layoutSubtreeIfNeeded()
                let size = hosting.fittingSize
                if size.width > 0 && size.height > 0 {
                    p.setContentSize(size)
                }
                self.positionPanel(
                    p, anchorView: anchorView, parent: parent
                )
                self.focusFirstTextField(in: hosting, panel: p)
                p.alphaValue = 1
            }
        }

        // Re-anchor on parent resize. addChildWindow handles
        // moves automatically, but resizes don't translate the
        // panel — we have to recompute when the parent's frame
        // changes width/height.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parent,
            queue: .main
        ) { [weak self, weak anchorView, weak parent] _ in
            // Notification queue is .main, so we're on the main
            // thread; assumeIsolated lets us call back into our
            // @MainActor self without a Task hop.
            MainActor.assumeIsolated {
                guard let self = self,
                      let anchorView = anchorView,
                      let parent = parent,
                      let panel = self.panel
                else { return }
                self.positionPanel(
                    panel, anchorView: anchorView, parent: parent
                )
            }
        }
    }

    /// Hide the panel only if it's currently bound to
    /// `controller`. Used by surfaces that observe their own
    /// visibility state and want to yield the shared panel
    /// without stealing it from whichever surface just took
    /// ownership. Order-independent: a surface that has just
    /// become inactive can call this without risking a teardown
    /// of the newly-active surface's panel.
    public func dismiss(if controller: WebViewFindController) {
        guard currentController === controller else { return }
        dismiss()
    }

    /// Re-position the bar against its anchor, without touching focus.
    ///
    /// For anchors whose own geometry can change while the window's does not
    /// — a pane resized by a split drag, or by a sibling pane opening. The
    /// parent-window resize observer sees neither. Deliberately not routed
    /// through `present`, whose already-showing branch re-keys the panel and
    /// re-selects the field: correct for a ⌘F re-press, focus theft on every
    /// layout pass.
    public func reanchorIfPresenting(
        for controller: WebViewFindController,
        anchorView: NSView
    ) {
        guard currentController === controller,
              panel != nil,
              let parent = anchorView.window else { return }
        reanchor(to: anchorView, in: parent)
    }

    /// Hide the panel and return first responder to whoever
    /// held it before `present` was called.
    public func dismiss() {
        if let observer = resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            resizeObserver = nil
        }

        guard let panel = panel else { return }

        let parent = parentWindow
        let prior = priorParentResponder

        parent?.removeChildWindow(panel)
        panel.orderOut(nil)

        self.panel = nil
        self.hostingView = nil
        self.parentWindow = nil
        self.priorParentResponder = nil
        self.currentController = nil

        if let parent = parent {
            parent.makeKey()
            if let prior = prior {
                _ = parent.makeFirstResponder(prior)
            }
        }
    }

    /// Recompute and apply the panel frame against the current
    /// anchor + parent geometry. Safe to call repeatedly.
    private func reanchor(to anchorView: NSView, in parent: NSWindow) {
        guard let panel = panel else { return }
        // Re-apply appearance in case the parent flipped between
        // light and dark while the panel was visible.
        panel.appearance = parent.effectiveAppearance
        positionPanel(panel, anchorView: anchorView, parent: parent)
    }

    /// Compute screen-space top-right corner of `anchorView` and
    /// place the panel so its top-right corner aligns there
    /// (with our standard insets). Uses `convertToScreen` for the
    /// final transform — child-window positions are in screen
    /// coords.
    private func positionPanel(
        _ panel: NSPanel,
        anchorView: NSView,
        parent: NSWindow
    ) {
        let viewFrameInWindow = anchorView.convert(
            anchorView.bounds, to: nil
        )
        let viewFrameOnScreen = parent.convertToScreen(
            viewFrameInWindow
        )
        let size = panel.frame.size
        let topRightX = viewFrameOnScreen.maxX
            - Self.trailingInset
        let topRightY = viewFrameOnScreen.maxY
            - Self.topInset
        let origin = NSPoint(
            x: topRightX - size.width,
            y: topRightY - size.height
        )
        panel.setFrameOrigin(origin)
    }

    /// Walk the hosting view's subtree to find the first
    /// `NSTextField` and explicitly install it as the panel's
    /// first responder. This sidesteps the timing race between
    /// SwiftUI's `@FocusState`-style binding propagation and
    /// the panel's own key-state transitions, which previously
    /// left the field non-focused on first open. We also
    /// `selectText(:)` the field so a re-open with an existing
    /// query lands the user in a state where they can
    /// immediately retype to overwrite — matching the
    /// re-focus behavior of every native macOS find bar
    /// (Safari, Pages, Finder).
    private func focusFirstTextField(
        in hosting: NSView, panel: NSPanel
    ) {
        guard let field = firstSubview(
            of: NSTextField.self, in: hosting
        ) else { return }
        _ = panel.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func firstSubview<T: NSView>(
        of type: T.Type, in view: NSView
    ) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = firstSubview(of: type, in: sub) {
                return match
            }
        }
        return nil
    }
}
