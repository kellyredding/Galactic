import Foundation

/// How a file is being read.
///
/// Only `source` is produced today. The case pair exists now because the mode
/// has to be per-file rather than per-surface — a reader flipping one markdown
/// file to rendered is not saying anything about the next one — and retrofitting
/// that dimension later would mean touching every place a tab is created.
public enum FileViewMode: String, Equatable, Sendable {
    /// Line-numbered, highlighted, anchored by line. What every text file gets.
    case source
    /// The kind's own renderer, anchored however that renderer anchors. Not yet
    /// reachable; the toggle that offers it is deliberately last.
    case rendered
}

/// One open file, and everything the reader left in it.
///
/// The state here is what makes a single shared reader work. Switching files
/// rebuilds the page, so anything not recorded on the tab is gone — which is
/// why scroll position, the find query and the half-written composer all live
/// here rather than in the view. A tab is the memory; the reader is just the
/// window currently pointed at one.
public struct FileTab: Identifiable, Equatable {
    public let id: UUID
    public let url: URL

    /// Where the reader had scrolled to. Net new — no reader captured this
    /// before, because none of them was ever rebuilt for a different document.
    public var scrollOffset: Double

    /// The find bar's query and position, so ⌘F picks up where it left off
    /// rather than starting over on every switch.
    public var findQuery: String
    public var findMatchIndex: Int

    /// The page's own rescued composer state, verbatim as it reported it.
    ///
    /// Opaque here on purpose: what a half-written card consists of is the
    /// page's business, and parsing it to store it would make this file a
    /// second place that knows. The one part that is *not* per-file — the send
    /// bar's overall comment — is lifted out by `ComposerStateMerge` before
    /// this is filed, because that belongs to the review rather than to any
    /// one file in it.
    public var composerState: String?

    public var viewMode: FileViewMode

    public init(
        id: UUID = UUID(),
        url: URL,
        scrollOffset: Double = 0,
        findQuery: String = "",
        findMatchIndex: Int = 0,
        composerState: String? = nil,
        viewMode: FileViewMode = .source
    ) {
        self.id = id
        self.url = url
        self.scrollOffset = scrollOffset
        self.findQuery = findQuery
        self.findMatchIndex = findMatchIndex
        self.composerState = composerState
        self.viewMode = viewMode
    }

    /// The store and the composer both key on this.
    public var path: String { url.path }
}
