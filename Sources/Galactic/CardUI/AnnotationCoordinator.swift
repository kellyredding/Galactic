import AppKit
import WebKit

// MARK: - Annotation Coordinator

/// WKScriptMessageHandler that routes annotation
/// messages from the generalized AnnotationManager JS
/// to Swift via a callback.
public class AnnotationCoordinator: NSObject,
    WKScriptMessageHandler, WKNavigationDelegate
{
    public var lastIsDark: Bool
    public var onAnnotationMessage:
        ((AnnotationMessage) -> Void)?
    public var pendingInitJS: String?

    /// Run after `pendingInitJS`, because that script builds the annotation
    /// cards and moves the content any offset was measured against.
    public var pendingScrollJS: String?

    /// A link the page activated that the host has an answer for.
    ///
    /// Every `.linkActivated` is cancelled — a reader never navigates — so this
    /// is a notification and not a decision. A host that leaves it unset gets
    /// exactly the previous behaviour: the link is declined and logged.
    ///
    /// This is the seam a reader uses to make a reference in its own content
    /// actionable, rather than adding a case to `AnnotationMessage`: activating
    /// a link is a navigation, and this delegate is what answers navigations.
    public var onLinkActivated: ((URL) -> Void)?

    public init(isDark: Bool) {
        self.lastIsDark = isDark
    }

    public func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "annotation",
              let body = message.body as? [String: Any],
              let parsed = AnnotationMessage.from(body)
        else { return }
        onAnnotationMessage?(parsed)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor nav: WKNavigationAction,
        decisionHandler: @escaping
            (WKNavigationActionPolicy) -> Void
    ) {
        if nav.navigationType == .linkActivated,
           let url = nav.request.url
        {
            if url.scheme == "http"
                || url.scheme == "https"
            {
                NSWorkspace.shared.open(url)
            } else if let onLinkActivated {
                onLinkActivated(url)
            } else {
                // A scheme with no handler used to be indistinguishable from a
                // link that worked. Nothing here is an error — a page is free
                // to hold a link this build has no answer for — but a silent
                // cancel is not readable from the code or from a running app.
                GalacticLog.debug(
                    "reader-nav",
                    "declined \(url.scheme ?? "no-scheme") link"
                )
            }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        if let js = pendingInitJS {
            webView.evaluateJavaScript(js)
            pendingInitJS = nil
        }
        if let js = pendingScrollJS {
            webView.evaluateJavaScript(js)
            pendingScrollJS = nil
        }
    }
}
