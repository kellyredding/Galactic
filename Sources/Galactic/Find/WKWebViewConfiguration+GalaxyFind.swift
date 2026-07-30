import WebKit

extension WKWebViewConfiguration {
    /// Install the GalaxyFind user script on this configuration.
    ///
    /// The script runs at document end on every navigation and
    /// installs `window.GalaxyFind` once per page (the IIFE
    /// short-circuits if it's already there). Idempotent — safe
    /// to call from any reader's `makeNSView` regardless of
    /// whether other Galaxy scripts are also being added.
    ///
    /// Companion to `WebViewFindController`, which drives the
    /// installed module via `evaluateJavaScript` and listens for
    /// match-count messages on the `galaxyFind` handler.
    public func installGalaxyFindUserScript() {
        let script = WKUserScript(
            source: GalaxyFindJS.userScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(script)
    }
}
