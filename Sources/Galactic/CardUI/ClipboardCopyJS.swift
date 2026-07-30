import Foundation

// MARK: - Shared JS-side clipboard helper
//
// Defines `window.GalaxyClipboard`, used by any WKWebView
// module that wants a "copy" button. The icon SVGs match the
// SwiftUI `doc.on.doc` SF Symbol used by `CopyButton.swift`
// in the Snapshots / Artifacts list toolbars, so the
// affordance reads as "the same thing, in a new spot."
//
// Inject ahead of any module that calls into
// `GalaxyClipboard` (annotation manager, scrollback notes
// manager). Idempotent — calls through `if (window
// .GalaxyClipboard) return;` so a second injection is a
// no-op.

// js-validate
public let clipboardCopyJS: String = """
(function() {
    if (window.GalaxyClipboard) return;

    var COPY_ICON_SVG =
        '<svg class="copy-icon" width="14"'
        + ' height="14" viewBox="0 0 16 16"'
        + ' aria-hidden="true">'
        + '<path fill="currentColor"'
        + ' d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75'
        + ' 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c'
        + '0 .138.112.25.25.25h7.5a.25.25 0 0 0 .'
        + '25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1'
        + '.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 '
        + '14.25Z"/>'
        + '<path fill="currentColor"'
        + ' d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15'
        + '.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 '
        + '1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1'
        + '.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.11'
        + '2.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a'
        + '.25.25 0 0 0-.25-.25Z"/>'
        + '</svg>';

    // Outlined bookmark — a kept location. Stroked to match
    // the add-note bubble rather than the filled copy glyph
    // beside it, so the two copy actions read as different
    // things at a glance.
    var REF_ICON_SVG =
        '<svg class="copy-icon" width="14"'
        + ' height="14" viewBox="0 0 16 16"'
        + ' fill="none" stroke="currentColor"'
        + ' stroke-width="1.5" stroke-linejoin="round"'
        + ' aria-hidden="true">'
        + '<path d="M4.3 2.2h7.4a.9.9 0 0 1 .9.9v10.8'
        + 'l-4.6-2.9-4.6 2.9V3.1a.9.9 0 0 1 .9-.9Z"/>'
        + '</svg>';

    var CHECK_ICON_SVG =
        '<svg class="copy-icon" width="14"'
        + ' height="14" viewBox="0 0 16 16"'
        + ' aria-hidden="true">'
        + '<path fill="currentColor"'
        + ' d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25'
        + ' 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.751'
        + '.751 0 0 1 .018-1.042.751.751 0 0 1 1.04'
        + '2-.018L6 10.94l6.72-6.72a.75.75 0 0 1 1'
        + '.06 0Z"/>'
        + '</svg>';

    function copyLegacy(text) {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.top = '-1000px';
        ta.style.left = '-1000px';
        document.body.appendChild(ta);
        ta.select();
        var ok = false;
        try { ok = document.execCommand('copy'); }
        catch (err) { ok = false; }
        document.body.removeChild(ta);
        return ok;
    }

    // Strip trailing whitespace from every line, plus
    // trailing blank lines at end-of-string. Terminal
    // scrollback rows are right-padded with spaces to the
    // column width — pasting that padding into editors /
    // PR descriptions / notes is annoying, and almost
    // never what the user wants. Leading whitespace is
    // preserved so indentation survives.
    function trimTrailingWhitespace(text) {
        if (typeof text !== 'string') return '';
        var lines = text.split('\\n');
        for (var i = 0; i < lines.length; i++) {
            lines[i] = lines[i].replace(/[ \\t]+$/, '');
        }
        // Drop empty lines at the very end so the
        // copied text doesn't paste with blank trailing
        // rows.
        while (lines.length > 0
            && lines[lines.length - 1] === '') {
            lines.pop();
        }
        return lines.join('\\n');
    }

    // Modern path with legacy fallback. Resolves true on
    // success, false otherwise. Never rejects. Trims
    // trailing whitespace before writing — see
    // trimTrailingWhitespace for why.
    function copy(text) {
        var cleaned = trimTrailingWhitespace(text);
        return new Promise(function(resolve) {
            if (navigator.clipboard
                && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(cleaned)
                    .then(
                        function() { resolve(true); },
                        function() {
                            resolve(copyLegacy(cleaned));
                        }
                    );
            } else {
                resolve(copyLegacy(cleaned));
            }
        });
    }

    function showCopiedFeedback(btn, defaultTitle) {
        // Remember whichever glyph this button started with.
        // More than one icon uses this path now, and reverting
        // to a named one would quietly turn a reference button
        // into a copy button once its confirmation faded.
        if (!btn._restoreIcon) {
            btn._restoreIcon = btn.innerHTML;
        }
        btn.classList.add('copied');
        btn.innerHTML = CHECK_ICON_SVG;
        btn.setAttribute('title', 'Copied!');
        btn.setAttribute('aria-label', 'Copied!');
        if (btn._copyResetTimer) {
            clearTimeout(btn._copyResetTimer);
        }
        btn._copyResetTimer = setTimeout(function() {
            btn.classList.remove('copied');
            btn.innerHTML = btn._restoreIcon;
            btn.setAttribute('title', defaultTitle);
            btn.setAttribute('aria-label', defaultTitle);
            btn._copyResetTimer = null;
        }, 1500);
    }

    // Returns an HTML string for a copy button. Caller
    // chooses a class (e.g. 'note-copy-lines') and a
    // default tooltip title.
    function buttonHTML(className, defaultTitle) {
        return '<button type="button" class="copy-button '
            + className + '" title="' + defaultTitle
            + '" aria-label="' + defaultTitle + '">'
            + COPY_ICON_SVG + '</button>';
    }

    // Same button, bookmark glyph. Carries `copy-button` so it
    // inherits the shared icon treatment, and is wired with
    // bindCopyButton like any other — only the text it produces
    // differs.
    function refButtonHTML(className, defaultTitle) {
        return '<button type="button" class="copy-button '
            + className + '" title="' + defaultTitle
            + '" aria-label="' + defaultTitle + '">'
            + REF_ICON_SVG + '</button>';
    }

    // Wires a click handler on `btn`. `getText` is a
    // function that returns the (possibly recomputed) text
    // to copy at click time. Click handler stops
    // propagation so a click doesn't also trigger a
    // parent card's expand/edit.
    function bindCopyButton(btn, getText, defaultTitle) {
        btn.addEventListener('click', function(e) {
            e.stopPropagation();
            var text;
            try { text = getText(); }
            catch (err) { text = ''; }
            if (typeof text !== 'string'
                || text.length === 0) return;
            copy(text).then(function(ok) {
                if (ok) {
                    showCopiedFeedback(btn, defaultTitle);
                }
            });
        });
        // Block dblclick from triggering a parent card's
        // double-click → edit handler.
        btn.addEventListener('dblclick', function(e) {
            e.stopPropagation();
        });
    }

    window.GalaxyClipboard = {
        COPY_ICON_SVG: COPY_ICON_SVG,
        CHECK_ICON_SVG: CHECK_ICON_SVG,
        REF_ICON_SVG: REF_ICON_SVG,
        copy: copy,
        showCopiedFeedback: showCopiedFeedback,
        buttonHTML: buttonHTML,
        refButtonHTML: refButtonHTML,
        bindCopyButton: bindCopyButton
    };
})();
"""
