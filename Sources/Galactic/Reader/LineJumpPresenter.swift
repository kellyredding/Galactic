import Combine
import Foundation

/// The line-number prompt.
///
/// An in-window overlay rather than a panel, unlike the find bar. The find bar
/// stays up while you work through matches, so it earns a window that can hold
/// key on its own; this takes one number and leaves, and an overlay is what
/// `GalacticModals` can see — so every local monitor answering an unmodified key
/// stands down for it without either side knowing about the other.
@MainActor
public final class LineJumpPresenter: ObservableObject {

    public static let shared = LineJumpPresenter()

    @Published public private(set) var isPresented = false
    @Published public var query = ""

    /// The largest line the open document has, when the host knows it.
    ///
    /// Shown rather than enforced. A number past the end lands on the last line,
    /// so this is orientation — the reason to say it is that "how long is this
    /// file" is the question you ask right after deciding to jump in it.
    @Published public private(set) var lineCount: Int?

    /// Where a chosen line goes. Set by the host that owns the reader.
    public var onJump: ((Int) -> Void)?

    /// Internal rather than private, matching its siblings: `ModalFocusCapture`
    /// keeps its note and its monitor internal so a test can assert that the
    /// monitor lives exactly as long as the modal, and that claim is otherwise
    /// unassertable from outside.
    let focus = ModalFocusCapture()

    /// Internal so the package's tests can drive an instance without mutating
    /// the singleton every other test shares. Hosts use `shared`.
    init() {}

    /// Read as a stand-down gate by every monitor answering a bare key, through
    /// `GalacticModals`.
    public static var isClaimingKeyboard: Bool { shared.isPresented }

    public func toggle(lineCount: Int? = nil) {
        isPresented ? dismiss() : present(lineCount: lineCount)
    }

    public func present(lineCount: Int? = nil) {
        guard !isPresented else { return }
        query = ""
        self.lineCount = lineCount
        focus.arm(
            isActive: { [weak self] in self?.isPresented ?? false },
            onEscape: { [weak self] in self?.dismiss() }
        )
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
        focus.disarm()
    }

    /// Called by the view as it disappears, never by `dismiss` — see
    /// `ModalFocusCapture.restore` for why that ordering is the whole argument.
    func restoreFocus() {
        focus.restore()
    }

    /// Take what was typed, if it is a line at all.
    ///
    /// A blank field or anything non-numeric closes without jumping rather than
    /// complaining: the prompt is one keystroke away, so being wrong about it
    /// costs nothing worth a message.
    public func commit() {
        let line = Self.line(from: query)
        dismiss()
        guard let line else { return }
        onJump?(line)
    }

    /// The line a typed string names.
    ///
    /// Zero and below are rejected rather than clamped. Lines are one-based
    /// everywhere they are shown, so a zero is a misunderstanding rather than a
    /// request, and moving the reader in response to one would teach the wrong
    /// thing about what the number means.
    ///
    /// Not actor-bound: it reads a string and answers, and the view asks it once
    /// per keystroke to decide whether to show what Return will do.
    nonisolated static func line(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            trimmed.allSatisfy(\.isWholeNumber),
            let value = Int(trimmed),
            value > 0
        else { return nil }
        return value
    }
}
