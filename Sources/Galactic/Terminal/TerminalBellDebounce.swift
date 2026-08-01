import Foundation

/// Collapses a burst of bells into a single perceived one.
///
/// A terminal rings far faster than anything done in response can finish —
/// holding backspace at the start of a line produces a stream of them. Ungated,
/// the sound stacks on itself, flash overlays pile up, and a notification fires
/// per byte.
///
/// The gate belongs around the whole response rather than around any one part
/// of it. Gating only the flash leaves sound and notifications free to stack,
/// which is the arrangement this replaced.
///
/// The window is supplied by the caller, because what counts as *one* bell
/// depends on what that caller does about it: a pane that pulses once needs the
/// length of the pulse, while a pipeline that runs a multi-flash cadence and
/// posts a notification needs the length of the whole sequence. A window
/// shorter than the response is the failure mode to avoid — a second bell then
/// starts while the first is still on screen, which is exactly what gating was
/// for.
public final class TerminalBellDebounce {

    private let window: TimeInterval
    private var isInFlight = false

    public init(window: TimeInterval) {
        self.window = window
    }

    /// Run `body` unless an earlier run is still inside the window.
    ///
    /// Hops to the main queue before reading the gate, so callers do not each
    /// have to reason about which thread the engine delivered a bell on, and so
    /// the flag is only ever touched from one place — which is why it needs no
    /// lock.
    ///
    /// The window is measured from the run that was *accepted*, not from the
    /// most recent attempt. A continuous stream of bells therefore produces one
    /// response per window rather than silence, which it would if every dropped
    /// attempt pushed the deadline out.
    public func fire(_ body: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isInFlight else { return }
            self.isInFlight = true
            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.window
            ) { [weak self] in
                self?.isInFlight = false
            }
            body()
        }
    }
}
