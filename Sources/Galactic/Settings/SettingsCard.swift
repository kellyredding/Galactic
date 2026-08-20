import SwiftUI

/// Grouped section in a settings tab. Title above, content in a rounded
/// control-background box below. One card per logical grouping of related
/// settings.
///
/// The box stretches to the full available width (leading-aligned content) so
/// cards read as a consistent left-justified column regardless of how wide
/// their content is. Cards whose content already fills the width via a
/// `SettingsRow` spacer are unaffected; cards with a single narrow control
/// would otherwise shrink to hug the control and get centred by the parent
/// stack.
///
/// Shared so that a settings surface built here looks native in whichever
/// application places it. An application that wants a different look keeps its
/// own card type: Swift resolves a same-named type in the application's own
/// module ahead of this one, so nothing is forced to adopt it.
public struct SettingsCard<Content: View>: View {
    /// Optional section title above the box. Omit it for a bare card.
    public var title: String?
    @ViewBuilder public let content: Content

    public init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 12)
                    .padding(.bottom, 6)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}
