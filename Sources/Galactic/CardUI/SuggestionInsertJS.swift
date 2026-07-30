import Foundation

// This file defines two shared form-header affordances:
// `window.GalaxySuggestion` below, and `window.GalaxyAddNote`
// further down. They live together because both are buttons the
// note and annotation form headers inject, and because both files
// they would otherwise need are already in two Xcode projects —
// adding a third would mean hand-editing `project.pbxproj` twice.

// MARK: - Shared JS-side suggestion-insert helper
//
// Defines `window.GalaxySuggestion`, used by note /
// annotation new + edit affordances to insert the captured
// source text into the active textarea wrapped in a
// `suggestion` fenced code block:
//
//     ```suggestion
//     {raw text}
//     ```
//
// Visual companion to `GalaxyClipboard`: reuses the same
// per-anchor-type captured-text producer
// (`AnnotationManager.capturedTextForForm` /
// `.capturedTextForAnnotation`) so what gets inserted
// matches what would be copied to the clipboard exactly,
// just routed into the textarea instead of the system
// pasteboard.
//
// The icon is a `±` glyph framed by a rounded rectangle,
// matching GitHub's markdown-toolbar "Add a suggestion"
// button.
//
// Idempotent — calls through `if (window.GalaxySuggestion)
// return;` so a second injection is a no-op.

// js-validate
public let suggestionInsertJS: String = """
(function() {
    if (window.GalaxySuggestion) return;

    // Bold "+" glyph — two pill-rounded bars filling the
    // full viewBox so the icon's visual weight reads on
    // par with the Octicons-style filled copy icon next
    // to it. Sized 14x14 to match the copy icon exactly.
    var SUGGEST_ICON_SVG =
        '<svg class="suggest-icon" width="14"'
        + ' height="14" viewBox="0 0 16 16"'
        + ' fill="currentColor" aria-hidden="true">'
        + '<rect x="6.75" y="1" width="2.5"'
        + ' height="14" rx="1.25"/>'
        + '<rect x="1" y="6.75" width="14"'
        + ' height="2.5" rx="1.25"/>'
        + '</svg>';

    // Trim per-line trailing whitespace and drop trailing
    // empty lines so the inner block doesn't carry the
    // padding spaces terminal scrollback rows include —
    // mirrors the cleanup `GalaxyClipboard.copy` performs
    // before writing to the clipboard.
    function trimTrailing(text) {
        if (typeof text !== 'string') return '';
        var lines = text.split('\\n');
        for (var i = 0; i < lines.length; i++) {
            lines[i] = lines[i].replace(/[ \\t]+$/, '');
        }
        while (lines.length > 0
            && lines[lines.length - 1] === '') {
            lines.pop();
        }
        return lines.join('\\n');
    }

    // Pick a backtick fence that can't be terminated by
    // any backtick run inside the inner text. CommonMark
    // spec: outer fence must be >= 3 backticks AND strictly
    // longer than the longest backtick run in the content.
    function chooseFence(text) {
        var longest = 0;
        var run = 0;
        for (var i = 0; i < text.length; i++) {
            if (text.charCodeAt(i) === 96 /* ` */) {
                run++;
                if (run > longest) longest = run;
            } else {
                run = 0;
            }
        }
        var len = Math.max(3, longest + 1);
        var fence = '';
        for (var k = 0; k < len; k++) fence += '`';
        return fence;
    }

    function buildSuggestion(text) {
        var inner = trimTrailing(text);
        if (!inner) return '';
        var fence = chooseFence(inner);
        return fence + 'suggestion\\n' + inner + '\\n'
            + fence;
    }

    // Append the suggestion block to the end of the
    // textarea. Smart separator picks the right number of
    // newlines so the block is preceded by a blank line
    // (standard markdown spacing) without doubling up.
    // Cursor lands inside the block on the first content
    // line so the user can edit immediately. Dispatching
    // an `input` event lets the existing autoGrow / emoji
    // autocomplete listeners react to the value change.
    function insertSuggestion(textarea, text) {
        if (!textarea) return false;
        var block = buildSuggestion(text);
        if (!block) return false;
        var existing = textarea.value || '';
        var sep;
        if (existing.length === 0) {
            sep = '';
        } else if (/\\n\\n$/.test(existing)) {
            sep = '';
        } else if (/\\n$/.test(existing)) {
            sep = '\\n';
        } else {
            sep = '\\n\\n';
        }
        var blockStart = existing.length + sep.length;
        textarea.value = existing + sep + block + '\\n';
        // Caret on the first content character: skip past
        // the opening fence + 'suggestion' tag + newline.
        var fenceMatch = block.match(/^`+/);
        var fenceLen = fenceMatch
            ? fenceMatch[0].length : 3;
        var caret = blockStart + fenceLen
            + 'suggestion'.length + 1;
        textarea.setSelectionRange(caret, caret);
        textarea.focus();
        textarea.dispatchEvent(
            new Event('input', { bubbles: true })
        );
        return true;
    }

    function buttonHTML(className, defaultTitle) {
        return '<button type="button"'
            + ' class="suggest-button '
            + className + '" title="' + defaultTitle
            + '" aria-label="' + defaultTitle + '">'
            + SUGGEST_ICON_SVG + '</button>';
    }

    // Wires a click handler on `btn`. `getText` returns
    // the source text to wrap (typically the same producer
    // the copy-lines button uses). `getTextarea` returns
    // the target textarea — the form textarea while the
    // form is open, or the in-card edit textarea when
    // editing an existing note/annotation.
    function bindSuggestionButton(
        btn, getText, getTextarea
    ) {
        btn.addEventListener('click', function(e) {
            e.stopPropagation();
            var text;
            try { text = getText(); }
            catch (err) { text = ''; }
            if (typeof text !== 'string'
                || text.length === 0) return;
            var ta;
            try { ta = getTextarea(); }
            catch (err) { ta = null; }
            if (!ta) return;
            insertSuggestion(ta, text);
        });
        btn.addEventListener('dblclick', function(e) {
            e.stopPropagation();
        });
    }

    window.GalaxySuggestion = {
        SUGGEST_ICON_SVG: SUGGEST_ICON_SVG,
        buildSuggestion: buildSuggestion,
        insertSuggestion: insertSuggestion,
        buttonHTML: buttonHTML,
        bindSuggestionButton: bindSuggestionButton
    };
})();
"""

// MARK: - Shared JS-side add-note affordance
//
// Defines `window.GalaxyAddNote`, the button that promotes a
// selection toolbar into the note form. Companion to
// `GalaxyClipboard` and `GalaxySuggestion`, and deliberately
// thinner than either: promoting is surface-specific, so only the
// icon and the markup are shared here and each manager wires its
// own click handler.
//
// The icon is an outlined comment bubble, distinct from the
// suggestion affordance's filled plus so the two never read as the
// same action — they occupy the same slot in the same row, one
// state apart. Stroked rather than filled, which makes it lighter
// than the filled copy icon beside it; raise `stroke-width` if it
// reads too quiet.
//
// Idempotent — calls through `if (window.GalaxyAddNote) return;`
// so a second injection is a no-op.

// js-validate
public let addNoteButtonJS: String = """
(function() {
    if (window.GalaxyAddNote) return;

    var ADDNOTE_ICON_SVG =
        '<svg class="addnote-icon" width="14"'
        + ' height="14" viewBox="0 0 16 16"'
        + ' fill="none" stroke="currentColor"'
        + ' stroke-width="1.5" stroke-linejoin="round"'
        + ' aria-hidden="true">'
        + '<path d="M3.6 3h8.8a1.4 1.4 0 0 1 1.4 1.4v4.9'
        + 'a1.4 1.4 0 0 1-1.4 1.4H7.6L4.7 13.2V10.7H3.6'
        + 'a1.4 1.4 0 0 1-1.4-1.4V4.4A1.4 1.4 0 0 1 3.6 3Z"/>'
        + '</svg>';

    function buttonHTML(className, defaultTitle) {
        return '<button type="button"'
            + ' class="addnote-button '
            + className + '" title="' + defaultTitle
            + '" aria-label="' + defaultTitle + '">'
            + ADDNOTE_ICON_SVG + '</button>';
    }

    // `onActivate` promotes the toolbar to the note form on
    // whichever manager owns this surface. dblclick is swallowed
    // so a fast double-click on the button doesn't also reach the
    // row beneath and re-open a selection.
    function bindAddNoteButton(btn, onActivate) {
        btn.addEventListener('click', function(e) {
            e.stopPropagation();
            try { onActivate(); } catch (err) {}
        });
        btn.addEventListener('dblclick', function(e) {
            e.stopPropagation();
        });
    }

    window.GalaxyAddNote = {
        ADDNOTE_ICON_SVG: ADDNOTE_ICON_SVG,
        buttonHTML: buttonHTML,
        bindAddNoteButton: bindAddNoteButton
    };
})();
"""
