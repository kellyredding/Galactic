import AppKit
import SwiftUI
import WebKit

/// Hosts a reader's page and owns its lifecycle.
///
/// Every reader stood up its own web view, and the standing-up was the same:
/// configure find-in-page, register the annotation channel, turn off the
/// backdrop so the layer colour shows through, set a navigation delegate, hand
/// the coordinator an init script to run once the page finishes, load, and
/// publish the view back to the host. Then, on a theme change, the same
/// sequence again with one addition — rescue whatever the reader had typed
/// into a composer before the page it lived in is thrown away.
///
/// ### The reload token
///
/// A page is rebuilt when `reloadToken` changes, and the token is whatever the
/// document was built from. Appearance is part of it for every reader; a
/// reader whose content can change under it puts the content in too. Stating
/// it as a value rather than comparing appearance directly is what lets one
/// host serve both — the reader that reloads on content used to need a
/// lifecycle of its own for that single difference, and carried a duplicate
/// coordinator to get it.
///
/// ### Rescuing a composer
///
/// A theme change destroys the page, and with it any half-written note. Before
/// loading a replacement the outgoing page is asked for its form state, and
/// whatever comes back is handed to `annotationInitJS` to fold into the script
/// that initialises the new one. Nil means there was nothing to rescue —
/// either the first load, when no manager exists yet, or no composer open.
public struct ReaderHostView: NSViewRepresentable {

    /// Whether the page is drawn dark. Sets the layer colour behind the page,
    /// so a reload does not flash the wrong background before paint.
    public var isDark: Bool

    /// Everything the page is built from. A change rebuilds it.
    public var reloadToken: AnyHashable

    /// Build the page.
    public var document: () -> String

    /// Build the script that installs annotations, given any form state
    /// rescued from the outgoing page. Return an empty string to install
    /// nothing.
    public var annotationInitJS: (String?) -> String

    /// Take the outgoing page's scroll position, and answer with the incoming
    /// page's.
    ///
    /// One call in both directions, for the same reason the composer hand-off is
    /// one call: the position arriving belongs to the page being replaced, and
    /// only the host knows which file that was.
    ///
    /// Asked *before* `annotationInitJS`, because that is where the host hands
    /// the composer over and advances its own record of which file is on screen.
    public var handOffScroll: ((Double) -> Double)?

    public var baseURL: URL?

    /// Published back so a host can drive find-in-page and card updates.
    @Binding public var webView: WKWebView?

    public var onAnnotationMessage: ((AnnotationMessage) -> Void)?

    /// A link activated in the page. See `AnnotationCoordinator`.
    ///
    /// A reader whose content holds references — a search result, a citation,
    /// a `path:42` in a note — makes them ordinary anchors and answers here.
    /// Unset means the previous behaviour: declined and logged.
    public var onLinkActivated: ((URL) -> Void)?

    /// The script that puts a freshly built page somewhere other than where the
    /// reader left it.
    ///
    /// Asked once per build, after the composer hand-off. A non-nil answer
    /// **replaces** the remembered scroll offset rather than running beside it:
    /// both answer "where does this page land", and a page cannot land twice. A
    /// host that opened a file *because* of a line reference wants the line;
    /// the offset it remembers for that file is from an earlier visit and is
    /// not what was asked for.
    ///
    /// Runs in `pendingScrollJS`, so it inherits that slot's ordering — after
    /// the init script, because that script builds the annotation cards and
    /// moves the content any measurement was taken against.
    public var landingJS: (() -> String?)?

    public var isInspectable: Bool

    /// Whether this reader is the surface in front of the user.
    ///
    /// Not the same question as "is this reader open". A host is free to keep
    /// every tab mounted and switch between them with opacity — the way to
    /// keep each tab's state and switch instantly — and a reader left open on
    /// a tab the user has moved away from is still in the window. It would go
    /// on answering the zoom chords from there, because
    /// `performKeyEquivalent` reaches the whole hierarchy before the menu bar.
    ///
    /// Required rather than defaulted, and that is the point: `true` would be
    /// the wrong default for every host that forgot it, silently reproducing
    /// the bug this exists to close, and `false` would hide the omission
    /// behind a reader whose zoom quietly stopped working. Asking makes the
    /// answer a decision.
    ///
    /// `TerminalHostView` takes the same value for the same reason; see its
    /// declaration.
    public var isVisibleSurface: Bool

    public init(
        isDark: Bool,
        reloadToken: AnyHashable,
        document: @escaping () -> String,
        annotationInitJS: @escaping (String?) -> String,
        handOffScroll: ((Double) -> Double)? = nil,
        baseURL: URL?,
        webView: Binding<WKWebView?>,
        isVisibleSurface: Bool,
        onAnnotationMessage: ((AnnotationMessage) -> Void)? = nil,
        onLinkActivated: ((URL) -> Void)? = nil,
        landingJS: (() -> String?)? = nil,
        isInspectable: Bool = false
    ) {
        self.isDark = isDark
        self.reloadToken = reloadToken
        self.document = document
        self.annotationInitJS = annotationInitJS
        self.handOffScroll = handOffScroll
        self.baseURL = baseURL
        self._webView = webView
        self.isVisibleSurface = isVisibleSurface
        self.onAnnotationMessage = onAnnotationMessage
        self.onLinkActivated = onLinkActivated
        self.landingJS = landingJS
        self.isInspectable = isInspectable
    }

    public func makeNSView(context: Context) -> ReaderWebView {
        let config = WKWebViewConfiguration()
        config.installGalaxyFindUserScript()
        config.userContentController.add(
            context.coordinator, name: "annotation"
        )

        let view = ReaderWebView(frame: .zero, configuration: config)
        // The page paints its own background; without this the web view draws
        // its default white first and a dark reader flashes on every load.
        view.setValue(false, forKey: "drawsBackground")
        view.isInspectable = isInspectable
        view.isVisibleSurface = isVisibleSurface
        view.navigationDelegate = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = backdrop

        context.coordinator.lastToken = reloadToken
        context.coordinator.onAnnotationMessage = onAnnotationMessage
        context.coordinator.onLinkActivated = onLinkActivated
        context.coordinator.pendingInitJS = annotationInitJS(nil)
        // A first build can be asked to land somewhere too: a host that mounts
        // its reader in response to the same click that chose the line.
        context.coordinator.pendingScrollJS = landingJS?()

        view.loadHTMLString(document(), baseURL: baseURL)

        // Deferred: publishing during a view update mutates state SwiftUI is
        // in the middle of reading.
        DispatchQueue.main.async { webView = view }

        return view
    }

    public func updateNSView(_ view: ReaderWebView, context: Context) {
        // Always refresh: the closure captures state the host may have
        // replaced since the last pass.
        context.coordinator.onAnnotationMessage = onAnnotationMessage
        context.coordinator.onLinkActivated = onLinkActivated

        // Above the token guard, and that placement is the whole fix. Moving
        // between tabs changes which surface is in front of the user without
        // changing anything the page is built from, so the reload token is
        // identical and everything below this line is skipped. Set after the
        // guard, the flag would be right only on the passes that happened to
        // rebuild the page — which is never the pass that matters.
        view.isVisibleSurface = isVisibleSurface

        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        view.layer?.backgroundColor = backdrop

        let build = annotationInitJS
        let scroll = handOffScroll
        let page = document
        let base = baseURL
        let landing = landingJS

        // Ask the outgoing page for anything worth keeping, then load inside
        // the reply — loading first would destroy the page being asked.
        //
        // Scroll first, and the order is load-bearing: `annotationInitJS` is
        // where the host hands the composer over, and that hand-off is what
        // advances its record of which file is on screen. Anything else that
        // needs to know which file is being *replaced* has to ask before it.
        view.evaluateJavaScript(Self.rescueScrollJS) { position, _ in
            let restoreTo = scroll?((position as? Double) ?? 0) ?? 0
            view.evaluateJavaScript(Self.rescueFormStateJS) { result, _ in
                context.coordinator.pendingInitJS = build(result as? String)
                // A landing script wins over a remembered offset: it is what
                // the reader just asked for, and the offset is where they were
                // the last time they looked at this file.
                context.coordinator.pendingScrollJS =
                    landing?()
                    ?? (restoreTo > 0 ? Self.restoreScrollJS(restoreTo) : nil)
                view.loadHTMLString(page(), baseURL: base)
            }
        }
    }

    public static func dismantleNSView(
        _ view: ReaderWebView,
        coordinator: Coordinator
    ) {
        view.stopLoading()
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: "annotation")
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(isDark: isDark)
    }

    private var backdrop: CGColor {
        (isDark ? NSColor.black : NSColor.white).cgColor
    }

    /// Asks the outgoing page for its composer state.
    ///
    /// Guarded on the manager existing *and* having blocks: on a first load
    /// there is no manager at all, and evaluating a bare reference would
    /// answer with an error rather than a value.
    private static let rescueFormStateJS = """
    typeof AnnotationManager !== 'undefined'
        && AnnotationManager.blocks.length > 0
        ? JSON.stringify(AnnotationManager.getFormState())
        : null
    """

    /// Asks the outgoing page how far down it was.
    ///
    /// Separate from the composer rescue rather than folded into it, because
    /// that one answers `null` for a page with no anchorable blocks — an image,
    /// or anything the annotation layer declined to install on. Those pages
    /// scroll too.
    ///
    /// The document is the scrolling element in a reader, unlike the scrollback,
    /// whose own container scrolls inside it.
    private static let rescueScrollJS = "window.pageYOffset"

    private static func restoreScrollJS(_ offset: Double) -> String {
        "window.scrollTo({ top: \(offset), behavior: 'instant' })"
    }

    /// Remembers what the page was last built from.
    ///
    /// Everything else it does is already shared; this adds only the memory
    /// that lets `updateNSView` tell a rebuild from a routine pass.
    public final class Coordinator: AnnotationCoordinator {
        public var lastToken: AnyHashable?
    }
}
