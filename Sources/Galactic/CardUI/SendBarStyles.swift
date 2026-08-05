import Foundation

// MARK: - Send Bar

/// The bar that offers to send a surface's collected notes or annotations
/// into a Claude session.
///
/// Markup, colours, and rules for the strip pinned to the bottom of a
/// note-bearing document. The scrollback carried all three inline for as long
/// as it was the only surface that had one; the artifact and snapshot readers
/// now show the same bar, and a second copy of a hard-coded green is exactly
/// the kind of drift the rest of this directory exists to prevent.
///
/// The bar knows a count, a noun, and that someone pressed it. It does not
/// know what gets sent — each surface composes its own payload, because a
/// scrollback note and a persisted annotation have nothing in common past the
/// gesture.
///
/// ### No class prefix
///
/// The prefixed helpers next door — `hostResetCSS(prefix:)`,
/// `selectionToolbarCSS(prefix:)` — are parameterized because both surfaces
/// already had differently-named elements for the same component, `note-` in
/// the scrollback and `annotation-` in the readers, and the prefix was how a
/// retrofit avoided renaming either. Nothing here was retrofitted, so one
/// class name serves both. The two documents are separate web views; there is
/// nothing for it to collide with.
/// The container for the overall comment is empty on purpose: the textarea
/// inside it is built by `GalaxyCardText.createComposerTextarea` on first
/// expand, so the attributes every composer switches off — spellcheck,
/// autocorrect, autocapitalize, autocomplete — stay declared in exactly one
/// place rather than being restated here in markup.
public let sendBarHTML: String = """
    <div class="send-bar" id="send-bar" style="display:none;">
        <div class="send-bar-comment" id="send-bar-comment" style="display:none;"></div>
        <div class="send-bar-row">
            <span class="send-bar-count" id="send-bar-count"></span>
            <button class="send-bar-button" id="send-bar-button">Send to Claude ⌘⇧↩</button>
        </div>
    </div>
    """

/// The four colours the bar resolves, as custom properties.
///
/// Split from `sendBarCSS` for the reason `noteUXTokens` is split from the
/// rules that use it: the two hosts arrive at light-versus-dark differently —
/// the scrollback from its terminal theme's background luminance, a reader
/// from `ReaderTheme.isDark` — and only the answer needs to be shared, not the
/// derivation.
public func sendBarTokens(isLight: Bool) -> String {
    """
    :root {
        --send-bar-bg: \(isLight
            ? "rgba(34, 139, 34, 0.92)"
            : "rgba(40, 170, 80, 0.95)");
        --send-bar-border-top: \(isLight
            ? "rgba(0, 0, 0, 0.1)"
            : "rgba(255, 255, 255, 0.15)");
        --send-bar-btn-bg: \(isLight
            ? "rgba(255, 255, 255, 0.25)"
            : "rgba(255, 255, 255, 0.2)");
        --send-bar-btn-border: \(isLight
            ? "rgba(255, 255, 255, 0.35)"
            : "rgba(255, 255, 255, 0.3)");
    }
    """
}

/// Rules for the bar, its button, and the gutter it needs.
///
/// Requires the custom properties `sendBarTokens(isLight:)` declares.
///
/// The bar is `position: fixed`, so it would otherwise cover the last line of
/// whatever it sits over. The gutter that prevents this is declared here rather
/// than left to each host, because it is the bar's own height that decides it —
/// the scrollback previously carried the value in its own `body` rule, where
/// nothing connected it to the 40px it was compensating for.
public let sendBarCSS: String = """
    body {
        padding-bottom: 48px;
    }
    .send-bar {
        position: fixed;
        bottom: 0;
        left: 0;
        right: 0;
        background: var(--send-bar-bg);
        backdrop-filter: blur(8px);
        /* A column rather than the 40px row this used to be, so the overall
           comment can open above the count and the button. The bar is
           anchored to the bottom, so growing upward leaves the button
           exactly where the pointer left it. Collapsed, the row's own
           min-height makes this the same 40px strip it always was. */
        display: flex;
        flex-direction: column;
        align-items: stretch;
        min-height: 40px;
        padding: 0 16px;
        color: white;
        font-family: -apple-system, system-ui, sans-serif;
        font-size: 13px;
        font-weight: 500;
        z-index: 1000;
        border-top: 1px solid var(--send-bar-border-top);
    }
    .send-bar-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        min-height: 40px;
    }
    .send-bar-comment {
        padding: 8px 0 2px;
    }
    .send-bar-comment-input {
        width: 100%;
        box-sizing: border-box;
        padding: 5px 8px;
        border-radius: 4px;
        /* Themed exactly as `.note-textarea` and `.annotation-textarea` are,
           off the same two properties, because this is one more composer and
           a reader typing prose into it should not be able to tell which one
           they are in. Both hosts declare these in the stylesheet this is
           emitted into — the readers in `annotationCSSVars`, the scrollback
           from its terminal theme — so following the theme costs nothing here.

           The border stays the bar's, not the page's: it is what separates a
           dark field from dark green, and it is the one part of the field that
           belongs to the bar rather than to the document. */
        border: 1px solid var(--send-bar-btn-border);
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, system-ui, sans-serif;
        font-size: 13px;
        font-weight: 400;
        line-height: 1.4;
        /* The height is the autosize's to set, and only its. */
        resize: none;
        overflow: hidden;
    }
    .send-bar-comment-input:focus {
        outline: none;
        border-color: rgba(255, 255, 255, 0.7);
    }
    .send-bar-comment-input::placeholder {
        /* Follows the field it sits in, for the same reason the field
           follows the page. A fixed dark placeholder was readable only
           while the field was light. */
        color: var(--fg);
        opacity: 0.45;
    }
    .send-bar-button {
        background: var(--send-bar-btn-bg);
        border: 1px solid var(--send-bar-btn-border);
        color: white;
        padding: 4px 12px;
        border-radius: 4px;
        cursor: pointer;
        /* The scrollback's body sets `-webkit-user-select: text` +
           `cursor: text`, which inherit here. WebKit then renders the
           text I-beam on hover and lets it win over `cursor: pointer`
           whenever the button's text is selectable — the pointer only
           shows mid mouse-press. Opting the button out of selection
           keeps the pointer consistent, drag or no drag. */
        user-select: none;
        -webkit-user-select: none;
        font-weight: 600;
        font-size: 13px;
        position: relative; /* anchor for tooltip ::after */
    }
    .send-bar-button:not(:disabled):hover {
        background: rgba(255, 255, 255, 0.35);
    }
    /* Disabled look WITHOUT `opacity` — opacity would cascade to the
       ::after tooltip, washing out its pill background and text. Dim
       via color/border changes instead so the tooltip renders at full
       opacity. */
    .send-bar-button:disabled {
        cursor: not-allowed;
        color: rgba(255, 255, 255, 0.45);
        border-color: rgba(255, 255, 255, 0.2);
    }
    /* Instant CSS tooltip for the disabled state — the native `title`
       attribute has a multi-second OS delay before showing, which feels
       broken for a user actively trying to figure out why the button is
       disabled. The data-attribute is set by GalaxySendBar.setState. */
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
    """
