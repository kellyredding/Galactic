import SwiftUI

/// One row inside a `SettingsCard`: label on the left, control on the right.
/// The content closure produces the control. The stretching spacer between them
/// keeps the control flush to the right edge of the card.
public struct SettingsRow<Content: View>: View {
    public let label: String
    @ViewBuilder public let content: Content

    public init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        HStack {
            Text(label)
            Spacer()
            content
        }
    }
}
