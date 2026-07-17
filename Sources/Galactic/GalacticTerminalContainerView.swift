import AppKit

/// Hosts a terminal view full-bleed inside an inset content area.
///
/// SwiftTerm's renderer clips the terminal's leftmost column
/// whenever the terminal view's own frame origin is offset from
/// (0,0) of its immediate superview. Consumers that want visual
/// padding around the terminal therefore must NOT inset the
/// terminal view directly — they inset THIS container instead,
/// which keeps the terminal flush at the origin of a private inner
/// view and moves the padding onto that inner view's position.
///
/// The container fills its host and reserves `contentInsets` of
/// padding around the terminal. The padding region is transparent,
/// so whatever the host paints behind the container shows through
/// as the padded strip. Consumers align their own overlays (drag
/// highlight, scrollback, etc.) to ``contentFrame`` so they cover
/// exactly the same rect the terminal occupies.
public final class GalacticTerminalContainerView: NSView {
    /// The wrapped terminal view, laid out full-bleed inside the
    /// inset content area. Exposed so consumers keep a typed handle
    /// for focus/first-responder wiring.
    public let terminalView: NSView

    /// Padding reserved between the container edge and the terminal.
    /// Uniform in practice, but per-edge for flexibility.
    public var contentInsets: NSEdgeInsets {
        didSet { needsLayout = true }
    }

    /// The inset content rect, in this view's coordinate space —
    /// exactly where the terminal is laid out. Consumers frame their
    /// overlays here. Because the container fills its host at origin
    /// (0,0), this rect is also valid in the host's coordinate space.
    public var contentFrame: NSRect {
        NSRect(
            x: contentInsets.left,
            y: contentInsets.bottom,
            width: max(
                0,
                bounds.width - contentInsets.left - contentInsets.right
            ),
            height: max(
                0,
                bounds.height - contentInsets.top - contentInsets.bottom
            )
        )
    }

    /// Private inner view the terminal fills edge-to-edge. This is
    /// the level that carries the inset offset, so the terminal's
    /// own frame origin stays (0,0) and never triggers the clip.
    private let contentView = NSView()

    public init(
        terminalView: NSView,
        contentInsets: NSEdgeInsets = NSEdgeInsets(
            top: 4, left: 4, bottom: 4, right: 4
        )
    ) {
        self.terminalView = terminalView
        self.contentInsets = contentInsets
        super.init(frame: .zero)

        // Autoresizing is disabled on both nested views so `layout()`
        // stays the single source of truth for their frames.
        contentView.autoresizingMask = []
        addSubview(contentView)

        terminalView.autoresizingMask = []
        contentView.addSubview(terminalView)
    }

    /// Convenience initializer for a uniform inset on all edges.
    public convenience init(
        terminalView: NSView,
        inset: CGFloat
    ) {
        self.init(
            terminalView: terminalView,
            contentInsets: NSEdgeInsets(
                top: inset, left: inset, bottom: inset, right: inset
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        super.layout()
        contentView.frame = contentFrame
        terminalView.frame = contentView.bounds
    }
}
