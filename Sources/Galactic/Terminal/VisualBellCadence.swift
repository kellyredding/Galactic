import Foundation

/// The on/off rhythm a persistent attention flash follows.
///
/// Distinct from `TerminalVisualBell`, which pulses a pane once and is over.
/// This is the slower, repeating cue a host renders somewhere the user is
/// likely to be looking *away* from the pane — a sidebar row, a tab. Three
/// deliberate flashes read as "something wants you" where one reads as a
/// glitch.
///
/// Emits state rather than drawing anything, because where the flash appears
/// and what it looks like belong to the host: one app tints a selected sidebar
/// row, another might badge a tab or do nothing at all. What is shared is the
/// rhythm, which is the part that would drift if each app kept its own.
///
/// A value rather than a set of static constants so `totalDuration` and `run`
/// can never disagree. Anything gating on the length of a bell — a debounce
/// window, most obviously — needs exactly this number, and computing it by hand
/// somewhere else is how it ends up wrong: the arrangement this replaced had a
/// literal in one file and a doc comment in another claiming a figure 100ms off
/// the arithmetic.
public struct VisualBellCadence {

    /// How long each flash stays lit.
    public let flashDuration: TimeInterval

    /// Dark interval between consecutive flashes.
    public let gapDuration: TimeInterval

    /// How many times to flash.
    public let flashCount: Int

    /// The cadence both apps use.
    public static let standard = VisualBellCadence()

    public init(
        flashCount: Int = 3,
        flashDuration: TimeInterval = 0.375,
        gapDuration: TimeInterval = 0.1
    ) {
        self.flashCount = flashCount
        self.flashDuration = flashDuration
        self.gapDuration = gapDuration
    }

    /// End-to-end length of the sequence: every flash, plus the gaps between
    /// them but not a trailing one.
    ///
    /// This is the number a bell gate should be sized to, so that a second bell
    /// cannot begin while the first is still visibly running.
    public var totalDuration: TimeInterval {
        guard flashCount > 0 else { return 0 }
        return (flashDuration * Double(flashCount))
            + (gapDuration * Double(flashCount - 1))
    }

    /// Drive `setActive` through the sequence, ending false.
    ///
    /// Scheduled on the main queue in one pass rather than chained, so a slow
    /// frame delays a flash without shortening the ones after it — the rhythm
    /// is what the cue conveys, and a sequence that compresses under load
    /// stops reading as deliberate.
    ///
    /// **Not cancellable, and with no protection against overlapping itself.**
    /// Two runs against one target fight over the state, and the second's final
    /// `false` can land while the first still means to be lit. A caller must not
    /// start a run while one is going — which is normally free, because whatever
    /// gates the bell is already sized to `totalDuration` and cannot admit a
    /// second bell inside the first's sequence. That dependency runs both ways:
    /// the gate takes its length from here, and this relies on the gate to be at
    /// least that long.
    ///
    /// Capture weakly if the thing being flashed can be torn down. The sequence
    /// outlives its own scheduling by `totalDuration`, so a strong capture keeps
    /// the target alive to finish flashing something nobody is looking at.
    public func run(_ setActive: @escaping (Bool) -> Void) {
        var delay: TimeInterval = 0

        for index in 0..<flashCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                setActive(true)
            }
            delay += flashDuration

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                setActive(false)
            }

            if index < flashCount - 1 {
                delay += gapDuration
            }
        }
    }
}
