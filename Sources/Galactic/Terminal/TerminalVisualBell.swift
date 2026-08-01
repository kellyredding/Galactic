import AppKit

/// Pane-pulse visual bell primitive. Overlays a neutral-
/// gray dimming pulse on any `NSView` — rises quickly to
/// `peakOpacity`, then decays back to zero. Pure UI, no
/// state, no coupling to pane type, so the Shell and
/// Session panes share exactly the same look.
///
/// Driven by a single `CAKeyframeAnimation` on layer
/// opacity rather than chained `NSAnimationContext`
/// groups: one Core Animation call gives smoother
/// interpolation and avoids inter-group jitter.
///
/// Neutral 0.5 gray is theme-agnostic (reads as a brief
/// "pane covered" cue over both light and dark
/// backgrounds without fighting either). Sibling-view
/// approach (vs. swapping terminal colors) avoids racing
/// SwiftTerm's render cadence, and `.above`
/// positioning pins the overlay above any caret or
/// child subviews so nothing can peek through during
/// the pulse.
public enum TerminalVisualBell {
    /// Total duration of the pulse (rise + fall). Long
    /// enough to feel like a deliberate pulse rather
    /// than a snap, short enough to stay crisp.
    public static let duration: TimeInterval = 0.20

    /// Peak opacity at the top of the pulse curve.
    /// Dimmer than a snap-in overlay because a pulse
    /// gives the eye more time to register the flash,
    /// so it doesn't need to shout.
    public static let peakOpacity: Float = 0.25

    /// Fraction of the total duration at which the
    /// pulse reaches peak. Quick rise (25%), longer
    /// decay (75%) — feels more like a pulse than a
    /// symmetric triangle.
    public static let peakFraction: Double = 0.25

    /// Pulse a neutral-gray overlay across `target` and
    /// remove it when the animation completes. Safe to
    /// call from the main thread during live UI; the
    /// overlay does not intercept hit testing for user
    /// input (`NSView` default passes through when no
    /// gesture is attached).
    public static func pulse(over target: NSView) {
        let flash = NSView(frame: target.bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.gray.cgColor
        flash.autoresizingMask = [.width, .height]
        // Base layer opacity is 0 — the animation
        // overlays the temporary pulse curve, and when
        // the animation ends the layer snaps back to 0
        // (invisible) before `removeFromSuperview` fires,
        // so there's no end-of-pulse flicker.
        flash.layer?.opacity = 0
        target.addSubview(
            flash, positioned: .above, relativeTo: nil
        )

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, peakOpacity, 0]
        anim.keyTimes = [
            0,
            NSNumber(value: peakFraction),
            1
        ]
        anim.duration = duration
        // Ease-out on the rise so the pulse pops in
        // crisply; ease-in on the fall so the tail feels
        // gentle rather than cliff-edged.
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        flash.layer?.add(anim, forKey: "pulse")

        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration
        ) {
            flash.removeFromSuperview()
        }
    }
}
