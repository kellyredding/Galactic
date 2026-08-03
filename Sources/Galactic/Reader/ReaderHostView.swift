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

    public var baseURL: URL?

    /// Published back so a host can drive find-in-page and card updates.
    @Binding public var webView: WKWebView?

    public var onAnnotationMessage: ((AnnotationMessage) -> Void)?

    public var isInspectable: Bool

    public init(
        isDark: Bool,
        reloadToken: AnyHashable,
        document: @escaping () -> String,
        annotationInitJS: @escaping (String?) -> String,
        baseURL: URL?,
        webView: Binding<WKWebView?>,
        onAnnotationMessage: ((AnnotationMessage) -> Void)? = nil,
        isInspectable: Bool = false
    ) {
        self.isDark = isDark
        self.reloadToken = reloadToken
        self.document = document
        self.annotationInitJS = annotationInitJS
        self.baseURL = baseURL
        self._webView = webView
        self.onAnnotationMessage = onAnnotationMessage
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
        view.navigationDelegate = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = backdrop

        context.coordinator.lastToken = reloadToken
        context.coordinator.onAnnotationMessage = onAnnotationMessage
        context.coordinator.pendingInitJS = annotationInitJS(nil)

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

        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        view.layer?.backgroundColor = backdrop

        let build = annotationInitJS
        let page = document
        let base = baseURL

        // Ask the outgoing page for anything worth keeping, then load inside
        // the reply — loading first would destroy the page being asked.
        view.evaluateJavaScript(Self.rescueFormStateJS) { result, _ in
            context.coordinator.pendingInitJS = build(result as? String)
            view.loadHTMLString(page(), baseURL: base)
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

    /// Remembers what the page was last built from.
    ///
    /// Everything else it does is already shared; this adds only the memory
    /// that lets `updateNSView` tell a rebuild from a routine pass.
    public final class Coordinator: AnnotationCoordinator {
        public var lastToken: AnyHashable?
    }
}
