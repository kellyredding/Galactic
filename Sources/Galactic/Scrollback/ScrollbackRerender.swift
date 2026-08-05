import AppKit

/// Height of one terminal line for a given font.
///
/// The scrollback overlay has to lay frozen cells out on the same grid the
/// live terminal uses, so this is the number that keeps the two aligned. Kept
/// beside the font resolver rather than inside a backend, because the chrome
/// needs it while re-rendering a snapshot and never touches a backend to do so.
public func terminalCellHeight(for font: NSFont) -> CGFloat {
    let ctFont = font as CTFont
    return ceil(
        CTFontGetAscent(ctFont)
            + CTFontGetDescent(ctFont)
            + CTFontGetLeading(ctFont)
    )
}

public extension ScrollbackOverlayView {

    /// Re-render an open overlay against new metrics, holding scroll position.
    ///
    /// The frozen buffer does not change — the same snapshot is rendered again
    /// with different type. Re-capturing instead would silently swap what the
    /// user is reading for whatever the live terminal has since become, which
    /// is the opposite of what a frozen surface is for.
    ///
    /// A full rebuild rather than restyling in place, because the colours of
    /// each cell are baked into inline styles when the document is built: a
    /// theme change cannot be expressed as new CSS over old markup.
    ///
    /// The visible line is read out of the page first and handed back after,
    /// so the reader stays where they were rather than being returned to the
    /// top of several thousand lines. Whatever was still being composed — a
    /// half-written note, an edit in progress, an overall comment — is
    /// rescued the same way, since none of it has a source of truth outside
    /// the page.
    func reRender(
        snapshot: ScrollbackSnapshot,
        theme: TerminalColorTheme,
        fontFamily: String,
        fontSize: CGFloat,
        textEntry: [String: [[String: Any]]]?
    ) {
        scrollbackView.webView.evaluateJavaScript(
            "ScrollbackManager.getVisibleLine()"
        ) { [weak self] result, _ in
            guard let self else { return }
            // A missing answer is not line zero. The page returns 0 legitimately
            // when the reader is at the top, but returns *nothing* when it has
            // not finished loading — and treating those alike re-renders a
            // half-built page and dumps the reader at the top of several
            // thousand lines. Holding position is the whole point of this
            // method, so decline rather than guess.
            guard let scrollLine = result as? Int else { return }
            // Ask the outgoing page for anything it was still composing,
            // before the load that destroys it. The notes themselves come
            // back from Swift, but a half-written one only exists here.
            self.scrollbackView.webView.evaluateJavaScript(
                "JSON.stringify(ScrollbackManager.getFormState())"
            ) { formResult, _ in
                let font = resolveTerminalFont(
                    family: fontFamily, size: fontSize
                )
                let html = ScrollbackHTMLRenderer.render(
                    snapshot: snapshot,
                    theme: theme,
                    fontFamily: font.fontName,
                    fontSize: fontSize,
                    cellHeight: terminalCellHeight(for: font),
                    textEntry: textEntry
                )
                self.scrollbackView.reload(
                    html: html,
                    scrollToLine: scrollLine,
                    formState: formResult as? String
                )
            }
        }
    }
}
