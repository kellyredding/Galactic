import SwiftUI

/// The Files surface's own settings, minus the application.
///
/// A host supplies a binding to wherever it keeps the value and places this
/// wherever it thinks Files settings belong. Everything else — the label, the
/// range, the stepper, the caption and the zero case — is a statement about file
/// search rather than about an application.
///
/// **The value is per-app; the control is not.** Two applications may
/// legitimately disagree about how much of a file a reader is shown, because
/// that decides a rendering rather than what the corpus holds. They have no
/// reason to disagree about what the stepper allows, and until now they each
/// carried their own copy of the answer.
public struct FilesSettingsView: View {

    @Binding private var searchContextLines: Int

    public init(searchContextLines: Binding<Int>) {
        self._searchContextLines = searchContextLines
    }

    /// What the stepper allows. Zero is meaningful — matching lines only, which
    /// is what grep gives you.
    public static let contextRange: ClosedRange<Int> = 0...10

    public var body: some View {
        SettingsCard(title: "Search") {
            SettingsRow(label: "Lines of context") {
                HStack(spacing: 6) {
                    Text("\(searchContextLines)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: 16, alignment: .trailing)

                    Stepper(
                        "",
                        value: $searchContextLines,
                        in: Self.contextRange
                    )
                    .labelsHidden()

                    Text(
                        searchContextLines == 0
                            ? "Matching lines only"
                            : "Either side of each match"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }
        }
    }
}
