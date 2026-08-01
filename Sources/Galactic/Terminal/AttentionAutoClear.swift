import SwiftUI

/// Clears a surface's pending attention once the user is demonstrably looking
/// at it.
///
/// The mirror of whatever sets that attention, and deliberately expressed
/// against the same predicate: something is worth flagging when the surface is
/// *not* being viewed, and worth forgetting when it is. Hosts that spell those
/// two conditions separately drift, which is what happened to the app this came
/// from — one predicate written three ways in the setters and a fourth way here.
///
/// `isBeingViewed` is the host's judgement, because what it takes to be looking
/// at something is a property of the host's own chrome. One app means "this
/// session is selected, its window has focus, and the terminal tab is
/// frontmost"; another with a single session and no tabs means something much
/// simpler. Collapsing all of that to one Bool before it arrives is what lets
/// the triggers below be three rather than one per input.
struct AttentionAutoClear: ViewModifier {

    let isBeingViewed: Bool
    let hasAttention: Bool
    let clear: () -> Void

    private func clearIfNeeded() {
        guard isBeingViewed, hasAttention else { return }
        clear()
    }

    func body(content: Content) -> some View {
        content
            .onAppear { clearIfNeeded() }
            .onChange(of: isBeingViewed) { _, _ in clearIfNeeded() }
            .onChange(of: hasAttention) { _, nowHasAttention in
                // Attention arriving while the surface is already being watched
                // needs a second look on the next tick. The set can land just
                // after the focus and selection state has settled, so the
                // change that would have cleared it has already been observed
                // and will not fire again.
                guard nowHasAttention, isBeingViewed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    clearIfNeeded()
                }
            }
    }
}

public extension View {

    /// Clear `hasAttention` — by calling `clear` — as soon as this surface is
    /// being viewed, and again a tick later if attention arrives while it
    /// already is.
    ///
    /// Apply this to whatever draws the cue rather than to one place per
    /// surface: several views may render the same pending attention, and any of
    /// them becoming visible is evidence the user saw it.
    func attentionAutoClear(
        isBeingViewed: Bool,
        hasAttention: Bool,
        clear: @escaping () -> Void
    ) -> some View {
        modifier(
            AttentionAutoClear(
                isBeingViewed: isBeingViewed,
                hasAttention: hasAttention,
                clear: clear
            )
        )
    }
}
