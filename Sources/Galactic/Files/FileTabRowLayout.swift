import SwiftUI

/// Places one row's tabs at widths decided before the layout ran.
///
/// **This exists for one line: `sizeThatFits` reports the width it was
/// *offered*, never the width its children add up to.** That is what lets the
/// row spend every point it is given.
///
/// A stack cannot do it. Its size is the sum of its content, so handing the fit
/// a width measured from the row and having the fit spend all of it closes a
/// loop: the content grows to the measurement, the next pass measures the larger
/// content, and — with label widths rounded up — each pass gains a fraction and
/// the layout never settles. MEASURED, when it was a stack: 23,121 frames of
/// recursive `-[NSView _layoutSubtreeWithOldSize:]` on the main thread at ~80%
/// CPU, against 531 frames and idle once the row stopped filling. It hangs the
/// app rather than looking wrong, which is why the fix has to be structural
/// rather than a smaller number somewhere.
///
/// `.frame(maxWidth: .infinity)` is not the same thing and was tried: it changes
/// what a view will *accept*, while its ideal width stays the content sum — so
/// the fixed point is still there for an unspecified proposal to land on.
struct FileTabRowLayout: Layout {

    /// One width per tab, in the order they are placed.
    let widths: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let height = subviews
            .map { $0.sizeThatFits(.unspecified).height }
            .max() ?? 0
        // The offered width, so nothing the placement does can move it. Falling
        // back to the content sum only when nothing was offered at all, which is
        // a sizing question rather than a layout.
        return CGSize(
            width: proposal.width ?? content(subviews.count), height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = self.width(at: index)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func width(at index: Int) -> CGFloat {
        index < widths.count ? widths[index] : 0
    }

    private func content(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return widths.prefix(count).reduce(0, +) + spacing * CGFloat(count - 1)
    }
}
