import Foundation
import AppKit

/// Converts a frozen `ScrollbackSnapshot` into a complete HTML document
/// that visually matches the live terminal rendering. Each snapshot line becomes
/// a `<div class="tl">` with styled `<span>` runs for each attribute group.
///
/// The HTML includes embedded CSS (font, colors, line-height matching the
/// terminal) and a JavaScript `ScrollbackManager` that handles keyboard
/// navigation, scroll position, and Swift ↔ WKWebView communication.
public enum ScrollbackHTMLRenderer {

    // MARK: - Public API

    /// Render a frozen `ScrollbackSnapshot` to a complete HTML document string.
    ///
    /// - Parameters:
    ///   - snapshot: Engine-agnostic scrollback snapshot. Iteration yields
    ///     `ScrollbackCell` instances translated from whichever backend
    ///     produced the snapshot.
    ///   - theme: Current color theme for default/ANSI colors
    ///   - fontFamily: CSS font-family value (e.g. "SF Mono", "Menlo")
    ///   - fontSize: Font size in points
    ///   - cellHeight: Pixel height of one terminal line (from cellDimension.height)
    /// - Parameter textEntry: composer keystroke bindings, in the shape
    ///   `window.GalaxyTextEntry.configure` expects. Passed in rather than read
    ///   from a settings singleton because this file is shared verbatim with
    ///   assist-ant, whose settings type differs — reading one here would end
    ///   that. Stated by every caller, including the ones that mean nil: an
    ///   omitted binding set and a deliberately absent one are different
    ///   answers, and a default cannot tell them apart.
    public static func render(
        snapshot: ScrollbackSnapshot,
        theme: TerminalColorTheme,
        fontFamily: String,
        fontSize: CGFloat,
        cellHeight: CGFloat,
        textEntry: [String: [[String: Any]]]?
    ) -> String {
        let resolver = ColorResolver(theme: theme)
        var html = ""
        let lineCount = snapshot.lineCount
        html.reserveCapacity(lineCount * snapshot.cols * 4)  // rough estimate

        for lineIdx in 0..<lineCount {
            html.append(renderLine(lineIndex: lineIdx,
                                   snapshot: snapshot,
                                   resolver: resolver))
        }

        return wrapDocument(
            body: html,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            cellHeight: cellHeight,
            textEntry: textEntry
        )
    }

    // MARK: - Line Rendering

    private static func renderLine(
        lineIndex: Int,
        snapshot: ScrollbackSnapshot,
        resolver: ColorResolver
    ) -> String {
        var spans = ""
        var currentStyle: ScrollbackCellStyle? = nil
        var currentText = ""
        var currentStartCol = 0  // column where current span starts
        var currentCol = 0       // current column position

        snapshot.enumerateCells(line: lineIndex) { cell in
            // Skip continuation cells (wide character second column).
            // The leading half at column N-1 already spans N-1 and N.
            if cell.columnWidth == 0 { return }

            let char = htmlEscape(cell.character)
            let colSpan = cell.columnWidth

            if cell.style == currentStyle {
                currentText.append(char)
                currentCol += colSpan
            } else {
                // Flush previous run with absolute position
                if let style = currentStyle, !currentText.isEmpty {
                    let colCount = currentCol - currentStartCol
                    spans.append(spanTag(for: style, text: currentText,
                                         startCol: currentStartCol,
                                         colCount: colCount,
                                         resolver: resolver))
                }
                currentStyle = cell.style
                currentText = char
                currentStartCol = currentCol
                currentCol += colSpan
            }
        }

        // Flush final run
        if let style = currentStyle, !currentText.isEmpty {
            let colCount = currentCol - currentStartCol
            spans.append(spanTag(for: style, text: currentText,
                                 startCol: currentStartCol,
                                 colCount: colCount,
                                 resolver: resolver))
        }

        if spans.isEmpty {
            return "<div class=\"tl\" data-line=\"\(lineIndex)\">&nbsp;</div>"
        }
        return "<div class=\"tl\" data-line=\"\(lineIndex)\">\(spans)</div>"
    }

    // MARK: - Span Generation

    private static func spanTag(
        for style: ScrollbackCellStyle,
        text: String,
        startCol: Int,
        colCount: Int,
        resolver: ColorResolver
    ) -> String {
        let attrs = style.attributes
        let isBold = attrs.contains(.bold)
        let isInverse = attrs.contains(.inverse)

        // Resolve colors (handle inverse swap)
        var fgHex = resolver.fgColor(style.foreground, isBold: isBold)
        var bgHex = resolver.bgColor(style.background)

        if isInverse {
            let tmpFg = fgHex ?? resolver.theme.foreground
            let tmpBg = bgHex  // nil means transparent (theme background)
            fgHex = tmpBg ?? resolver.theme.background
            bgHex = tmpFg
        }

        // Use CSS `ch` units for positioning — `ch` is the browser's own
        // measurement of one character advance width in the current font.
        // This eliminates the mismatch between Swift's CTFont cellWidth
        // and WebKit's font metrics that caused span boundary artifacts.
        var css = "position:absolute;left:\(startCol)ch;width:\(colCount)ch;overflow:hidden;"
        if let fg = fgHex { css.append("color:\(fg);") }
        if let bg = bgHex { css.append("background-color:\(bg);") }
        // Use -webkit-text-stroke instead of font-weight:bold. CSS bold
        // synthesis widens glyphs, breaking the monospace cell grid. Core
        // Text (used by SwiftTerm) renders bold by thickening strokes at
        // fixed glyph positions — text-stroke replicates that behavior.
        if isBold { css.append("-webkit-text-stroke:0.5px currentColor;") }
        if attrs.contains(.italic) { css.append("font-style:italic;") }
        if attrs.contains(.dim) { css.append("opacity:0.5;") }
        if attrs.contains(.invisible) { css.append("visibility:hidden;") }

        // Text decoration (combine underline + strikethrough)
        var decorations: [String] = []
        if attrs.contains(.underline) { decorations.append("underline") }
        if attrs.contains(.crossedOut) { decorations.append("line-through") }
        if !decorations.isEmpty {
            css.append("text-decoration:\(decorations.joined(separator: " "));")
        }

        return "<span style=\"\(css)\">\(text)</span>"
    }

    // MARK: - HTML Document Wrapper

    private static func wrapDocument(
        body: String,
        theme: TerminalColorTheme,
        fontFamily: String,
        fontSize: CGFloat,
        cellHeight: CGFloat,
        textEntry: [String: [[String: Any]]]?
    ) -> String {
        // Map font family for CSS — system monospace needs special handling
        let cssFontFamily: String
        if fontFamily.contains("SFMono") || fontFamily == "SF Mono" ||
            fontFamily.hasPrefix(".SFNSMono") || fontFamily.hasPrefix(".AppleSystemUIFontMonospaced") {
            cssFontFamily = "ui-monospace, \"SF Mono\", monospace"
        } else {
            cssFontFamily = "\"\(fontFamily)\", ui-monospace, monospace"
        }

        // Detect light vs dark theme for note styling CSS class
        let isLight = theme.backgroundLuminance > 0.5

        // Empty when no bindings were passed, which leaves the matcher on its
        // own defaults rather than clearing it.
        let textEntryConfigJS: String = {
            guard let textEntry,
                  let data = try? JSONSerialization.data(
                      withJSONObject: textEntry),
                  let json = String(data: data, encoding: .utf8)
            else { return "" }
            return "window.GalaxyTextEntry.configure(\(json));"
        }()

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style id="base-theme">
        :root {
            --fg: \(theme.foreground);
            --bg: \(theme.background);
            --font-family: \(cssFontFamily);
            --font-family-mono: "SF Mono", "Menlo", "Monaco", "Courier New", monospace;
            --font-size: \(fontSize)px;
            --line-height: \(cellHeight)px;
            --delete-color: #d63031;
            --card-active-border: rgba(255, 220, 50, 0.5);
            --card-active-bg: rgba(255, 255, 120, 0.12);
        }
        \(noteUXTokens(textSize: "var(--font-size)"))
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            background: var(--bg);
            color: var(--fg);
            font-family: var(--font-family);
            font-size: var(--font-size);
            line-height: var(--line-height);
            overflow-x: hidden;
            overscroll-behavior: none;
            -webkit-font-smoothing: antialiased;
            -webkit-user-select: text;
            cursor: text;
            padding-bottom: 48px;
        }
        pre {
            margin: 0;
            font-family: inherit;
            font-size: inherit;
            line-height: inherit;
        }
        .tl {
            position: relative;
            height: var(--line-height);
            white-space: pre;
            overflow: hidden;
        }
        ::selection {
            background-color: rgba(88, 166, 255, 0.3);
        }
        \(noteCSS(isLight: isLight))
        </style>
        </head>
        <body\(isLight ? " class=\"light\"" : "")>
        <pre id="terminal-content">\(body)</pre>
        <div class="send-bar" id="send-bar" style="display:none;">
            <span class="send-bar-count" id="send-bar-count">0 notes</span>
            <button class="send-bar-button" id="send-bar-button">Send to Claude ⌘⇧↩</button>
        </div>
        <script>\(emojiDataJS)</script>
        <script>\(emojiAutocompleteJS)</script>
        <script>\(cardTextJS)</script>
        <script>\(clipboardCopyJS)</script>
        <script>\(textEntryJS)</script>
        <script>\(textEntryConfigJS)</script>
        <script>\(suggestionInsertJS)</script>
        <script>\(addNoteButtonJS)</script>
        <script>
        \(scrollbackManagerJS)
        \(noteManagerJS)
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Emoji JS

    // Loaded once, with the card UI that depends on them, rather than read out
    // of the hosting app's bundle by each surface that wants them.
    private static let emojiDataJS: String = EmojiJS.data
    private static let emojiAutocompleteJS: String = EmojiJS.autocomplete

    // MARK: - JavaScript

    // js-validate
    // Internal rather than private so the package's shipped-JavaScript gate can
    // reach it. Not public: a host splices the finished document, never this.
    static let scrollbackManagerJS = """
    const ScrollbackManager = {
        lineHeight: 0,
        totalLines: 0,
        container: null,

        // While the Cmd+F find bar is visible, the chrome flips
        // this true via suspendInput() so handleKey ignores
        // arrow / page / Esc keys (otherwise Esc would dismiss
        // the whole overlay instead of just closing find, and
        // arrow keys would scroll the buffer underneath while
        // the user is typing in the find field).
        inputSuspended: false,

        suspendInput(flag) {
            this.inputSuspended = !!flag;
            const cls = 'galaxy-find-active';
            if (this.inputSuspended) {
                document.body.classList.add(cls);
            } else {
                document.body.classList.remove(cls);
            }
        },

        initialize() {
            // Use the document scrolling element (document-level scroll)
            // so WKWebView's native scroll indicator is visible.
            this.container = document.scrollingElement || document.documentElement;
            const firstLine = document.querySelector('.tl');
            if (firstLine) {
                this.lineHeight = firstLine.getBoundingClientRect().height;
            }
            this.totalLines = document.querySelectorAll('.tl').length;

            // Add bottom padding to compensate for the fractional row gap.
            // The viewport height rarely divides evenly by cellHeight,
            // leaving a gap of (viewportHeight % cellHeight) pixels at the
            // bottom. Without this padding, scrollTop is clamped short of the
            // target when scrolling to the last screenful, shifting content
            // down by the gap amount.
            const gap = window.innerHeight % this.lineHeight;
            if (gap > 0) {
                document.getElementById('terminal-content').style.paddingBottom = gap + 'px';
            }

            document.addEventListener('keydown', (e) => this.handleKey(e));

            // Initialize note manager
            this.notes.initialize();

            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'ready'
            });
        },

        handleKey(e) {
            // Suspended while the Cmd+F find bar is open; the
            // bar owns Esc/arrow keys for that duration.
            if (this.inputSuspended) return;

            // Let textareas handle their own arrow/cursor keys
            if (e.target.tagName === 'TEXTAREA') return;

            const c = this.container;
            switch (e.key) {
            case 'Escape':
                e.preventDefault();
                this.handleEscape();
                break;
            case 'Enter':
                // Bare Enter promotes a selection toolbar into
                // the note form, so drag then Enter arrives where
                // dragging alone used to. The textarea guard at
                // the top of this handler keeps it from stealing
                // newlines while composing.
                if (!e.metaKey && !e.shiftKey
                    && this.notes.selectionOnly) {
                    e.preventDefault();
                    this.notes.promoteToForm();
                    break;
                }
                // Cmd+Shift+Enter — send notes to Claude
                if (e.metaKey && e.shiftKey && this.notes.items.length > 0) {
                    e.preventDefault();
                    this.notes.sendToClaude();
                }
                break;
            case 'ArrowUp':
                if (!e.metaKey && !e.shiftKey) {
                    e.preventDefault();
                    c.scrollTop -= this.lineHeight;
                }
                break;
            case 'ArrowDown':
                if (!e.metaKey && !e.shiftKey) {
                    e.preventDefault();
                    c.scrollTop += this.lineHeight;
                }
                break;
            case 'PageUp':
                e.preventDefault();
                c.scrollTop -= c.clientHeight;
                break;
            case 'PageDown':
                e.preventDefault();
                c.scrollTop += c.clientHeight;
                break;
            case 'Home':
                e.preventDefault();
                c.scrollTop = 0;
                break;
            case 'End':
                e.preventDefault();
                c.scrollTop = c.scrollHeight;
                break;
            }
        },

        handleEscape() {
            const n = this.notes;

            // 1. Editing a note — the edit textarea's keydown handler
            // manages its own escape (emoji → confirm → cancel).
            // If we still reach here while editing, it means the
            // textarea didn't catch it — just ignore.
            if (n.editingId) return;

            // 2. Note expanded — collapse
            if (n.expandedId) {
                n.toggleExpand(n.expandedId);
                return;
            }

            // 3. Form visible — delegate to form escape handler
            if (n.formElement && n.formElement.style.display !== 'none') {
                const ta = n.formElement.querySelector('textarea');
                if (ta) {
                    n.handleFormEscape(ta);
                    return;
                }
                n.hideForm();
                n.clearHighlights();
                return;
            }

            // 4. Has notes — confirm dismiss
            if (n.items.length > 0) {
                window.webkit.messageHandlers.scrollback.postMessage({
                    action: 'confirmDismiss'
                });
                return;
            }

            // 5. No notes — dismiss scrollback
            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'dismiss'
            });
        },

        scrollToLine(lineIndex) {
            const line = document.querySelector('[data-line=\"' + lineIndex + '\"]');
            if (line) {
                this.container.scrollTop = line.offsetTop;
            }
        },

        getVisibleLine() {
            const c = this.container;
            const scrollTop = c.scrollTop;
            const lines = document.querySelectorAll('.tl');
            for (const line of lines) {
                if (line.offsetTop >= scrollTop) {
                    return parseInt(line.dataset.line);
                }
            }
            return 0;
        }
    };

    // Native-side hook to push Send-to-Claude button state
    // into the overlay live. Called from Swift whenever the
    // underlying disabledReason() changes (session stops or
    // resumes, session-pane scrollback opens or closes).
    // Uses a data-attribute (not the native `title`) so the
    // CSS tooltip in `.send-bar-button[data-disabled-reason]`
    // shows instantly on hover, no OS-imposed delay.
    ScrollbackManager.setSendButtonState = function(enabled, tooltip) {
        const btn = document.getElementById('send-bar-button');
        if (!btn) return;
        btn.disabled = !enabled;
        if (tooltip) {
            btn.setAttribute('data-disabled-reason', tooltip);
        } else {
            btn.removeAttribute('data-disabled-reason');
        }
    };

    document.addEventListener('DOMContentLoaded', () => {
        ScrollbackManager.initialize();
    });
    """

    // MARK: - Note CSS

    private static func noteCSS(isLight: Bool) -> String {
        let formBg = isLight
            ? "rgba(255, 255, 255, 0.95)"
            : "rgba(30, 30, 30, 0.95)"
        let formBorder = isLight
            ? "rgba(88, 166, 255, 0.5)"
            : "rgba(88, 166, 255, 0.4)"
        let cardBg = isLight
            ? "rgba(255, 255, 255, 0.92)"
            : "rgba(30, 30, 30, 0.9)"
        let textColor = isLight
            ? "rgba(0, 0, 0, 0.5)"
            : "rgba(255, 255, 255, 0.5)"
        let textColorFaint = isLight
            ? "rgba(0, 0, 0, 0.3)"
            : "rgba(255, 255, 255, 0.3)"
        let inputBg = isLight
            ? "rgba(0, 0, 0, 0.04)"
            : "rgba(255, 255, 255, 0.05)"
        let inputBorder = isLight
            ? "rgba(0, 0, 0, 0.12)"
            : "rgba(255, 255, 255, 0.1)"
        let cardBorder = isLight
            ? "rgba(0, 0, 0, 0.1)"
            : "rgba(255, 255, 255, 0.1)"
        let cardBorderHover = isLight
            ? "rgba(0, 0, 0, 0.2)"
            : "rgba(255, 255, 255, 0.2)"
        let highlightBg = isLight
            ? "rgba(88, 166, 255, 0.15)"
            : "rgba(88, 166, 255, 0.25)"
        let highlightBorder = isLight
            ? "rgba(88, 166, 255, 0.7)"
            : "rgba(88, 166, 255, 0.8)"
        let expandHighlightBg = isLight
            ? "rgba(255, 220, 50, 0.10)"
            : "rgba(255, 255, 120, 0.12)"
        let expandHighlightBorder = isLight
            ? "rgba(255, 200, 30, 0.6)"
            : "rgba(255, 220, 50, 0.7)"
        let sendBarBg = isLight
            ? "rgba(34, 139, 34, 0.92)"
            : "rgba(40, 170, 80, 0.95)"
        let sendBarBorderTop = isLight
            ? "rgba(0, 0, 0, 0.1)"
            : "rgba(255, 255, 255, 0.15)"
        let sendBtnBg = isLight
            ? "rgba(255, 255, 255, 0.25)"
            : "rgba(255, 255, 255, 0.2)"
        let sendBtnBorder = isLight
            ? "rgba(255, 255, 255, 0.35)"
            : "rgba(255, 255, 255, 0.3)"

        return """
        /* Note line highlights. The left marker is an absolutely
           positioned ::before rather than a border or padding, which
           would shift the absolutely-positioned spans inside a .tl
           line. It is inset 6px from the left edge, well within the
           overflow:hidden that .tl applies, so nothing has to relax
           that clipping. */
        .note-highlight {
            background-color: \(highlightBg) !important;
        }
        .note-highlight::before {
            content: '';
            position: absolute;
            left: 6px;
            top: 0;
            bottom: 0;
            width: 4px;
            background: \(highlightBorder);
            z-index: 10;
            border-radius: 1px;
        }
        .note-expanded-highlight {
            background-color: \(expandHighlightBg) !important;
        }
        .note-expanded-highlight::before {
            content: '';
            position: absolute;
            left: 6px;
            top: 0;
            bottom: 0;
            width: 4px;
            background: \(expandHighlightBorder);
            z-index: 10;
            border-radius: 1px;
        }

        \(hostResetCSS(prefix: "note"))

        /* Note form — in flow, matches snapshot annotation form styling */
        .note-form {
            position: relative;
            margin: 4px 24px;
            z-index: 100;
            padding: var(--note-box-pad-y) var(--note-box-pad-x);
            border: 1px solid \(formBorder);
            border-radius: 6px;
            background: \(formBg);
            font-family: var(--note-chrome-font);
            font-size: var(--note-chrome-size);
            box-sizing: border-box;
            display: none;
            white-space: normal;
        }
        .note-form-header {
            font-size: var(--note-meta-size);
            color: \(textColor);
            margin-bottom: var(--note-header-gap);
            font-family: var(--note-text-font);
        }
        .note-textarea {
            width: 100%;
            min-height: var(--note-one-line);
            padding: var(--note-text-pad-y) var(--note-text-pad-x);
            border: 1px solid \(inputBorder);
            border-radius: 4px;
            background: var(--bg);
            color: var(--fg);
            font-family: var(--note-text-font);
            font-size: var(--note-text-size);
            line-height: var(--note-text-line-height);
            resize: none;
            overflow: hidden;
            box-sizing: border-box;
        }
        .note-textarea:focus {
            outline: none;
            border-color: rgba(88, 166, 255, 0.6);
        }
        body.file-drop-active .note-textarea,
        body.file-drop-active .note-edit-textarea {
            border-color: rgba(88, 166, 255, 0.8);
            box-shadow: 0 0 0 1px rgba(88, 166, 255, 0.3);
        }
        .note-textarea::placeholder {
            color: \(textColor);
            opacity: 1;
        }

        /* Note cards — positioned in flow after their target line.
           font-size is explicit: without it the card inherited
           through pre#terminal-content to the terminal point size,
           which is what made a saved note grow away from the 12px
           textarea it was typed in. */
        .note-card {
            position: relative;
            margin: 4px 24px;
            z-index: 90;
            background: \(cardBg);
            border: 1px solid \(cardBorder);
            border-radius: 6px;
            padding: var(--note-box-pad-y) var(--note-box-pad-x);
            font-family: var(--note-chrome-font);
            font-size: var(--note-chrome-size);
            cursor: pointer;
            box-sizing: border-box;
            white-space: normal;
        }
        .note-card:hover {
            border-color: \(cardBorderHover);
        }
        .note-card.expanded {
            border-color: var(--card-active-border);
            background: var(--card-active-bg);
        }
        .note-card-header {
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: var(--note-meta-size);
            color: \(textColor);
            margin-bottom: var(--note-header-gap);
            font-family: var(--note-text-font);
        }
        .note-card-ref,
        .note-expand-hint { font-weight: 500; }
        .note-card-meta { color: \(textColorFaint); }
        .note-card-actions {
            margin-left: auto;
            display: flex;
            gap: 6px;
            opacity: 0;
            transition: opacity 0.15s;
        }
        .note-card:hover .note-card-actions {
            opacity: 1;
        }
        .note-card-actions:has(.confirming) {
            opacity: 1;
        }
        .note-card-actions:has(.confirming) .note-btn-edit {
            display: none;
        }
        /* Hidden rather than removed: the action buttons are the
           tallest thing in the header, so dropping them from
           layout shortened the header and pulled the note text up
           as soon as editing began. Reserving the box keeps the
           chrome still. */
        .note-card:has(.note-edit-textarea) .note-card-actions {
            visibility: hidden;
        }

        /* Copy-lines affordance — sits inline next to the
           line-reference label in the form/card header.
           The host header is display:flex so the button
           slots in as a flex item. */
        \(iconButtonCSS(
            prefix: "note",
            restColor: textColor,
            hoverColor: "var(--fg)"
        ))
        .note-form-header {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .note-form-header .note-form-ref {
            flex: 0 1 auto;
        }
        /* Edit-mode hides the action row but keeps the
           header — copy lives in the header so it stays
           visible. */
        .note-card:has(.note-edit-textarea)
            .copy-button.note-copy-lines {
            opacity: 1;
        }
        /* Add-a-suggestion affordance — only shown in
           new (form) and edit states, never in show.
           Inserts the captured source text into the
           active textarea wrapped in a `suggestion`
           fenced block. Its rest and hover treatment comes
           from the shared icon-button block above; only the
           states that reveal it live here. */
        .note-form-header
            .suggest-button.note-suggest {
            display: inline-flex;
        }
        .note-card:has(.note-edit-textarea)
            .suggest-button.note-suggest {
            display: inline-flex;
            opacity: 1;
        }
        .note-card-content {
            font-size: var(--note-text-size);
            line-height: var(--note-text-line-height);
            color: var(--fg);
        }
        .note-card-content.collapsed {
            max-height: var(--note-one-line);
            overflow: hidden;
        }
        /* Editing mounts the textarea inside this element rather
           than in place of it, so its own padding and border would
           stack with the textarea's and push the text down and to
           the right. Give up the box while it is only a host —
           the textarea supplies the same inset itself, so the text
           lands where the card body had it. */
        .note-card-content:has(.note-edit-textarea) {
            padding: 0;
            border-width: 0;
        }
        \(verbatimCardCSS)
        \(selectionToolbarCSS(prefix: "note"))
        /* Sits in the header row at the end of the label group,
           rather than below the card body where appearing and
           disappearing changed the card's height — a one-line
           note would shrink as it expanded and grow back as it
           collapsed, nudging every card below it. Nothing
           follows it in that group and the action buttons are
           pinned right by their own auto margin, so it can leave
           the flow without moving anything, in either
           direction. */
        /* Font, size and colour are left to the header, and the
           weight is shared with the line reference below, so the
           hint reads as the same kind of label as the reference
           beside it and follows it if that treatment changes. */
        .note-expand-hint {
            cursor: pointer;
            white-space: nowrap;
        }
        .note-card.expanded .note-expand-hint,
        .note-card:has(.note-edit-textarea)
            .note-expand-hint {
            display: none;
        }

        /* Edit/delete buttons — match snapshot annotation style exactly */
        .note-card-actions button {
            background: none;
            border: none;
            color: \(textColor);
            cursor: pointer;
            font-size: 15px;
            padding: 3px 6px;
            border-radius: 4px;
            line-height: 1;
        }
        .note-card-actions button:hover {
            background: \(inputBg);
            color: var(--fg);
        }
        .note-card-actions .note-btn-delete {
            color: var(--delete-color);
        }
        .note-card-actions .note-btn-delete:hover {
            background: rgba(255, 59, 48, 0.1);
            color: var(--delete-color);
        }

        \(deleteConfirmCSS(prefix: "note"))

        /* Send bar */
        .send-bar {
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            height: 40px;
            background: \(sendBarBg);
            backdrop-filter: blur(8px);
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 0 16px;
            color: white;
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 13px;
            font-weight: 500;
            z-index: 1000;
            border-top: 1px solid \(sendBarBorderTop);
        }
        .send-bar-button {
            background: \(sendBtnBg);
            border: 1px solid \(sendBtnBorder);
            color: white;
            padding: 4px 12px;
            border-radius: 4px;
            cursor: pointer;
            /* The body sets `-webkit-user-select: text` + `cursor: text`,
               which inherit here. WebKit then renders the text I-beam on
               hover and lets it win over `cursor: pointer` whenever the
               button's text is selectable — the pointer only shows mid
               mouse-press. Opting the button out of selection keeps the
               pointer consistent, drag or no drag. */
            user-select: none;
            -webkit-user-select: none;
            font-weight: 600;
            font-size: 13px;
            position: relative; /* anchor for tooltip ::after */
        }
        .send-bar-button:not(:disabled):hover {
            background: rgba(255, 255, 255, 0.35);
        }
        /* Disabled look WITHOUT `opacity` — opacity would
           cascade to the ::after tooltip, washing out its
           pill background and text. Dim via color/border
           changes instead so the tooltip renders at full
           opacity. */
        .send-bar-button:disabled {
            cursor: not-allowed;
            color: rgba(255, 255, 255, 0.45);
            border-color: rgba(255, 255, 255, 0.2);
        }
        /* Instant CSS tooltip for the disabled state — the
           native `title` attribute has a multi-second OS
           delay before showing, which feels broken for a
           user actively trying to figure out why the button
           is disabled. The data-attribute is set by
           ScrollbackManager.setSendButtonState. */
        .send-bar-button[data-disabled-reason]:hover::after {
            content: attr(data-disabled-reason);
            position: absolute;
            bottom: calc(100% + 6px);
            right: 0;
            background: #2b2b2b;
            color: #fff;
            padding: 4px 8px;
            border-radius: 4px;
            border: 1px solid rgba(255, 255, 255, 0.15);
            box-shadow: 0 3px 10px rgba(0, 0, 0, 0.5);
            font-size: 11px;
            font-weight: 500;
            white-space: nowrap;
            pointer-events: none;
            z-index: 1001;
        }

        /* Edit textarea in card */
        .note-edit-textarea {
            width: 100%;
            min-height: var(--note-one-line);
            background: \(inputBg);
            border: 1px solid \(inputBorder);
            border-radius: 4px;
            color: var(--fg);
            font-family: var(--note-text-font);
            font-size: var(--note-text-size);
            line-height: var(--note-text-line-height);
            padding: var(--note-text-pad-y) var(--note-text-pad-x);
            resize: none;
            outline: none;
            box-sizing: border-box;
        }
        .note-edit-textarea:focus {
            border-color: rgba(88, 166, 255, 0.5);
        }

        \(emojiPopupCSS(
            background: formBg,
            border: cardBorder,
            shadow: "rgba(0, 0, 0, 0.3)"
        ))
        """
    }

    // MARK: - Note Manager JavaScript

    // js-validate
    // Internal for the same reason as the manager above.
    static let noteManagerJS = """
    ScrollbackManager.notes = {
        items: [],
        nextNumber: 1,
        formElement: null,
        // Card registry keyed by note id. The name predates the
        // in-flow card layout — note cards need no spacer
        // elements, so each entry holds only { card }.
        cardSpacers: {},
        editingId: null,
        expandedId: null,
        _deleteConfirmation: null,
        submitting: false,
        deleting: false,
        highlightedLines: [],
        formStartLine: null,
        formEndLine: null,
        // True while the form is showing only its header row as a
        // toolbar over a live selection, with no textarea and
        // nothing focused.
        selectionOnly: false,
        pendingEditCancelId: null,
        pendingEditOriginalContent: null,
        editIconSVG: window.GalaxyCardText.EDIT_ICON_SVG,
        deleteIconSVG: window.GalaxyCardText.DELETE_ICON_SVG,

        initialize() {
            const self = this;

            // Drag-select detection
            document.addEventListener('mouseup', (e) => {
                // Ignore clicks on note UI elements
                if (e.target.closest('.note-form') ||
                    e.target.closest('.send-bar')) return;
                // A click on an existing card expands it, so a
                // toolbar over some other range is no longer
                // about anything the user is looking at.
                if (e.target.closest('.note-card')) {
                    if (self.selectionOnly) {
                        self.hideForm();
                        self.clearHighlights();
                    }
                    return;
                }

                const sel = window.getSelection();
                // A plain click collapses the selection. Nothing
                // needed to handle this before, because the
                // selection was destroyed the moment it was read.
                if (!sel || sel.isCollapsed) {
                    if (self.selectionOnly) {
                        self.hideForm();
                        self.clearHighlights();
                    }
                    return;
                }

                const range = sel.getRangeAt(0);
                const startLine = self.findLineElement(range.startContainer);
                const endLine = self.findLineElement(range.endContainer);

                // Landed somewhere with no line. Don't leave a
                // toolbar pointing at a range the user has moved
                // away from.
                if (!startLine || !endLine) {
                    if (self.selectionOnly) {
                        self.hideForm();
                        self.clearHighlights();
                    }
                    return;
                }

                const startIdx = parseInt(startLine.dataset.line);
                const endIdx = parseInt(endLine.dataset.line);

                const lo = Math.min(startIdx, endIdx);
                const hi = Math.max(startIdx, endIdx);

                // Guard: only a form being written into can lose
                // work. A toolbar holds nothing, so re-pointing it
                // at a new range needs no confirmation.
                if (self.formElement
                    && self.formElement.style.display !== 'none'
                    && !self.selectionOnly) {
                    const ta = self.formElement
                        .querySelector('textarea');
                    if (ta && ta.value.trim()) {
                        window.webkit.messageHandlers.scrollback
                            .postMessage({
                                action: 'confirmDragReplace',
                                startLine: lo,
                                endLine: hi
                            });
                        sel.removeAllRanges();
                        return;
                    }
                }

                // The selection deliberately survives: it is what
                // a plain Cmd+C acts on, and what tells the user
                // that copying is available right now.
                self.showSelectionToolbar(lo, hi);
            });

            // Send bar click
            document.getElementById('send-bar-button').addEventListener('click', () => {
                self.sendToClaude();
            });
        },

        findLineElement(node) {
            let el = node.nodeType === 3 ? node.parentElement : node;
            while (el && !el.classList.contains('tl')) {
                el = el.parentElement;
            }
            return el;
        },

        // --- Form Management ---

        // Toolbar to form, from the add-note button or Enter.
        promoteToForm() {
            if (!this.selectionOnly) return;
            this.selectionOnly = false;
            this.formElement.classList.remove(
                'selection-only');
            const ta = this.formElement
                .querySelector('textarea');
            if (ta) {
                ta.style.height = 'auto';
                ta.style.height = ta.scrollHeight + 'px';
                ta.focus();
            }
        },

        // Every selection lands here, whatever was on screen
        // before: the toolbar is the only thing a range opens.
        // Reaching the form is a separate, deliberate step, so
        // nothing here focuses anything — focusing would collapse
        // the browser selection the user still needs for Cmd+C.
        showSelectionToolbar(startLine, endLine) {
            this.clearHighlights();
            for (let i = startLine; i <= endLine; i++) {
                const line = document.querySelector('[data-line=\"' + i + '\"]');
                if (line) {
                    line.classList.add('note-highlight');
                    this.highlightedLines.push(line);
                }
            }

            if (!this.formElement) {
                this.createForm();
            }

            this.formStartLine = startLine;
            this.formEndLine = endLine;

            // Update header — match snapshot style: "Note #N: line N"
            const ref = this.formElement.querySelector('.note-form-ref');
            if (startLine === endLine) {
                ref.textContent = 'Note #' + this.nextNumber + ': line ' + (startLine + 1);
            } else {
                ref.textContent = 'Note #' + this.nextNumber + ': lines ' + (startLine + 1) + '\\u2013' + (endLine + 1);
            }

            this.selectionOnly = true;
            this.formElement.classList.add('selection-only');

            this.positionForm(endLine);
            this.formElement.style.display = 'block';
            const ta = this.formElement.querySelector('textarea');
            ta.value = '';
            ta.style.height = 'auto';
        },

        // Per-textarea auto-grow, kept off the keystroke hot path.
        //
        // The textarea lives inside the scrollback document, which
        // holds the entire frozen terminal buffer (up to 100K lines
        // per the terminalScrollbackLines setting). Reading
        // scrollHeight forces a synchronous layout across that whole
        // DOM, so a naive per-input resize causes keystroke lag on
        // long-running sessions whose buffer has filled up.
        //
        // Structural edits resize immediately: a typed newline, or a
        // bulk insert from paste/dictation/drop where the length jumps
        // by more than one. Ordinary single-character typing is
        // debounced — the resize fires WAIT ms after the last
        // keystroke, so a continuous burst or a held key-repeat
        // coalesces into a single layout once typing settles, and a
        // soft wrap grows the field on the next pause. MAX_WAIT caps
        // the debounce so an unbroken burst still resizes at least
        // every MAX_WAIT ms, bounding how long a wrapped line sits
        // clipped behind overflow:hidden.
        //
        // Trackers update on every input so the next delta is measured
        // against the true previous length.
        installAutosize(ta) {
            window.GalaxyCardText.installAutosize(ta);
        },

        createForm() {
            this.formElement = document.createElement('div');
            this.formElement.className = 'note-form';
            // The form is display:none until a selection
            // is made (showSelectionToolbar sets
            // formElement.style.display = 'block'), so the
            // copy button is naturally invisible until
            // there's a range to copy.
            const formCopyHTML =
                (typeof window.GalaxyClipboard
                    === 'undefined')
                    ? ''
                    : window.GalaxyClipboard.buttonHTML(
                        'note-copy-lines', 'Copy lines');
            const formSuggestHTML =
                (typeof window.GalaxySuggestion
                    === 'undefined')
                    ? ''
                    : window.GalaxySuggestion.buttonHTML(
                        'note-suggest',
                        'Add a suggestion');
            // Promotes the selection toolbar into this form.
            const formAddNoteHTML =
                (typeof window.GalaxyAddNote
                    === 'undefined')
                    ? ''
                    : window.GalaxyAddNote.buttonHTML(
                        'note-addnote',
                        'Add a note');
            this.formElement.innerHTML =
                '<div class="note-form-header">' +
                    '<span class="note-form-ref"></span>' +
                    formCopyHTML +
                    formSuggestHTML +
                    formAddNoteHTML +
                '</div>' +
                window.GalaxyCardText.composerTextareaHTML(
                    'note-textarea',
                    { placeholder: 'Add note\\u2026', hint: 'save' }
                );

            // Don't append to DOM yet — positionForm() will place it
            const self = this;
            const ta = this.formElement.querySelector('textarea');

            // Wire the form's copy-lines button. Reads the
            // pending selection's text via pendingFormText.
            const formCopyBtn = this.formElement
                .querySelector('.note-copy-lines');
            if (formCopyBtn
                && window.GalaxyClipboard) {
                window.GalaxyClipboard.bindCopyButton(
                    formCopyBtn,
                    () => self.pendingFormText(),
                    'Copy lines'
                );
            }

            // Wire the form's suggestion-insert button.
            // Reuses pendingFormText so the suggestion
            // block matches the would-be saved
            // lineContent byte-for-byte.
            const formSuggestBtn = this.formElement
                .querySelector('.note-suggest');
            if (formSuggestBtn
                && window.GalaxySuggestion) {
                window.GalaxySuggestion.bindSuggestionButton(
                    formSuggestBtn,
                    () => self.pendingFormText(),
                    () => this.formElement
                        .querySelector('textarea')
                );
            }

            // Promote the toolbar into this form. Only visible
            // while the form is in its selection-only state.
            const formAddNoteBtn = this.formElement
                .querySelector('.note-addnote');
            if (formAddNoteBtn && window.GalaxyAddNote) {
                window.GalaxyAddNote.bindAddNoteButton(
                    formAddNoteBtn,
                    () => self.promoteToForm()
                );
            }

            // Escape is claimed here so it cannot reach the overlay's own key
            // handler, which would exit scrollback out from under an open form.
            window.GalaxyCardText.bindCardComposer(ta, {
                onSubmit: () => { self.submitNote(); },
                onEscape: () => { self.handleFormEscape(ta); }
            });

            // Auto-grow/shrink textarea via the rAF-deferred
            // helper so per-keystroke scrollHeight reads don't
            // block typing in long-buffer sessions.
            this.installAutosize(ta);

            // Attach emoji autocomplete
            if (typeof EmojiAutocomplete !== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }
        },

        handleFormEscape(ta) {
            // Check emoji popup first
            if (typeof EmojiAutocomplete !== 'undefined' &&
                EmojiAutocomplete.isActive(ta)) {
                EmojiAutocomplete.dismiss(ta);
                return;
            }
            if (ta.value.trim().length > 0) {
                // Has content — ask Swift for confirmation via NSAlert
                window.webkit.messageHandlers.scrollback.postMessage({
                    action: 'confirmDiscardForm'
                });
            } else {
                this.hideForm();
                this.clearHighlights();
            }
        },

        focusForm() {
            if (!this.formElement
                || this.formElement.style.display === 'none') return;
            const ta = this.formElement.querySelector('textarea');
            if (ta) ta.focus();
        },

        forceDiscardForm() {
            if (this.formElement) {
                var ta = this.formElement.querySelector('textarea');
                if (ta) {
                    ta.value = '';
                    ta.style.height = 'auto';
                }
                this.hideForm();
                this.clearHighlights();
            }
        },

        positionForm(endLine) {
            // Remove form from current position
            if (this.formElement.parentNode) {
                this.formElement.remove();
            }

            const endLineEl = document.querySelector('[data-line=\"' + endLine + '\"]');
            if (!endLineEl) return;

            // Insert form in flow after end line (after any existing cards)
            const insertPoint = this.findInsertPoint(endLineEl);
            insertPoint.after(this.formElement);
        },

        hideForm() {
            if (this.formElement) {
                this.formElement.style.display = 'none';
                this.formElement.classList.remove(
                    'selection-only');
            }
            this.selectionOnly = false;
        },

        // Lift text from the rendered scrollback for the
        // current pending selection. Single source of
        // truth for both submitNote (sent to Swift as the
        // note's lineContent) and the form's copy-lines
        // affordance (so what the user copies pre-submit
        // matches exactly what gets saved).
        pendingFormText() {
            if (this.formStartLine == null
                || this.formEndLine == null) return '';
            let out = '';
            for (let i = this.formStartLine;
                 i <= this.formEndLine; i++) {
                const line = document.querySelector(
                    '[data-line=\"' + i + '\"]');
                if (line) {
                    if (out) out += '\\n';
                    out += line.textContent;
                }
            }
            return out;
        },

        submitNote() {
            if (this.submitting) return;

            const ta = this.formElement.querySelector('textarea');
            const content = ta.value.trim();
            if (!content) return;

            this.submitting = true;

            // Extract line content from DOM via the
            // shared helper (also used by the copy-lines
            // affordance so the two paths stay in sync).
            const lineContent = this.pendingFormText();

            // Post to Swift
            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'createNote',
                startLine: this.formStartLine,
                endLine: this.formEndLine,
                lineContent: lineContent,
                content: content
            });

            // Clear form
            ta.value = '';
            ta.style.height = 'auto';
            this.hideForm();
            this.clearHighlights();
        },

        // --- Card Management ---

        noteCreated(note) {
            this.submitting = false;

            // Assign number if not present
            if (!note.number) {
                note.number = this.nextNumber;
            }
            this.nextNumber = Math.max(this.nextNumber, note.number + 1);

            // Check for duplicate (from restoreNoteState)
            if (this.items.find(n => n.id === note.id)) return;

            this.items.push(note);
            this.insertCard(note);
            this.updateSendBar();
        },

        noteUpdated(note) {
            this.submitting = false;

            const idx = this.items.findIndex(n => n.id === note.id);
            if (idx >= 0) {
                this.items[idx].content = note.content;
            }
            // Update card content display. Splice the Swift-rendered
            // markdown HTML straight into the body — same pipeline that
            // feeds artifact/snapshot annotation cards.
            const idx2 = this.items.findIndex(n => n.id === note.id);
            if (idx2 >= 0) {
                this.items[idx2].renderedHTML = note.renderedHTML;
            }
            const card = document.querySelector('[data-note-id=\"' + note.id + '\"]');
            if (card) {
                const contentEl = card.querySelector('.note-card-content');
                if (contentEl) {
                    contentEl.innerHTML = note.renderedHTML;
                }
            }
            this.editingId = null;
        },

        noteDeleted(id) {
            this.deleteConfirmation().finish();

            this.items = this.items.filter(n => n.id !== id);

            // Remove card
            const entry = this.cardSpacers[id];
            if (entry) {
                if (entry.card) entry.card.remove();
                delete this.cardSpacers[id];
            }

            // Clear expanded state if this was expanded
            if (this.expandedId === id) {
                this.expandedId = null;
                this.clearExpandHighlights();
            }

            this.updateSendBar();
        },

        insertCard(note) {
            const endLineEl = document.querySelector('[data-line=\"' + note.endLine + '\"]');
            if (!endLineEl) return;

            // Create card in flow after end line (after existing cards)
            const card = this.buildCardElement(note);
            const insertPoint = this.findInsertPoint(endLineEl);
            insertPoint.after(card);

            this.cardSpacers[note.id] = { card: card };
        },

        buildCardElement(note) {
            const self = this;
            const card = document.createElement('div');
            card.className = 'note-card';
            card.dataset.noteId = note.id;

            const refText = note.startLine === note.endLine
                ? 'Line ' + (note.startLine + 1)
                : 'Lines ' + (note.startLine + 1) + '–' + (note.endLine + 1);

            // Copy-lines button — placed between the
            // meta `#N` span and the action row so it
            // juxtaposes the line-reference label.
            const cardCopyHTML =
                (typeof window.GalaxyClipboard
                    === 'undefined')
                    ? ''
                    : window.GalaxyClipboard.buttonHTML(
                        'note-copy-lines', 'Copy lines');
            // Suggestion-insert button. Always rendered;
            // CSS hides it in the show state and reveals
            // it only while an edit textarea is active.
            const cardSuggestHTML =
                (typeof window.GalaxySuggestion
                    === 'undefined')
                    ? ''
                    : window.GalaxySuggestion.buttonHTML(
                        'note-suggest',
                        'Add a suggestion');

            card.innerHTML =
                '<div class="note-card-header">' +
                    '<span class="note-card-ref">' + refText + '</span>' +
                    '<span class="note-card-meta">#' + note.number + '</span>' +
                    cardCopyHTML +
                    cardSuggestHTML +
                    '<span class="note-expand-hint">Click to expand</span>' +
                    '<span class="note-card-actions">' +
                        '<button class="note-btn-edit" title="Edit">' +
                            self.editIconSVG + '</button>' +
                        '<button class="note-btn-delete" title="Delete">' +
                            self.deleteIconSVG + '</button>' +
                    '</span>' +
                '</div>' +
                '<pre class="note-card-content verbatim-card-content collapsed">' +
                    note.renderedHTML +
                '</pre>';

            // Click to expand/collapse
            card.addEventListener('click', (e) => {
                if (e.target.closest('.note-btn-edit') ||
                    e.target.closest('.note-btn-delete') ||
                    e.target.closest('.note-copy-lines') ||
                    e.target.closest('.note-suggest') ||
                    e.target.closest('.note-edit-textarea')) return;
                self.toggleExpand(note.id);
            });

            // Edit button
            card.querySelector('.note-btn-edit').addEventListener('click', (e) => {
                e.stopPropagation();
                self.startEdit(note.id);
            });

            // Delete button
            card.querySelector('.note-btn-delete').addEventListener('click', (e) => {
                e.stopPropagation();
                self.handleDelete(note.id);
            });

            // Copy-lines button. Notes always carry
            // lineContent because they always anchor to a
            // line range — read it directly off the note
            // object.
            const cardCopyBtn = card.querySelector(
                '.note-copy-lines');
            if (cardCopyBtn
                && window.GalaxyClipboard) {
                window.GalaxyClipboard.bindCopyButton(
                    cardCopyBtn,
                    () => note.lineContent || '',
                    'Copy lines'
                );
            }

            // Suggestion-insert button. Looks up the
            // edit textarea at click time so it picks up
            // whatever startEdit just mounted.
            const cardSuggestBtn = card.querySelector(
                '.note-suggest');
            if (cardSuggestBtn
                && window.GalaxySuggestion) {
                window.GalaxySuggestion.bindSuggestionButton(
                    cardSuggestBtn,
                    () => note.lineContent || '',
                    () => card.querySelector(
                        '.note-edit-textarea')
                );
            }

            // Suppress the 2nd click of a double-click so it doesn't
            // toggle expand. Capture phase + stopImmediatePropagation
            // ensures this runs before the bubble-phase toggle handler
            // and prevents it from firing on the 2nd click.
            card.addEventListener('click', (e) => {
                if (e.detail >= 2) e.stopImmediatePropagation();
            }, true);

            // Double-click anywhere on the card → enter edit, same path
            // as the pencil icon. Same exclusions as the toggle handler.
            card.addEventListener('dblclick', (e) => {
                if (e.target.closest('.note-btn-edit') ||
                    e.target.closest('.note-btn-delete') ||
                    e.target.closest('.note-copy-lines') ||
                    e.target.closest('.note-suggest') ||
                    e.target.closest('.note-edit-textarea')) return;
                self.startEdit(note.id);
            });

            return card;
        },

        // --- Expand/Collapse ---

        toggleExpand(noteId) {
            if (this.editingId) return;

            const card = document.querySelector('[data-note-id=\"' + noteId + '\"]');
            if (!card) return;
            const contentEl = card.querySelector('.note-card-content');

            if (this.expandedId === noteId) {
                // Collapse
                card.classList.remove('expanded');
                if (contentEl) contentEl.classList.add('collapsed');
                this.expandedId = null;
                this.clearExpandHighlights();
            } else {
                // Collapse previous
                if (this.expandedId) {
                    const prev = document.querySelector('[data-note-id=\"' + this.expandedId + '\"]');
                    if (prev) {
                        prev.classList.remove('expanded');
                        const prevContent = prev.querySelector('.note-card-content');
                        if (prevContent) prevContent.classList.add('collapsed');
                    }
                    this.clearExpandHighlights();
                }

                // Expand this — yellow border on card, show full content,
                // yellow highlight on referenced lines
                card.classList.add('expanded');
                if (contentEl) contentEl.classList.remove('collapsed');
                this.expandedId = noteId;

                const note = this.items.find(n => n.id === noteId);
                if (note) {
                    for (let i = note.startLine; i <= note.endLine; i++) {
                        const line = document.querySelector('[data-line=\"' + i + '\"]');
                        if (line) line.classList.add('note-expanded-highlight');
                    }
                }
            }
        },

        clearExpandHighlights() {
            document.querySelectorAll('.note-expanded-highlight').forEach(el => {
                el.classList.remove('note-expanded-highlight');
            });
        },

        // --- Edit ---

        startEdit(noteId) {
            const note = this.items.find(n => n.id === noteId);
            if (!note) return;

            const card = document.querySelector('[data-note-id=\"' + noteId + '\"]');
            if (!card) return;

            // Expand if not already
            if (this.expandedId !== noteId) {
                this.toggleExpand(noteId);
            }

            this.editingId = noteId;

            // Replace content with textarea
            const contentEl = card.querySelector('.note-card-content');
            const originalContent = note.content;
            contentEl.innerHTML = '';
            contentEl.classList.remove('collapsed');

            const ta = window.GalaxyCardText.createComposerTextarea(
                'note-edit-textarea', originalContent, 2
            );
            contentEl.appendChild(ta);

            // Auto-size
            ta.style.height = 'auto';
            ta.style.height = ta.scrollHeight + 'px';

            const self = this;

            window.GalaxyCardText.bindCardComposer(ta, {
                onSubmit: () => { self.saveEdit(noteId, ta.value); },
                onEscape: () => {
                    // An open emoji popup owns Escape before the edit does —
                    // dismissing the popup is what the user means, not
                    // abandoning what they have typed.
                    if (typeof EmojiAutocomplete !== 'undefined' &&
                        EmojiAutocomplete.isActive(ta)) {
                        EmojiAutocomplete.dismiss(ta);
                        return;
                    }
                    if (ta.value !== originalContent) {
                        // Has changes — ask Swift for confirmation
                        self.pendingEditCancelId = noteId;
                        self.pendingEditOriginalContent = originalContent;
                        window.webkit.messageHandlers.scrollback.postMessage({
                            action: 'confirmDiscardEdit'
                        });
                    } else {
                        self.cancelEdit(noteId, originalContent);
                    }
                }
            });

            // Auto-grow/shrink textarea via the rAF-deferred
            // helper so per-keystroke scrollHeight reads don't
            // block typing in long-buffer sessions.
            this.installAutosize(ta);

            // Attach emoji autocomplete
            if (typeof EmojiAutocomplete !== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            ta.focus();
        },

        saveEdit(noteId, newContent) {
            if (this.submitting) return;

            const trimmed = newContent.trim();
            if (!trimmed) return;

            this.submitting = true;

            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'updateNote',
                id: noteId,
                content: trimmed
            });
        },

        cancelEdit(noteId, originalContent) {
            this.editingId = null;
            const card = document.querySelector('[data-note-id=\"' + noteId + '\"]');
            if (!card) return;

            const contentEl = card.querySelector('.note-card-content');
            contentEl.innerHTML = '';
            contentEl.textContent = originalContent;
        },

        forceDiscardEdit() {
            if (this.pendingEditCancelId) {
                this.cancelEdit(this.pendingEditCancelId, this.pendingEditOriginalContent);
                this.pendingEditCancelId = null;
                this.pendingEditOriginalContent = null;
            }
        },

        // --- Delete ---

        // The machine is shared; locating this surface's button and telling
        // this surface's host are not. Built on first use so it does not
        // depend on where initialize() happens to run.
        deleteConfirmation() {
            if (!this._deleteConfirmation) {
                this._deleteConfirmation =
                    window.GalaxyCardText.createDeleteConfirmation({
                        findButton: (noteId) => {
                            const card = document.querySelector(
                                '[data-note-id=\"' + noteId + '\"]'
                            );
                            return card
                                ? card.querySelector('.note-btn-delete')
                                : null;
                        },
                        onConfirmed: (noteId) => {
                            window.webkit.messageHandlers.scrollback
                                .postMessage({
                                    action: 'deleteNote',
                                    id: noteId
                                });
                        }
                    });
            }
            return this._deleteConfirmation;
        },

        handleDelete(noteId) {
            this.deleteConfirmation().handleClick(noteId);
        },

        // --- Highlight Management ---

        clearHighlights() {
            this.highlightedLines.forEach(el => {
                el.classList.remove('note-highlight');
            });
            this.highlightedLines = [];
        },

        // --- Position Sync ---

        findInsertPoint(lineEl) {
            // Walk siblings after the line to find the last card/form,
            // so new items stack after existing ones
            let point = lineEl;
            let next = point.nextElementSibling;
            while (next && (next.classList.contains('note-card') ||
                            next.classList.contains('note-form'))) {
                point = next;
                next = point.nextElementSibling;
            }
            return point;
        },

        // --- Send Bar ---

        updateSendBar() {
            const bar = document.getElementById('send-bar');
            const count = document.getElementById('send-bar-count');
            if (this.items.length > 0) {
                bar.style.display = 'flex';
                const n = this.items.length;
                count.textContent = n + ' note' + (n === 1 ? '' : 's');
            } else {
                bar.style.display = 'none';
            }
        },

        sendToClaude(force) {
            if (this.items.length === 0) return;

            // Guard: an open note form or in-progress edit holds
            // comment text that Send would silently drop (only
            // committed notes ship). Ask Swift to confirm before
            // discarding it, mirroring the drag-replace guard.
            if (!force && this.hasOpenUnsavedComment()) {
                window.webkit.messageHandlers.scrollback
                    .postMessage({
                        action: 'confirmSendWithUnsavedComment'
                    });
                return;
            }

            const sorted = [...this.items].sort((a, b) =>
                a.endLine - b.endLine || a.startLine - b.startLine);
            const message = sorted.map((note, i) => {
                const n = i + 1;
                return '[' + n + ']\\n'
                    + '```\\n' + note.lineContent + '\\n```\\n'
                    + note.content;
            }).join('\\n\\n\\n');

            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'sendToClaude',
                message: message
            });
        },

        hasUnsavedWork() {
            // Submitted notes that haven't been sent to Claude
            if (this.items.length > 0) return true;
            return this.hasOpenUnsavedComment();
        },

        // True only for comment text that Send to Claude would
        // silently drop: an open note form with typed text, or an
        // in-progress edit with unsaved changes. Excludes committed
        // notes (this.items) — those ARE what Send ships.
        hasOpenUnsavedComment() {
            // New note form open with content
            if (this.formElement
                && this.formElement.style.display !== 'none') {
                const ta = this.formElement
                    .querySelector('textarea');
                if (ta && ta.value.trim().length > 0) return true;
            }
            // Edit in progress with changes
            if (this.editingId) {
                const card = document.querySelector(
                    '[data-note-id="' + this.editingId + '"]'
                );
                if (card) {
                    const ta = card.querySelector(
                        '.note-edit-textarea'
                    );
                    const note = this.items.find(
                        n => n.id === this.editingId
                    );
                    if (ta && note
                        && ta.value !== note.content) {
                        return true;
                    }
                }
            }
            return false;
        }
    };

    function handleFileDrop(paths) {
        // Which textarea receives the drop is this surface's own question —
        // the create form if it is open, otherwise the note being edited.
        // Everything after that is the same on both card surfaces.
        var ta = null;
        var notes = ScrollbackManager.notes;

        if (notes.formElement
            && notes.formElement.style.display !== 'none') {
            ta = notes.formElement.querySelector('textarea');
        }
        if (!ta && notes.editingId) {
            ta = document.querySelector('.note-edit-textarea');
        }

        window.GalaxyCardText.insertPaths(ta, paths);
    }
    """

    // MARK: - HTML Escaping

    private static func htmlEscape(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }
}

// MARK: - Color Resolver

extension ScrollbackHTMLRenderer {

    /// Resolves `ScrollbackColor` values to CSS hex strings using the same
    /// logic as SwiftTerm's `mapColor()` in AppleTerminalView. The first 16
    /// palette entries come from the theme's `ansiColors`; 16-231 are the
    /// 6×6×6 RGB cube; 232-255 are the grayscale ramp.
    struct ColorResolver {
        let theme: TerminalColorTheme
        private let palette: [String]  // 256 hex colors

        init(theme: TerminalColorTheme) {
            self.theme = theme
            var p = [String]()
            p.reserveCapacity(256)

            // First 16 from theme
            for hex in theme.ansiColors {
                p.append(hex)
            }

            // 216 color cube (indices 16-231)
            for r in 0..<6 {
                for g in 0..<6 {
                    for b in 0..<6 {
                        let rv = r > 0 ? r * 40 + 55 : 0
                        let gv = g > 0 ? g * 40 + 55 : 0
                        let bv = b > 0 ? b * 40 + 55 : 0
                        p.append(String(format: "#%02X%02X%02X", rv, gv, bv))
                    }
                }
            }

            // 24 grayscale (indices 232-255)
            for i in 0..<24 {
                let v = i * 10 + 8
                p.append(String(format: "#%02X%02X%02X", v, v, v))
            }

            self.palette = p
        }

        /// Resolve foreground color. Returns nil to use the CSS default (--fg).
        func fgColor(_ color: ScrollbackColor, isBold: Bool) -> String? {
            switch color {
            case .defaultColor:
                // Bold + default fg → use bold foreground color from theme
                if isBold {
                    return theme.boldForeground ?? theme.ansiColors[15]
                }
                return nil  // Use CSS var(--fg)

            case .defaultInvertedColor:
                // Inverted default — return background color as foreground
                return theme.background

            case .ansi256(let code):
                let idx: Int
                // Bright promotion: bold + normal color (0-7) → bright (8-15)
                if isBold && code < 8 {
                    idx = Int(code) + 8
                } else {
                    idx = Int(code)
                }
                guard idx < palette.count else { return nil }
                return palette[idx]

            case .trueColor(let r, let g, let b):
                return String(format: "#%02X%02X%02X", r, g, b)
            }
        }

        /// Resolve background color. Returns nil for transparent (theme default bg).
        func bgColor(_ color: ScrollbackColor) -> String? {
            switch color {
            case .defaultColor, .defaultInvertedColor:
                return nil  // Transparent — inherits body background

            case .ansi256(let code):
                let idx = Int(code)
                guard idx < palette.count else { return nil }
                return palette[idx]

            case .trueColor(let r, let g, let b):
                return String(format: "#%02X%02X%02X", r, g, b)
            }
        }
    }
}
