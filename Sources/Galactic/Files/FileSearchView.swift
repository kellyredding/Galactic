import SwiftUI

/// The cross-file search panel.
///
/// A fourth copy of the card-and-scrim shape the picker, the cheat sheet and
/// the go-to-line prompt each spell out. Copied knowingly: extracting it can
/// only be verified by re-QA'ing three working surfaces by hand, because no
/// test in this package instantiates a view body. The presenter half — where
/// the ordering bugs are expensive and a test can reach — was extracted
/// instead, and lives on `ModalFocusCapture.arm`.
///
/// Metrics match `FilePickerView`'s exactly, so the two cards occupy the same
/// rectangle and swapping between them does not move anything.
public struct FileSearchView: View {

    @ObservedObject private var presenter: FileSearchPresenter
    @FocusState private var fieldFocused: Bool

    /// Reads the singleton the host mounts. Not a default argument: a default
    /// expression is evaluated nonisolated, and `.shared` is main-actor.
    @MainActor public init() {
        presenter = .shared
    }

    public init(presenter: FileSearchPresenter) {
        self.presenter = presenter
    }

    public var body: some View {
        ZStack(alignment: .top) {
            scrim
            card
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { fieldFocused = true }
        // Clear the claim first, hand the keyboard back second. Reversing these
        // puts the caret back and then loses it again, because SwiftUI clears
        // first responder when it tears down a field still bound to a focus
        // binding that reads true.
        .onDisappear {
            fieldFocused = false
            presenter.restoreFocus()
        }
    }

    /// Clear rather than dimmed, matching the picker: it exists to catch the
    /// click outside, not to say the surface behind it is unavailable.
    private var scrim: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            field
            Divider()
            status
        }
        .frame(width: Metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .shadow(radius: 20, y: 6)
        .padding(.top, Metrics.topInset)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Search in Files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let root = presenter.root {
                Text(FileTabLabel.relativeOrAbbreviated(root, root: nil))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Find in every file under this folder", text: $presenter.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .onSubmit { presenter.commit() }
            caseToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Case sensitivity, stated on the panel and restated in the results
    /// header, so a surprising result set can be explained without rerunning
    /// it.
    private var caseToggle: some View {
        Button {
            presenter.toggleCaseSensitivity()
        } label: {
            Text("Aa")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            presenter.isCaseSensitive
                                ? Color.accentColor.opacity(0.25) : Color.clear
                        )
                )
                .foregroundStyle(
                    presenter.isCaseSensitive ? .primary : .tertiary
                )
        }
        .buttonStyle(.plain)
        .help(
            presenter.isCaseSensitive
                ? "Matching case. Click to ignore case."
                : "Ignoring case. Click to match case."
        )
        .accessibilityLabel("Match case")
        .accessibilityAddTraits(
            presenter.isCaseSensitive ? [.isSelected, .isButton] : .isButton
        )
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if presenter.isSearching {
                ProgressView()
                    .controlSize(.small)
                Text("Searching…")
            } else if let run = presenter.lastRun {
                Text(summary(of: run))
            } else {
                Text("Return to search")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func summary(of run: FileSearchRun) -> String {
        guard run.wasRootIndexed else { return "Not indexed yet" }
        guard run.matchCount > 0 else { return "No matches" }
        let matches = run.matchCount == 1
            ? "1 match" : "\(run.matchCount.formatted()) matches"
        let files = run.files.count == 1
            ? "1 file" : "\(run.files.count.formatted()) files"
        return "\(matches) in \(files)"
    }

    enum Metrics {
        /// The picker's width, so the two cards are the same rectangle.
        static let width: CGFloat = 640
        static let cornerRadius: CGFloat = 8
        /// A hair below the divider it hangs from.
        static let topInset: CGFloat = 6
    }
}
