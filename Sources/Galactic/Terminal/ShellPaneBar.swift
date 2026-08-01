import AppKit
import SwiftUI

/// The bar above a shell pane. Shows a "Shell" label and terminal icon
/// centered, doubles as the divider drag handle, and resets the split on
/// double-click.
///
/// Drag tracking goes through an AppKit view rather than a SwiftUI
/// `DragGesture`, which gives unreliable cursor feedback and double-click
/// handling for a divider this thin. Resize handles elsewhere are built the
/// same way for the same reason.
///
/// Sized by its caller — the 28pt height is the host's frame, not this view's
/// — so an app wanting a different bar height changes a number rather than
/// this file.
public struct ShellPaneBar: NSViewRepresentable {

    /// Fired once when a drag begins (a mouseDown that isn't a double-click).
    ///
    /// The split container is expected to enter a drag-preview mode: the panes
    /// hold their current heights while a ghost line tracks the proposed
    /// divider. Resizing live instead would reflow both terminal buffers on
    /// every tick of the drag.
    private let onDragBegan: () -> Void

    /// Fired repeatedly during a drag with the cursor's Y delta from
    /// drag-start, in screen coordinates — positive means the cursor moved up.
    ///
    /// Screen coordinates rather than view-local, because the view being
    /// dragged is the one whose position the drag is deciding: a local delta
    /// would be measured against a moving origin.
    private let onDrag: (CGFloat) -> Void

    /// Fired once on mouseUp. Committing collapses the ghost line and snaps
    /// the panes to the new ratio in a single resize.
    private let onDragEnded: () -> Void

    /// Fired on double-click, for callers that reset the split ratio.
    private let onResetSplit: () -> Void

    public init(
        onDragBegan: @escaping () -> Void,
        onDrag: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void,
        onResetSplit: @escaping () -> Void
    ) {
        self.onDragBegan = onDragBegan
        self.onDrag = onDrag
        self.onDragEnded = onDragEnded
        self.onResetSplit = onResetSplit
    }

    public func makeNSView(context: Context) -> ShellPaneBarNSView {
        let view = ShellPaneBarNSView()
        view.onDragBegan = onDragBegan
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
        view.onResetSplit = onResetSplit
        return view
    }

    public func updateNSView(
        _ nsView: ShellPaneBarNSView, context: Context
    ) {
        nsView.onDragBegan = onDragBegan
        nsView.onDrag = onDrag
        nsView.onDragEnded = onDragEnded
        nsView.onResetSplit = onResetSplit
    }
}

/// The AppKit view behind `ShellPaneBar`.
///
/// Public only because it is the representable's view type, which a public
/// `NSViewRepresentable` has to expose. Nothing outside constructs one.
public final class ShellPaneBarNSView: NSView {
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onResetSplit: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragStartY: CGFloat = 0
    private var isDragging = false

    // Stored so their cgColor values can be re-resolved when the effective
    // appearance changes. Layer-backed cgColors are frozen at set time and
    // don't track dynamic NSColors.
    private let topLine = NSView()
    private let bottomLine = NSView()

    private let iconView: NSImageView = {
        let img = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Shell"
        )
        let v = NSImageView(image: img ?? NSImage())
        v.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let labelField: NSTextField = {
        let field = NSTextField(labelWithString: "Shell")
        field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        topLine.wantsLayer = true
        topLine.translatesAutoresizingMaskIntoConstraints = false

        bottomLine.wantsLayer = true
        bottomLine.translatesAutoresizingMaskIntoConstraints = false

        // Applied once now, and again on every appearance change below.
        applyAppearanceColors()

        let stack = NSStackView(views: [iconView, labelField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topLine)
        addSubview(bottomLine)
        addSubview(stack)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leftAnchor.constraint(equalTo: leftAnchor),
            topLine.rightAnchor.constraint(equalTo: rightAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomLine.leftAnchor.constraint(equalTo: leftAnchor),
            bottomLine.rightAnchor.constraint(equalTo: rightAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),

            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        if !isDragging {
            NSCursor.resizeUpDown.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onResetSplit?()
            return
        }
        isDragging = true
        dragStartY = NSEvent.mouseLocation.y
        NSCursor.resizeUpDown.set()
        onDragBegan?()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let delta = NSEvent.mouseLocation.y - dragStartY
        onDrag?(delta)
    }

    public override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        isDragging = false
        NSCursor.arrow.set()
        if wasDragging {
            onDragEnded?()
        }
    }

    // MARK: - Dark/light appearance

    /// macOS toggles `effectiveAppearance` when the user switches between
    /// light and dark mode. Layer-backed cgColors don't track dynamic
    /// NSColors, so they are re-resolved here to keep the bar readable.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    /// Resolve theme-aware colors for the bar background and its border lines
    /// under the current effective appearance.
    ///
    /// The background is fully opaque so a stopped session's backdrop can't
    /// bleed through when the shell pane is expanded above it; the borders use
    /// the semantic separator tint, which adapts light to dark on its own.
    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor =
                NSColor.windowBackgroundColor.cgColor
            let borderColor = NSColor.separatorColor.cgColor
            self.topLine.layer?.backgroundColor = borderColor
            self.bottomLine.layer?.backgroundColor = borderColor
        }
    }
}
