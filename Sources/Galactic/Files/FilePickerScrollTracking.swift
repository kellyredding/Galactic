import SwiftUI

/// Which row is at the top of a scrolling list.
///
/// ### Why each row reports itself
///
/// The obvious version measures the *content* once — one `GeometryReader` in the
/// list's background, reading its offset against the scroll view's coordinate
/// space — and it does not work. **Measured:** it reports `0.0` forever, firing
/// only when the row count changes and never when the list is scrolled. Three
/// attempts at restoring a scroll position were built on that number, and each
/// one "restored" to row zero, because row zero is what an offset of nought
/// resolves to.
///
/// A row's own geometry does move when the row moves. So each row reports its
/// position and the topmost one wins — and because `LazyVStack` only builds the
/// rows it is showing, that is a dozen or two readers rather than one per entry
/// in a tree of thousands.
struct TopVisibleRow: Equatable {
    let id: String
    /// Distance from the top of the viewport. Negative once the row has passed
    /// above it.
    let y: CGFloat
}

/// The row nearest the top edge, reduced across whichever rows are built.
struct TopRowPreference: PreferenceKey {
    static let defaultValue: TopVisibleRow? = nil

    static func reduce(
        value: inout TopVisibleRow?, nextValue: () -> TopVisibleRow?
    ) {
        guard let next = nextValue() else { return }
        guard let current = value else {
            value = next
            return
        }
        // Nearest the top edge, from either side of it: the first row of a
        // part-scrolled list sits slightly above zero, and the row after it
        // slightly below, so the smaller distance is the one a reader would
        // call the top row.
        value = abs(next.y) < abs(current.y) ? next : current
    }
}

extension View {
    /// Report this row's position within `space`, for `TopRowPreference`.
    ///
    /// A background rather than a wrapper, so it cannot affect the row's own
    /// size — a `GeometryReader` in the layout would take all the height it was
    /// offered and the rows would collapse.
    func reportingTopRow(id: String, in space: String) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TopRowPreference.self,
                    value: TopVisibleRow(
                        id: id, y: geometry.frame(in: .named(space)).minY
                    )
                )
            }
        )
    }
}
