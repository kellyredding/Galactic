import AppKit
import Combine
import SwiftUI
import WebKit

/// The Files surface: the strip of open files, and one reader under it.
///
/// **One reader, rebuilt on every file switch.** Not one web view per tab — that
/// would keep each tab's scroll position for free and cost a web view per open
/// file, which is a memory cliff at thirty tabs. What the reader would have
/// remembered is kept on the tab instead, and the rebuild path already exists
/// because a theme change takes the same route.
///
/// A host supplies the set to show, whether this surface is the one in front,
/// and three publishers for the keystrokes its menu owns. Everything else —
/// the overlays, the reader dispatch, the find bar, the escape ladder, the empty
/// state — is the same in every host and lives here.
public struct FilesPaneView: View {

    private let surface: FilesSurface
    @ObservedObject private var set: FileSet

    /// Whether this pane is the surface in front of the user.
    ///
    /// Passed down rather than read here: a host's panes may all stay mounted
    /// behind an opacity switch, so "is my view in the hierarchy" is not the
    /// same question. `ReaderHostView` needs the real answer to stop answering
    /// zoom chords from a surface nobody is looking at.
    private let isVisibleSurface: Bool

    /// True when something the host owns is covering this surface.
    ///
    /// One application puts a full-pane item viewer over Files; the other has
    /// nothing of the kind. A closure rather than a flag so the host that has
    /// none simply never says yes.
    private let isObscuredByHost: () -> Bool

    private let findActivations: AnyPublisher<Void, Never>
    private let lineJumpActivations: AnyPublisher<Void, Never>
    private let searchActivations: AnyPublisher<Void, Never>

    /// What the empty state suggests pressing.
    ///
    /// The only string here that names a keystroke, and a keystroke is the one
    /// thing about this surface a host really does own — it lives in that host's
    /// menu and its cheat sheet. Hosts that agree on ⌘T pass the same thing;
    /// nothing here assumes they do.
    private let emptyHint: String?

    @ObservedObject private var picker = FilePickerPresenter.shared
    @ObservedObject private var lineJump = LineJumpPresenter.shared
    @ObservedObject private var searcher = FileSearchPresenter.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var webViewRef: WKWebView?
    @State private var escapeMonitor: Any?

    /// What the Escape monitor reads instead of this struct's own properties.
    ///
    /// **A local monitor outlives the view value that installed it.** Its
    /// closure captures the `FilesPaneView` present at `onAppear`, and a SwiftUI
    /// view struct is a snapshot — so a captured `isVisibleSurface` stays
    /// whatever it was when the pane first mounted, which for a pane behind an
    /// opacity switch is `false` for the life of the process. Escape then never
    /// reached the composer at all.
    ///
    /// The host this was extracted from read a singleton live and so never hit
    /// this. The question was the same; the mechanism was not.
    @State private var gate = EscapeGate()

    /// Find within the open file.
    ///
    /// Forward, unlike a scrollback's, which searches backwards because its
    /// interesting end is the bottom. A file is read from the top.
    @StateObject private var findController = WebViewFindController(
        webView: nil, reverse: false
    )

    public init(
        surface: FilesSurface,
        set: FileSet,
        isVisibleSurface: Bool,
        isObscuredByHost: @escaping () -> Bool = { false },
        findActivations: AnyPublisher<Void, Never>,
        lineJumpActivations: AnyPublisher<Void, Never>,
        searchActivations: AnyPublisher<Void, Never>,
        emptyHint: String? = nil
    ) {
        self.surface = surface
        self.set = set
        self.isVisibleSurface = isVisibleSurface
        self.isObscuredByHost = isObscuredByHost
        self.findActivations = findActivations
        self.lineJumpActivations = lineJumpActivations
        self.searchActivations = searchActivations
        self.emptyHint = emptyHint
    }

    private var isDark: Bool { colorScheme == .dark }

    public var body: some View {
        VStack(spacing: 0) {
            FileTabStripView(
                set: set,
                onSelect: { surface.select(id: $0) },
                onClose: { surface.close(id: $0) },
                onReload: { surface.reload(id: $0) },
                onRearrange: { surface.rearrange(to: $0) }
            )
            Divider()
            reader
                // Anchored under the strip rather than floating at the window
                // root, which is where an editor's go-to-file panel sits: the
                // field appears where the reader's eye already is, and the list
                // grows down over the document it is about to replace.
                // **Gated on visibility, not just on the presenter.** The
                // presenters are process singletons and a host may mount one of
                // these panes per session, all of them alive behind an opacity
                // switch — so an ungated overlay puts N copies of one card on
                // screen, each with its own `@FocusState`, each focusing its
                // field on appear. The last to mount takes first responder, and
                // it is one nobody can see: the visible card renders with an
                // empty-looking field and the keystroke reads as dead.
                .overlay(alignment: .top) {
                    if isVisibleSurface, picker.isPresented {
                        FilePickerView().transition(.opacity)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.12), value: picker.isPresented
                )
                // Its own overlay rather than a branch of the picker's: the two
                // are never up together, but sharing one would make the
                // animation value a two-state expression and the transition
                // cross-fade one card into the other.
                .overlay(alignment: .top) {
                    if isVisibleSurface, lineJump.isPresented {
                        LineJumpView().transition(.opacity)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.12), value: lineJump.isPresented
                )
                // Third overlay, same reasoning as the second.
                .overlay(alignment: .top) {
                    if isVisibleSurface, searcher.isPresented {
                        FileSearchView().transition(.opacity)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.12), value: searcher.isPresented
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            gate.isVisibleSurface = isVisibleSurface
            installEscapeMonitor()
            claimReaderFocus()
        }
        .onDisappear {
            removeEscapeMonitor()
            FindBarPanelController.shared.dismiss(if: findController)
        }
        .onReceive(findActivations) { _ in activateFind() }
        .onReceive(lineJumpActivations) { _ in activateLineJump() }
        .onReceive(searchActivations) { _ in surface.presentSearcher() }
        .onChange(of: webViewRef) { _, view in
            findController.bind(to: view)
            claimReaderFocus()
        }
        // A query belongs to the file it was typed against, so switching files
        // takes the bar down rather than carrying a search into a document that
        // was never asked about it.
        .onChange(of: set.tabs.selectedID) { _, _ in
            persistFindState()
            findController.isVisible = false
        }
        .onChange(of: findController.isVisible) { _, _ in syncFindBarPanel() }
        .onChange(of: isVisibleSurface) { _, visible in
            gate.isVisibleSurface = visible
            claimReaderFocus()
            syncFindBarPanel()
        }
    }

    /// Put first responder in the reader while this is the surface in front.
    ///
    /// **Nothing else will.** A host that releases another pane's claim on a tab
    /// change leaves the window with no first responder at all, and the page
    /// needs one before Return can reach the annotation layer — which is what
    /// turns a selection into a note. Without this a reader who arrived from a
    /// terminal tab selected lines, pressed Return, and found the newlines had
    /// gone to a terminal they were no longer looking at.
    ///
    /// It also fixes what the panels capture. The line jump records the
    /// responder at `present()` and hands the keyboard back to it at dismiss, so
    /// a stale one from another tab is what a jump would restore to — which is
    /// the same fault seen from the other end.
    ///
    /// Stands aside for a panel: its field is the innermost surface and has
    /// already claimed the caret. Deferred a turn for the reason `claimField`
    /// is, and re-reads the gate rather than the captured value, because a view
    /// struct is a snapshot and the tab may have moved on.
    private func claimReaderFocus() {
        guard !GalacticModals.filesPanelIsClaimingKeyboard else { return }
        DispatchQueue.main.async {
            guard gate.isVisibleSurface, let webView = webViewRef else {
                return
            }
            webView.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Find

    /// Bring up the find bar over the open file.
    ///
    /// Silent on an image and on an empty tab: there is no text to search, and a
    /// bar that opens onto nothing is worse than a key that appears not to fire.
    private func activateFind() {
        guard isVisibleSurface, !isObscuredByHost(),
            let tab = set.selectedTab,
            let file = set.file(forPath: tab.path),
            !FileKind.isImage(file.url.lastPathComponent)
        else { return }
        findController.query = tab.findQuery
        findController.isVisible = true
        // Called directly as well as observed, because the change handler only
        // fires on a transition — pressing the key while the bar is already up
        // has to re-present in order to put the caret back in the field.
        syncFindBarPanel()
    }

    /// Show or hide the shared bar for this reader.
    ///
    /// Self-gating, and `dismiss(if:)` is a no-op when the panel belongs to
    /// another controller — so this is safe to call from any observer without
    /// racing whichever surface just took it.
    private func syncFindBarPanel() {
        guard isVisibleSurface, findController.isVisible,
            let anchor = webViewRef
        else {
            FindBarPanelController.shared.dismiss(if: findController)
            return
        }
        FindBarPanelController.shared.present(
            controller: findController, anchorView: anchor
        )
    }

    /// Keep the query with the tab it was typed against.
    ///
    /// Written on the way out rather than on every keystroke: the controller
    /// debounces, and a tab is only interesting to store when it stops being the
    /// one on screen.
    private func persistFindState() {
        guard let id = set.tabs.selectedID else { return }
        let query = findController.query
        surface.updateTab(id: id) { $0.findQuery = query }
    }

    // MARK: - Go to line

    /// Ask for a line number, then scroll to it.
    ///
    /// The line count goes in so the prompt can say how long the file is, which
    /// is the question asked immediately after deciding to jump in it. Counted
    /// from the content already in memory rather than from the page, because the
    /// reader is showing a snapshot the tab loaded and that is what is numbered.
    private func activateLineJump() {
        guard isVisibleSurface, !isObscuredByHost(),
            let tab = set.selectedTab,
            let file = set.file(forPath: tab.path),
            file.kind != .image
        else { return }
        lineJump.onJump = { jump(to: $0) }
        lineJump.present(
            lineCount: file.content.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
        )
    }

    private func jump(to line: Int) {
        webViewRef?.evaluateJavaScript(
            ReaderLineJump.javaScript(
                line: line, anchoring: SourceRenderer.anchoring
            )
        )
    }

    // MARK: - Escape

    /// Escape, for the reader's composer.
    ///
    /// A local `NSEvent` monitor rather than `.onExitCommand`, because the
    /// page's textarea swallows Escape outright and a SwiftUI handler never sees
    /// it — the same reason every other Escape in these apps is a monitor.
    ///
    /// Four gates, and the first two are not optional: a Galactic modal on
    /// screen owns the keyboard, and so does a window the host is running an
    /// app-modal session for. This monitor deliberately does not stand down for
    /// a focused text view the way others do, because the composer it exists to
    /// serve *is* one, and nothing else here would stop it.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            if GalacticModals.isClaimingKeyboard { return event }
            // The reader is behind Settings, not in front of it, so Escape is
            // that window's to answer.
            if GalacticModals.appModalWindowIsClaimingKeyboard { return event }
            guard event.keyCode == 53 else { return event }
            // Read through the gate, never off this struct — see its doc.
            guard gate.isVisibleSurface, !isObscuredByHost() else {
                return event
            }

            // The find bar first, and this monitor is why it needs saying. A
            // local monitor sees every key this app is sent, including one aimed
            // at the bar's own window — so consuming Escape for the note form
            // took away the bar's only keyboard exit and left it closable by
            // mouse alone. Innermost surface wins, which is what Escape means
            // everywhere else here.
            if findController.isVisible {
                findController.isVisible = false
                return nil
            }

            surface.handleEscape(webView: webViewRef)
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    // MARK: - The reader

    @ViewBuilder
    private var reader: some View {
        if let tab = set.selectedTab, let file = set.file(forPath: tab.path) {
            FileReaderView(
                file: file,
                itemLabel: label(for: file),
                notes: set.notes.notes(forPath: tab.path),
                noteCount: set.totalNoteCount,
                // Non-nil only for this set's results file, which is what makes
                // that tab render as results rather than as its own source.
                searchRun: surface.searchRun(
                    forPath: tab.path, owner: set.ownerID
                ),
                textEntry: surface.textEntryPayload,
                isDark: isDark,
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef,
                // The rescue and the restore are one operation, and the set is
                // what performs it: the blob arriving belongs to the page being
                // replaced, and only the set knows which file that was.
                handOffComposer: { set.handOffComposer(rescued: $0, to: tab.id) },
                handOffScroll: { set.handOffScroll(rescued: $0, to: tab.id) },
                onAnnotationMessage: { surface.handle($0, webView: webViewRef) },
                // A results page's paths and line numbers are ordinary links.
                // The reader cancels every navigation and hands ours here.
                onLinkActivated: { url in
                    guard let hit = SearchHitLink.parse(url) else { return }
                    surface.openSearchHit(path: hit.path, line: hit.line)
                },
                // Where the next page lands, when a line was asked for.
                landingJS: {
                    guard
                        let line = surface.consumePendingJump(forPath: tab.path)
                    else { return nil }
                    return ReaderLineJump.javaScript(
                        line: line, anchoring: SourceRenderer.anchoring
                    )
                }
            )
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 22))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No file open")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if let emptyHint {
                Text(emptyHint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the page calls this document — the path relative to the root, which
    /// is also what a review will cite.
    private func label(for file: ReaderFile) -> String {
        FilePaths.relativePath(of: file.url, under: set.root)
            ?? file.url.lastPathComponent
    }
}

// MARK: - Live state for the Escape monitor

/// A reference the monitor can read through, because a view struct is a
/// snapshot and a local monitor outlives the one that installed it.
///
/// Not `ObservableObject`: nothing redraws when this changes, and publishing it
/// would invalidate the pane on every tab switch to record a fact only a key
/// press ever reads.
@MainActor
private final class EscapeGate {
    var isVisibleSurface = false
}

// MARK: - The reader

/// Dispatches a loaded file onto a renderer.
///
/// Two questions, and only two: is this an image, and what language is it. The
/// text sniff that got the file this far already answered everything else — a
/// file with no recognised extension holding text renders as source, and a
/// `.txt` that was secretly a database never arrived.
private struct FileReaderView: View {
    let file: ReaderFile
    let itemLabel: String
    /// This file's notes, which become its cards.
    let notes: [FileNote]
    /// Every note in the set — what the send bar counts. A reader who has
    /// annotated three files and is looking at the fourth still has a review of
    /// all of them.
    let noteCount: Int
    /// Set when this tab *is* the set's search results, which is the third arm
    /// of the dispatch below.
    let searchRun: FileSearchRun?
    let textEntry: [String: [[String: Any]]]?
    let isDark: Bool
    let isVisibleSurface: Bool
    @Binding var webViewRef: WKWebView?
    let handOffComposer: (String?) -> String?
    let handOffScroll: (Double) -> Double
    let onAnnotationMessage: (AnnotationMessage) -> Void
    let onLinkActivated: (URL) -> Void
    let landingJS: () -> String?

    var body: some View {
        ReaderHostView(
            isDark: isDark,
            // The path and the appearance both rebuild the page, and so does a
            // fresh read of the same path: one reader serves every tab, so
            // unlike an artifact reader the content can change underneath it.
            // `loadedAt` is what makes a reload of the same file a rebuild.
            reloadToken: [
                file.url.path,
                String(file.loadedAt.timeIntervalSince1970),
                String(isDark),
            ].joined(separator: "|"),
            document: { document },
            annotationInitJS: { rescued in
                // Handed over even for an image, and putting this above the
                // guard is the fix. This call is the only thing that advances
                // the set's record of which tab the reader is showing, so
                // skipping it for an image left that record naming the file
                // before it — and the next thing hung off the same hand-off
                // would have stored the image's state onto that file.
                let restored = handOffComposer(rescued)
                // Images get no annotation layer. Every anchor a review can cite
                // is a line range, and an image anchors as a whole — a note on
                // one would compose a citation with no lines in it. Returning
                // nothing installs nothing, rather than installing a manager
                // whose cards cannot be sent.
                guard file.kind != .image else { return "" }
                // A results page has nothing to anchor a note to — the numbers
                // in its gutter belong to other files — and one would outlive
                // the results it was written against.
                guard searchRun == nil else { return "" }
                return buildFileNoteInitJS(
                    itemLabel: itemLabel,
                    notes: notes,
                    fileContent: file.content,
                    referencePath: file.url.path,
                    textEntry: textEntry,
                    restoringFormState: restored,
                    sendBarCount: noteCount
                )
            },
            handOffScroll: handOffScroll,
            baseURL: baseURL,
            webView: $webViewRef,
            isVisibleSurface: isVisibleSurface,
            onAnnotationMessage: onAnnotationMessage,
            onLinkActivated: onLinkActivated,
            landingJS: landingJS
        )
    }

    private var document: String {
        // Dispatched on the run rather than on the filename, so `FileKind`
        // learns nothing about search results and a host's own unhandled-kind
        // seam is untouched.
        if let searchRun {
            return FileSearchResultsRenderer.document(
                run: searchRun, isDark: isDark
            )
        }
        if file.kind == .image {
            return ImageRenderer.document(
                filePath: file.url.path, isDark: isDark
            )
        }
        return SourceRenderer.document(
            content: file.content,
            // The first line goes with the name, so a script with no extension
            // is read as whatever its shebang declares — a shim named `ri` is
            // bash.
            language: FileKind.highlightLanguage(
                forFilename: file.url.lastPathComponent,
                firstLine: firstLine
            ),
            isDark: isDark
        )
    }

    private var firstLine: String? {
        let line = file.content.prefix { $0 != "\n" }
        return line.isEmpty ? nil : String(line)
    }

    /// An image is loaded by the page from its own path, so the page has to be
    /// based in the directory holding it. Source is a string and needs nothing.
    ///
    /// The scheme is the package's rather than either application's: it is a
    /// base for relative resolution and nothing dereferences it, so two hosts
    /// spelling it differently would have been two spellings of nothing.
    private var baseURL: URL? {
        if file.kind == .image {
            return file.url.deletingLastPathComponent()
        }
        return URL(string: "galactic://file-reader")
    }
}
