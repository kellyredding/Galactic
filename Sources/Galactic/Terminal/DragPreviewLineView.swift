import SwiftUI

/// Ghost line shown while a pane divider is being dragged: one thin line at
/// the proposed divider, with a small label near the trailing edge.
///
/// Rendered over panes still laid out at their committed ratio, so neither
/// terminal reflows until the drag commits.
///
/// Both line and label use `Color.primary`, which resolves to white on dark
/// and black on light without either app supplying a colour.
public struct DragPreviewLineView: View {

    /// Percentage of the height the *bottom* pane would take — the number the
    /// user is actually dragging toward. Callers hold the top-pane ratio, so
    /// this is its complement.
    public let shellPercentage: Int

    public init(shellPercentage: Int) {
        self.shellPercentage = shellPercentage
    }

    public var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.85))
            .overlay(
                Text("Shell \(shellPercentage)%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.primary.opacity(0.85))
                    .fixedSize()
                    .padding(.trailing, 10)
                    .offset(y: -14),
                alignment: .trailing
            )
    }
}
