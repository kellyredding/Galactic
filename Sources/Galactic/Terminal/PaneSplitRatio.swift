import CoreGraphics

/// How far a pane divider may travel, as a window on the *top* pane's share.
///
/// One window governs two things that must agree: what a live drag allows, and
/// what a configured default is allowed to be. Both apps previously kept their
/// own copy of the numbers, and both wrote a comment saying the copy had to
/// match the drag — which is the shape of a constraint that has no single owner.
///
/// Expressed as the top pane's share because that is what a drag computes. The
/// bottom pane's window is derived rather than stated, and deriving it is
/// load-bearing: the two coincide only while the window is symmetric about the
/// middle, so a stated pair would silently stop agreeing the first time it
/// isn't.
public struct PaneSplitBounds {

    /// Tightest allowed top-pane share. Below this the top pane is too small
    /// to be useful, so a drag parks here rather than continuing.
    public let minRatio: CGFloat

    /// Loosest allowed top-pane share. Above this the bottom pane is too small
    /// to type into.
    public let maxRatio: CGFloat

    /// The window both apps use: no pane below 30% or above 70%.
    public static let standard = PaneSplitBounds(
        minRatio: 0.30, maxRatio: 0.70
    )

    /// Orders the pair rather than trusting it.
    ///
    /// Inverted bounds do not fail loudly downstream — clamping with a minimum
    /// above its maximum pins every ratio to the maximum, so the divider simply
    /// stops moving and nothing says why.
    public init(minRatio: CGFloat, maxRatio: CGFloat) {
        self.minRatio = min(minRatio, maxRatio)
        self.maxRatio = max(minRatio, maxRatio)
    }

    /// The same window seen from the bottom pane, for settings that configure
    /// the bottom pane's share directly.
    ///
    /// `Double` because settings storage and the controls bound to it work in
    /// `Double`, and a `ClosedRange` will not convert implicitly the way a
    /// scalar does.
    public var bottomRange: ClosedRange<Double> {
        Double(1.0 - maxRatio)...Double(1.0 - minRatio)
    }
}

/// Where the divider sits between two stacked panes, including mid-drag.
///
/// Holds two ratios rather than one: the committed position, and the proposed
/// one while a drag is in flight. Keeping them apart is what lets the panes
/// stay put while a ghost line tracks the cursor — resizing live would reflow
/// both terminal buffers on every tick of the drag.
///
/// A value type so a host can publish it as one property and have every
/// mutation announce itself, rather than keeping three published properties in
/// step by hand. The ratio measures the *top* pane's share.
public struct PaneSplitRatio {

    /// The committed top-pane fraction — what the panes are actually laid out
    /// to. Settable, because a host resets it from configuration on a
    /// double-click and on opening the second pane.
    public var ratio: CGFloat

    /// The proposed fraction while a drag is in flight, or nil when no drag is
    /// in progress.
    ///
    /// Deliberately stays nil until the first movement, so a click that never
    /// becomes a drag commits nothing.
    public private(set) var previewRatio: CGFloat?

    /// The committed ratio captured at drag start.
    ///
    /// Every update computes from this rather than from the running preview.
    /// Computing from the preview instead compounds: each tick's delta lands on
    /// top of the previous frame's adjustment, so the divider accelerates away
    /// from the cursor and the two part company.
    private var startRatio: CGFloat?

    public init(ratio: CGFloat = 0.5) {
        self.ratio = ratio
    }

    /// Begin a drag, remembering where the divider started.
    public mutating func beginDrag() {
        startRatio = ratio
    }

    /// Update the proposed ratio from the cursor's Y delta since drag start.
    ///
    /// The delta is in screen coordinates, so a positive value means the cursor
    /// moved up — which shrinks the top pane and grows the bottom one.
    ///
    /// Clamped to `bounds`, so moving past a threshold parks the preview at the
    /// boundary instead of continuing into a layout neither pane can use.
    ///
    /// A no-op before `beginDrag`, and for a zero height — there is no ratio to
    /// compute against in either case.
    public mutating func updateDrag(
        cursorDeltaY: CGFloat,
        totalHeight: CGFloat,
        bounds: PaneSplitBounds
    ) {
        guard totalHeight > 0, let startRatio else { return }
        let newTop = (startRatio * totalHeight) - cursorDeltaY
        let rawRatio = newTop / totalHeight
        previewRatio = min(
            max(rawRatio, bounds.minRatio), bounds.maxRatio
        )
    }

    /// Commit the drag, applying the proposed ratio in one step so both panes
    /// reflow once rather than on every tick, and clearing the drag state.
    ///
    /// A click that never moved leaves the committed ratio untouched, because
    /// there is no proposal to apply.
    public mutating func commitDrag() {
        if let previewRatio {
            ratio = previewRatio
        }
        startRatio = nil
        previewRatio = nil
    }

    /// The committed ratio held inside `bounds`.
    ///
    /// Applied at layout rather than at assignment so a stored ratio from
    /// configuration — or from a previous run with different bounds — cannot
    /// lay out a pane smaller than the drag would allow.
    public func clamped(to bounds: PaneSplitBounds) -> CGFloat {
        min(max(ratio, bounds.minRatio), bounds.maxRatio)
    }

    /// The top-pane share implied by a configured *bottom*-pane share.
    ///
    /// Settings name the bottom pane, because that is the one a user opens and
    /// sizes; layout needs the top. Clamping happens on the way through, so a
    /// stored value from a build with a different window cannot ask for a
    /// layout the drag would refuse.
    public static func topRatio(
        forBottomRatio bottomRatio: Double,
        within bounds: PaneSplitBounds
    ) -> CGFloat {
        let allowed = bounds.bottomRange
        let clamped = min(
            max(bottomRatio, allowed.lowerBound), allowed.upperBound
        )
        return CGFloat(1.0 - clamped)
    }
}
