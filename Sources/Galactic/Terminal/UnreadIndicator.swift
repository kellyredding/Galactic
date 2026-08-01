import SwiftUI

/// The dot a host shows when a surface has attention waiting on it.
///
/// The third of three cues a bell can produce, and the only persistent one:
/// `TerminalVisualBell` pulses the pane once, `VisualBellCadence` flashes a
/// row a few times, and this stays until someone looks. Kept here with them
/// because they are one vocabulary — a host adopting attention signalling wants
/// the set, not one of them.
///
/// Draws only. Whether it appears at all, and where, belongs to the caller:
/// position it with an offset or a `ZStack` alignment, and gate it on both the
/// attention state and whatever setting governs showing it. Both halves of that
/// gate matter — an app whose parents checked only the state ended up drawing a
/// dot that its own preference claimed to have switched off.
public struct UnreadIndicator: View {

    public init() {}

    public var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.2, blue: 0.2))
            .frame(width: 8, height: 8)
            .shadow(
                color: Color.red.opacity(0.6),
                radius: 3,
                x: 0,
                y: 0
            )
    }
}
