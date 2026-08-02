import AppKit

/// Freezing a pane's buffer and building the surface that renders it.
///
/// Both hosts opened a scrollback the same way — capture the pane's buffer,
/// read the live font metrics, render a document, and construct a web view
/// against the theme's background so a rubber-band overscroll does not reveal
/// white. What differs is only what each host does with the result afterwards,
/// so the wiring stays with them and the construction lives here.
public enum ScrollbackFactory {

    /// What a freshly opened scrollback consists of.
    ///
    /// The snapshot travels back with the view because the host has to retain
    /// it: re-rendering on a font or theme change renders *this* frozen buffer
    /// again, and re-capturing instead would swap what the reader is looking
    /// at for whatever the terminal has since become.
    public struct Opened {
        public let snapshot: ScrollbackSnapshot
        public let webView: ScrollbackWebView
    }

    /// Freeze `pane`'s buffer and build a web view rendering it.
    ///
    /// Returns nil when the pane has no buffer to freeze — teardown already in
    /// progress, or no active surface — which a caller should treat as "do not
    /// open", not as an error.
    ///
    /// `initialScrollLine` defaults to the snapshot's own viewport top, so an
    /// overlay opens where the user was already looking rather than at the
    /// bottom of several thousand lines.
    public static func open(
        pane: TerminalPane,
        theme: TerminalColorTheme,
        textEntry: [String: [[String: Any]]]?,
        initialScrollLine: Int? = nil
    ) -> Opened? {
        guard let snapshot = pane.captureScrollbackSnapshot() else {
            return nil
        }

        // Live font metrics, so frozen cells land on the same grid as the
        // ones still being painted behind the overlay.
        let font = pane.font
        let html = ScrollbackHTMLRenderer.render(
            snapshot: snapshot,
            theme: theme,
            fontFamily: font.fontName,
            fontSize: font.pointSize,
            cellHeight: pane.cellHeight,
            textEntry: textEntry
        )

        let webView = ScrollbackWebView(
            frame: pane.view.bounds,
            html: html,
            initialScrollLine: initialScrollLine ?? snapshot.yDisp,
            backgroundColor: theme.backgroundColorValue
        )
        return Opened(snapshot: snapshot, webView: webView)
    }
}
