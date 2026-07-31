import Foundation

// MARK: - Annotation CSS

/// CSS for annotation highlights, form, cards, spacers,
/// and emoji popup. Requires CSS variables: --bg, --fg,
/// --code-bg, --code-border, --blockquote-fg,
/// --table-header-bg, --delete-color,
/// --card-active-bg, --card-active-border,
/// --annotation-active-block-bg,
/// --annotation-active-block-border.
public let annotationCSS: String = """
    \(noteUXTokens(textSize: "13px"))
    \(hostResetCSS(prefix: "annotation"))
    .annotation-highlight {
        background-color: rgba(88, 166, 255, 0.12);
        border-left: 3px solid rgba(88, 166, 255, 0.6);
        padding-left: 8px;
        margin-left: -11px;
        transition: background-color 0.15s ease;
    }
    .annotation-form {
        position: absolute;
        left: 24px;
        right: 24px;
        z-index: 10;
        padding: var(--note-box-pad-y) var(--note-box-pad-x);
        border: 1px solid rgba(88, 166, 255, 0.4);
        border-radius: 6px;
        background: var(--code-bg);
        font-family: var(--note-chrome-font);
        font-size: var(--note-chrome-size);
        box-sizing: border-box;
    }
    .annotation-form-header {
        font-size: var(--note-meta-size);
        color: var(--blockquote-fg);
        margin-bottom: var(--note-header-gap);
        font-family: var(--note-text-font);
    }
    .annotation-textarea {
        width: 100%;
        min-height: var(--note-one-line);
        padding: var(--note-text-pad-y) var(--note-text-pad-x);
        border: 1px solid var(--code-border);
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
    .annotation-textarea:focus {
        outline: none;
        border-color: rgba(88, 166, 255, 0.6);
    }
    body.file-drop-active .annotation-textarea,
    body.file-drop-active .annotation-edit-textarea {
        border-color: rgba(88, 166, 255, 0.8);
        box-shadow: 0 0 0 1px rgba(88, 166, 255, 0.3);
    }
    .annotation-textarea::placeholder {
        color: var(--blockquote-fg);
        opacity: 0.6;
    }
    .annotation-card {
        position: absolute;
        left: 24px;
        right: 24px;
        z-index: 10;
        padding: var(--note-box-pad-y) var(--note-box-pad-x);
        border: 1px solid var(--code-border);
        border-radius: 6px;
        background: var(--code-bg);
        font-family: var(--note-chrome-font);
        font-size: var(--note-chrome-size);
        box-sizing: border-box;
    }
    .annotation-card-header {
        display: flex;
        align-items: center;
        gap: 6px;
        font-size: var(--note-meta-size);
        color: var(--blockquote-fg);
        margin-bottom: var(--note-header-gap);
        font-family: var(--note-text-font);
    }
    .annotation-card-meta {
        opacity: 0.5;
    }
    .annotation-card-actions {
        margin-left: auto;
        display: flex;
        gap: 6px;
        opacity: 0;
        transition: opacity 0.15s;
    }
    .annotation-card:hover .annotation-card-actions {
        opacity: 1;
    }
    .annotation-card-actions button {
        background: none;
        border: none;
        color: var(--blockquote-fg);
        cursor: pointer;
        font-size: 15px;
        padding: 3px 6px;
        border-radius: 4px;
        line-height: 1;
    }
    .annotation-card-actions button:hover {
        background: var(--table-header-bg);
        color: var(--fg);
    }
    .annotation-card-actions .annotation-btn-delete {
        color: var(--delete-color);
    }
    .annotation-card-actions .annotation-btn-delete:hover {
        background: rgba(255, 59, 48, 0.1);
        color: var(--delete-color);
    }
    .annotation-card-actions:has(.confirming) {
        opacity: 1;
    }
    .annotation-card-actions:has(.confirming)
        .annotation-btn-edit {
        display: none;
    }
    /* Copy-lines affordance — sits inline next to the
       line-reference label in the form/card header. The
       host card-header is display:flex so the button
       slots in as a flex item. */
    \(iconButtonCSS(
        prefix: "annotation",
        restColor: "var(--blockquote-fg)",
        hoverColor: "var(--fg)"
    ))
    .annotation-form-header {
        display: flex;
        align-items: center;
        gap: 6px;
    }
    .annotation-form-header .annotation-form-ref {
        flex: 0 1 auto;
    }
    /* In edit mode the textarea hides the action row but
       keeps the header — the copy button lives in the
       header so it stays visible. */
    .annotation-card:has(.annotation-edit-textarea)
        .copy-button.annotation-copy-lines {
        opacity: 1;
    }
    /* Add-a-suggestion affordance — only shown in
       new/edit states, never in show. Inserts the
       captured source text into the active textarea
       wrapped in a `suggestion` fenced block. */
    /* Visible whenever the form is up — the form is
       only shown for new/edit. */
    .annotation-form-header
        .suggest-button.annotation-suggest {
        display: inline-flex;
    }
    /* Visible on a card only while an edit textarea
       is active. Show state hides it. */
    .annotation-card:has(.annotation-edit-textarea)
        .suggest-button.annotation-suggest {
        display: inline-flex;
        opacity: 1;
    }
    /* Hidden rather than removed: the action buttons are the
       tallest thing in the header, so dropping them from layout
       shortened the header and pulled the note text up as soon as
       editing began. Reserving the box keeps the chrome still. */
    .annotation-card:has(.annotation-edit-textarea)
        .annotation-card-actions {
        visibility: hidden;
    }
    \(deleteConfirmCSS(prefix: "annotation"))
    .annotation-card-content {
        line-height: var(--note-text-line-height);
        color: var(--fg);
        font-size: var(--note-text-size);
    }
    .annotation-card-content.collapsed {
        max-height: var(--note-one-line);
        overflow: hidden;
    }
    \(verbatimCardCSS)
    \(selectionToolbarCSS(prefix: "annotation"))
    .annotation-edit-textarea {
        width: 100%;
        min-height: var(--note-one-line);
        padding: var(--note-text-pad-y) var(--note-text-pad-x);
        border: 1px solid rgba(88, 166, 255, 0.4);
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
    .annotation-card.expanded {
        border-color: var(--card-active-border);
        background: var(--card-active-bg);
    }
    .annotation-expanded-highlight {
        background-color:
            var(--annotation-active-block-bg);
        border-left: 3px solid
            var(--annotation-active-block-border);
        padding-left: 8px;
        margin-left: -11px;
        transition: background-color 0.15s ease;
    }
    /* Sits in the header row at the end of the label group,
       rather than below the card body where appearing and
       disappearing changed the card's height — a one-line note
       would shrink as it expanded and grow back as it collapsed,
       nudging every card below it. Nothing follows it in that
       group and the action buttons are pinned right by their own
       auto margin, so it can leave the flow without moving
       anything, in either direction. */
    /* Font, size and colour are left to the header so the hint
       reads as the same kind of label as the line reference
       beside it, and follows it if that treatment changes. */
    .annotation-expand-hint {
        cursor: pointer;
        white-space: nowrap;
    }
    .annotation-card.expanded .annotation-expand-hint,
    .annotation-card:has(.annotation-edit-textarea)
        .annotation-expand-hint {
        display: none;
    }
    .annotation-spacer {
        pointer-events: none;
        line-height: 0;
        font-size: 0;
    }
    .annotation-spacer.form-spacer {
        margin: var(--note-spacer-gap) 0;
    }
    .annotation-spacer.card-spacer {
        margin: var(--note-spacer-gap) 0;
    }
    .annotation-spacer-row td {
        padding: 0;
        border: none;
        background: transparent;
        line-height: 0;
    }
    \(emojiPopupCSS(
        background: "var(--code-bg)",
        border: "var(--code-border)",
        shadow: "rgba(0, 0, 0, 0.15)"
    ))
"""

// MARK: - CSS Variables

/// CSS variable definitions for annotation theming.
public func annotationCSSVars(isDark: Bool) -> String {
    let monoFontStack = "\"SF Mono\", \"Menlo\", "
        + "\"Monaco\", \"Courier New\", monospace"
    if isDark {
        return """
            --bg: #0d1117;
            --fg: #e6edf3;
            --code-bg: #161b22;
            --code-border: #30363d;
            --blockquote-fg: #8b949e;
            --table-header-bg: #21262d;
            --card-active-bg: \
        rgba(255, 255, 120, 0.12);
            --card-active-border: \
        rgba(255, 220, 50, 0.5);
            --annotation-active-block-bg: \
        rgba(255, 255, 120, 0.08);
            --annotation-active-block-border: \
        rgba(255, 220, 50, 0.35);
            --delete-color: #ff5252;
            --font-family-mono: \(monoFontStack);
        """
    } else {
        return """
            --bg: #ffffff;
            --fg: #1f2328;
            --code-bg: #f6f8fa;
            --code-border: #d0d7de;
            --blockquote-fg: #656d76;
            --table-header-bg: #f0f0f0;
            --card-active-bg: \
        rgba(255, 248, 220, 0.8);
            --card-active-border: #d4a017;
            --annotation-active-block-bg: \
        rgba(255, 248, 220, 0.5);
            --annotation-active-block-border: \
        rgba(212, 160, 23, 0.6);
            --delete-color: #ff3b30;
            --font-family-mono: \(monoFontStack);
        """
    }
}
