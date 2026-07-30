import Combine
import WebKit

/// Drives Galaxy's find UI against a single WKWebView.
///
/// The view-side `FindBarView` binds to this controller and Swift
/// dispatches operations into the page's `window.GalaxyFind`
/// module via `evaluateJavaScript`. Match counts flow back through
/// the `galaxyFind` message handler so the bar can render
/// "3 of 27" reactively.
///
/// Reverse mode is a fixed property at construction time. The
/// scrollback overlay constructs its controller with
/// `reverse: true` so iteration walks bottom-up; readers use the
/// default forward mode.
@MainActor
public final class WebViewFindController: NSObject, ObservableObject {
    /// Live text in the find field. The Combine pipeline below
    /// debounces this and forwards into the page's GalaxyFind
    /// module; do NOT call `applyQuery()` directly from a
    /// `didSet` here — every keystroke would rerun the full DOM
    /// walk and the WebView would feel like it's beach-balling.
    @Published public var query: String = ""
    @Published public private(set) var matchCount: Int = 0
    @Published public private(set) var matchIndex: Int = -1
    @Published public var isVisible: Bool = false {
        didSet {
            if isVisible {
                // Reopening with a non-empty query already typed:
                // re-apply immediately rather than waiting for the
                // debounce, which only fires on value changes.
                applyQuery()
            } else {
                closeFind()
            }
        }
    }

    /// Reverse iteration: first match = last hit walking up.
    /// Used by the scrollback overlay so Cmd+F results read
    /// most-recent-first.
    public let reverse: Bool

    private weak var webView: WKWebView?
    private var queryCancellable: AnyCancellable?

    /// Debounce window before a query change fires another
    /// full DOM walk. 250ms is the smallest value where typing
    /// "function" doesn't queue 8 redundant searches; pushing
    /// higher (500+) makes the bar feel laggy.
    private static let queryDebounce = 0.25

    public init(webView: WKWebView?, reverse: Bool = false) {
        self.webView = webView
        self.reverse = reverse
        super.init()
        attachMessageHandler()
        attachQueryPipeline()
    }

    private func attachQueryPipeline() {
        queryCancellable = $query
            .debounce(
                for: .seconds(Self.queryDebounce),
                scheduler: DispatchQueue.main
            )
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyQuery()
            }
    }

    /// Re-bind the controller to a different WKWebView (e.g.,
    /// reader swap, SwiftUI lifecycle resets the makeNSView
    /// instance). Re-attaches the message handler on the new
    /// web view's content controller and re-applies the current
    /// query so the new page mirrors the bar's state.
    public func bind(to webView: WKWebView?) {
        self.webView = webView
        attachMessageHandler()
        if isVisible { applyQuery() }
    }

    public func next() {
        webView?.evaluateJavaScript("GalaxyFind.next()")
    }

    public func prev() {
        webView?.evaluateJavaScript("GalaxyFind.prev()")
    }

    private func applyQuery() {
        guard isVisible else { return }
        let escaped = Self.jsEscape(query)
        let opts = reverse ? "{reverse:true}" : "{}"
        webView?.evaluateJavaScript(
            "GalaxyFind.setQuery('\(escaped)', \(opts))"
        )
    }

    private func closeFind() {
        webView?.evaluateJavaScript("GalaxyFind.close()")
        matchCount = 0
        matchIndex = -1
    }

    private func attachMessageHandler() {
        guard let controller = webView?.configuration
            .userContentController else { return }
        controller.removeScriptMessageHandler(forName: "galaxyFind")
        controller.add(
            WeakMessageProxy(target: self),
            name: "galaxyFind"
        )
    }

    fileprivate func handle(_ body: [String: Any]) {
        let event = body["event"] as? String ?? ""
        guard event == "matches" else { return }
        matchCount = body["count"] as? Int ?? 0
        matchIndex = body["index"] as? Int ?? -1
    }

    private static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            // U+2028 and U+2029 are line terminators to a JS
            // parser, so an unescaped one breaks the literal
            // exactly as a raw newline would. Reachable by
            // pasting text copied from a web page.
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// Weak proxy mirroring the pattern in `ScrollbackWebView` —
/// breaks the `WKUserContentController → handler` retain cycle.
/// `WKUserContentController.add(_:name:)` retains its handler
/// strongly; the message handler weakly retains the controller
/// so ARC can free the controller (and its WKWebView reference)
/// when the SwiftUI parent goes away.
private final class WeakMessageProxy:
    NSObject, WKScriptMessageHandler
{
    weak var target: WebViewFindController?

    public init(target: WebViewFindController) {
        self.target = target
    }

    public func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else {
            return
        }
        Task { @MainActor in
            self.target?.handle(body)
        }
    }
}
