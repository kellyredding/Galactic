import AppKit

/// Transparent overlay drawn on top of the terminal surface that paints a
/// 1px accent-colored rounded border while a file drag is hovering. Mouse
/// events pass straight through to the terminal underneath, so it is a
/// purely visual drop-zone affordance.
public class DragHighlightView: NSView {
    public var isHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Critical: allow mouse events to pass through to terminal underneath
        layer?.backgroundColor = .clear
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isHighlighted else { return }

        // Draw border highlight with enough inset for clean corners
        // 1px border needs 0.5px inset from edge to render fully inside bounds
        // Plus a little extra margin so corners don't clip against parent edges
        let borderRect = bounds.insetBy(dx: 2, dy: 2)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 3, yRadius: 3)
        borderPath.lineWidth = 1

        // Use system accent color
        NSColor.controlAccentColor.setStroke()
        borderPath.stroke()
    }

    // Allow mouse events to pass through to the terminal view underneath
    public override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
