import AppKit
import SwiftUI

/// The line-number prompt: one field, and what it will accept.
///
/// Mounted by the host as a top-aligned overlay on the reader, the same way the
/// file picker is, so the field lands where the reader's eye already is. Narrow
/// and short, because it takes a number — sizing this like the picker would
/// suggest a list was coming.
///
/// It draws no dimming. The scrim is clear and exists only to catch a click
/// outside the card: the document behind it is the thing you are looking for a
/// line in, and hiding it would remove the only context that helps.
public struct LineJumpView: View {
    @ObservedObject private var presenter: LineJumpPresenter
    @FocusState private var fieldFocused: Bool

    /// A default argument expression is read in a nonisolated context whatever
    /// the initialiser's isolation, so `= .shared` cannot name main-actor state
    /// and reading it in the body can — the same two-initialiser shape the
    /// picker, the cheat sheet and the inbox all use.
    @MainActor public init() { presenter = .shared }

    public init(presenter: LineJumpPresenter) { self.presenter = presenter }

    public var body: some View {
        ZStack(alignment: .top) {
            scrim
            card
        }
        .onAppear { fieldFocused = true }
        .onDisappear {
            // Cleared *before* restoring: SwiftUI clears first responder when
            // it tears down a field whose focus binding still reads true, which
            // would undo the restore a pass later.
            fieldFocused = false
            presenter.restoreFocus()
        }
    }

    private var scrim: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
    }

    private var card: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField(prompt, text: $presenter.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { presenter.commit() }
            if let line = LineJumpPresenter.line(from: presenter.query) {
                Text("↩ line \(line)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: Metrics.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .shadow(radius: 20, y: 6)
        .padding(.top, Metrics.topInset)
    }

    /// Says how long the file is when the host knows, because that is the
    /// question asked immediately after deciding to jump in it.
    private var prompt: String {
        if let count = presenter.lineCount {
            return "Go to line (1–\(count))"
        }
        return "Go to line"
    }

    enum Metrics {
        static let width: CGFloat = 320
        static let cornerRadius: CGFloat = 10
        static let topInset: CGFloat = 12
    }
}
