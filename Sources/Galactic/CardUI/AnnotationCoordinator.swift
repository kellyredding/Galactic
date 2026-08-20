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
