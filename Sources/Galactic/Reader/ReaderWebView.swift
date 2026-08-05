import AppKit
import WebKit

/// The web view every reader is hosted in.
///
/// A `WKWebView` with the handful of AppKit accommodations a document reader
/// needs and the framework does not provide. None of them are about any
/// particular kind of document, which is why they live here rather than in a
/// renderer: whatever the page contains, it is read inside a window that also
/// has menus, a key-view loop, and a drag destination.
///
/// ### What it adds
///
/// - **Key-view isolation.** `previousValidKeyView` and `nextValidKeyView`
///   answer nil. When something makes this view first responder, AppKit
///   otherwise walks the key view chain across the whole enclosing view tree,
///   which in a tabbed host means every pane of every tab.
/// - **Function-key silence.** F1–F20 are consumed rather than passed on.
///   Unhandled function keys reach the end of the responder chain and ring
///   NSBeep; dictation triggers like Fn+F11 would beep on every use. Dictation
///   itself is unaffected, arriving through `NSTextInputClient` rather than
///   `keyDown`.
/// - **Zoom.** Command with `=`, `-`, or `0`, applied as a CSS transform on
///   the body rather than through `pageZoom`, so the page keeps its layout
///   width and only the rendering scales.
/// - **Command-S passthrough.** Returned unhandled so the menu sees it.
///   `WKWebView` would otherwise consume it first.
/// - **File drops.** Dropped file paths are handed to a page-global
///   `handleFileDrop([...])`, if the page defines one.
///
/// ### What a page must provide
///
/// Nothing. Every behaviour above degrades to inaction: a page with no
/// `handleFileDrop` simply does not receive drops, and the drop-active body
/// class is cosmetic. A reader adopts this by using it, not by implementing
/// against it.
public class ReaderWebView: WKWebView {
    /// Short-circuit key view traversal — the same fix
    /// `GalacticSwiftTermView` carries, for the same reason.
    override public var previousValidKeyView: NSView? { nil }
    override public var nextValidKeyView: NSView? { nil }

    /// Current zoom level (1.0 = 100%)
    private var zoomLevel: CGFloat = 1.0

    /// Whether this reader is the surface in front of the user.
    ///
    /// Supplied by the host, because nothing here can work it out. A tabbed
    /// host may keep every tab mounted and switch between them with opacity
    /// rather than tearing them down — which is a deliberate way to preserve
    /// each tab's state and make switching instant — and a hidden view is
    /// still in the window's view hierarchy. `performKeyEquivalent` is offered
    /// to that whole hierarchy before the menu bar sees the event, and a zero
    /// alpha is not hidden, so a reader nobody can see was answering the zoom
    /// chords and scaling a page nobody was looking at while the menu item
    /// that should have had them sat unreached.
    ///
    /// Defaults to false: a host that forgets to say gets a reader that
    /// declines keys rather than one that steals them, and the missing wiring
    /// shows up as a chord that does nothing instead of a chord that does
    /// something invisible.
    var isVisibleSurface: Bool = false

    override public init(
        frame: CGRect,
        configuration: WKWebViewConfiguration
    ) {
        super.init(
            frame: frame,
            configuration: configuration
        )
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func performKeyEquivalent(
        with event: NSEvent
    ) -> Bool {
        // Answer nothing at all while another surface is in front of the user.
        //
        // Deliberately not `super`: the framework's own handling is exactly
        // what the overrides below exist to get in front of, and a reader that
        // is not on screen has no more business consuming a chord through
        // `WKWebView` than through this method. Declining outright lets the
        // event carry on to whatever the user can actually see.
        guard isVisibleSurface else { return false }

        // F1 (0xF704) through F20 (0xF717) —
        // consume silently
        if event.modifierFlags.contains(.function),
           event.charactersIgnoringModifiers?
               .unicodeScalars.first
               .map({
                   $0.value >= 0xF704
                       && $0.value <= 0xF717
               }) == true
        {
            return true
        }

        // Zoom is Command and nothing else.
        //
        // Tested for equality rather than membership, because `contains` is a
        // subset test: it holds for Command+Shift too, and
        // `charactersIgnoringModifiers` reports "=" whether or not Shift was
        // held. A host whose chrome-font-size shortcuts are Command+Shift over
        // exactly these keys would find a focused reader swallowing all three
        // and zooming itself instead — the menu never sees them.
        let chord = event.modifierFlags.intersection(
            [.command, .option, .control, .shift]
        )
        if chord == .command, let chars = event.charactersIgnoringModifiers {
            // Cmd+= or Cmd++: zoom in
            if chars == "=" || chars == "+" {
                adjustZoom(by: 0.1)
                return true
            }
            // Cmd+-: zoom out
            if chars == "-" {
                adjustZoom(by: -0.1)
                return true
            }
            // Cmd+0: reset zoom
            if chars == "0" {
                resetZoom()
                return true
            }
        }

        // Cmd+S: pass through to the menu.
        // WKWebView's default performKeyEquivalent
        // may consume this before the menu sees it.
        if event.modifierFlags.contains(.command),
           let chars = event
               .charactersIgnoringModifiers,
           chars == "s"
        {
            return false
        }

        return super.performKeyEquivalent(
            with: event
        )
    }

    private func adjustZoom(by delta: CGFloat) {
        zoomLevel = min(
            3.0, max(0.5, zoomLevel + delta)
        )
        applyZoom()
    }

    private func resetZoom() {
        zoomLevel = 1.0
        applyZoom()
    }

    private func applyZoom() {
        evaluateJavaScript("""
            document.body.style.transform
                = 'scale(\(zoomLevel))';
            document.body.style.transformOrigin
                = 'top left';
            document.body.style.width
                = '\(100.0 / zoomLevel)%';
        """)
    }

    // MARK: - File Drag and Drop

    override public func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard !ModalState.isPresenting(over: window) else {
            return []
        }

        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }

        evaluateJavaScript(
            "document.body.classList"
            + ".add('file-drop-active')"
        )
        return .copy
    }

    override public func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard !ModalState.isPresenting(over: window) else {
            return []
        }

        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        return .copy
    }

    override public func draggingExited(
        _ sender: NSDraggingInfo?
    ) {
        evaluateJavaScript(
            "document.body.classList"
            + ".remove('file-drop-active')"
        )
    }

    override public func draggingEnded(
        _ sender: NSDraggingInfo
    ) {
        evaluateJavaScript(
            "document.body.classList"
            + ".remove('file-drop-active')"
        )
    }

    override public func performDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        defer {
            evaluateJavaScript(
                "document.body.classList"
                + ".remove('file-drop-active')"
            )
        }

        guard !ModalState.isPresenting(over: window) else {
            return false
        }

        guard let urls = sender.draggingPasteboard
            .readObjects(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly: true,
                ]
            ) as? [URL], !urls.isEmpty
        else { return false }

        // Deduplicate by path
        var seen = Set<String>()
        var paths: [String] = []
        for url in urls {
            let p = url.standardized.path
            if !seen.contains(p) {
                seen.insert(p)
                paths.append(p)
            }
        }

        // Encoded rather than escaped. A filename may legally contain a
        // quote, a backslash, or a line terminator, and any of those ends the
        // string literal early — which makes the whole injected snippet a
        // syntax error rather than a call with a wrong argument, so nothing
        // runs at all and the only trace is a console message inside the page.
        let jsPaths = JavaScriptLiteral.array(paths)

        evaluateJavaScript(
            "if (typeof handleFileDrop"
            + " !== 'undefined')"
            + " { handleFileDrop(\(jsPaths)); }"
        )
        return true
    }
}
