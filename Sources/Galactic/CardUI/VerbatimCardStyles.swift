import Foundation

/// Shared presentation tokens for note and annotation UI.
///
/// `textSize` is the single value both the edit textarea and the
/// saved card body resolve to, so composing and reading a note never
/// differ in size. Artifact readers pass a fixed `13px`. The
/// scrollback passes `var(--font-size)` so notes track the terminal
/// font they sit among — a note renders inline between terminal rows,
/// so matching the text it annotates is what reads as correct there.
/// Chrome (headers, hints) stays fixed on both surfaces: meta chrome
/// is UI, note text is content.
///
/// `--note-one-line` is the height of exactly one line of note text
/// including the text box's own padding and border. The collapsed
/// card and the empty textarea both use it, so a one-line note
/// occupies the same height whether it is being typed or read. `1em`
/// resolves against the element using the token, not `:root` —
/// custom property values substitute as tokens and resolve at the use
/// site — so it tracks whatever `--note-text-size` resolved to.
public func noteUXTokens(textSize: String) -> String {
    """
    :root {
        --note-text-size: \(textSize);
        --note-text-line-height: 1.5;
        --note-text-font: var(--font-family-mono,
            "SF Mono", "Menlo", "Monaco",
            "Courier New", monospace);
        --note-chrome-size: 13px;
        --note-chrome-font: -apple-system, sans-serif;
        --note-meta-size: 11px;
        --note-box-pad-y: 6px;
        --note-box-pad-x: 10px;
        --note-text-pad-y: 6px;
        --note-text-pad-x: 8px;
        --note-header-gap: 4px;
        --note-spacer-gap: 6px;
        --note-one-line: calc(
            1em * var(--note-text-line-height)
            + var(--note-text-pad-y) * 2 + 2px);
    }
    """
}

/// Shared treatment for every icon button in a note or annotation
/// header: copy, add-a-suggestion, and add-a-note.
///
/// These were three near-identical rule sets per surface, six in
/// all, and they had already drifted — the suggestion button sat at
/// a different rest opacity than the copy button beside it, and the
/// add-note button, declaring no colour at all, fell through to the
/// user agent's `buttontext` and rendered near-black instead of
/// muted. A button does not inherit `color` from its container, so
/// leaving it out is not a way of accepting the surrounding value.
///
/// One block now describes all three. Only `display` differs
/// between them, and only because copy is always meaningful while
/// the other two belong to states — so those two default to hidden
/// here and the state rules that reveal them live with the state.
///
/// Colours are parameterized rather than shared: the artifact
/// readers resolve theirs from CSS variables, the scrollback from
/// its terminal theme.
public func iconButtonCSS(
    prefix: String,
    restColor: String,
    hoverColor: String
) -> String {
    """
    .copy-button.\(prefix)-copy-lines,
    .copy-button.\(prefix)-copy-ref,
    .suggest-button.\(prefix)-suggest,
    .addnote-button.\(prefix)-addnote {
        background: transparent;
        border: 0;
        padding: 0 4px;
        margin: 0;
        cursor: pointer;
        color: \(restColor);
        line-height: 1;
        opacity: 0.6;
        transition: opacity 120ms ease,
            color 120ms ease;
        align-items: center;
    }
    .copy-button.\(prefix)-copy-lines:hover,
    .copy-button.\(prefix)-copy-ref:hover,
    .suggest-button.\(prefix)-suggest:hover,
    .addnote-button.\(prefix)-addnote:hover {
        opacity: 1;
        color: \(hoverColor);
    }
    .copy-button.\(prefix)-copy-lines .copy-icon,
    .copy-button.\(prefix)-copy-ref .copy-icon,
    .suggest-button.\(prefix)-suggest .suggest-icon,
    .addnote-button.\(prefix)-addnote .addnote-icon {
        display: block;
    }
    .copy-button.\(prefix)-copy-lines,
    .copy-button.\(prefix)-copy-ref {
        display: inline-flex;
    }
    /* Confirmation after a successful copy. Both copy
       actions flash it — the reference button was added
       to a rule that named only its sibling, so its
       checkmark arrived in the resting colour. */
    .copy-button.\(prefix)-copy-lines.copied,
    .copy-button.\(prefix)-copy-ref.copied {
        color: #2ea043;
        opacity: 1;
    }
    .suggest-button.\(prefix)-suggest,
    .addnote-button.\(prefix)-addnote {
        display: none;
    }
    """
}

/// Rules for the form's selection-only state — the toolbar shown
/// while a range is selected but no note is being written yet.
///
/// The textarea and the suggestion affordance are hidden, and the
/// add-note affordance is revealed. Nothing in this state is
/// focused, which is the point: the browser's own selection has to
/// survive so a plain Cmd+C copies what the user highlighted.
///
/// The add-note button defaults to hidden and is revealed only by
/// the state selector, matching how the suggestion button already
/// works — a button that exists in the DOM but is wrong for the
/// current state is never visible.
///
/// Parameterized by class prefix because the two surfaces name
/// their elements differently — `annotation-` in the artifact and
/// snapshot readers, `note-` in the scrollback — while the rules
/// themselves are identical.
public func selectionToolbarCSS(prefix: String) -> String {
    """
    .\(prefix)-form.selection-only
        .\(prefix)-textarea {
        display: none;
    }
    .\(prefix)-form.selection-only
        .suggest-button.\(prefix)-suggest {
        display: none;
    }
    .\(prefix)-form.selection-only
        .addnote-button.\(prefix)-addnote {
        display: inline-flex;
    }
    """
}

/// CSS for verbatim text rendering inside annotation/note card
/// bodies. Targets `.verbatim-card-content`, the marker class
/// applied to every card-style container that displays user-typed
/// note/annotation text.
///
/// Notes and annotations render exactly as typed — no markdown,
/// no auto-linking. The container element is `<pre>` so the
/// browser's user-agent styling (monospace + whitespace
/// preservation) gives a correct rendering even if our CSS
/// variables fail to load. `white-space: pre-wrap` then upgrades
/// `<pre>`'s default `pre` to wrap inside the card width.
/// `overflow-wrap: anywhere` keeps long unbreakable strings
/// (URLs, paths, hashes) from blowing past the card. The mono
/// font matches the textarea the user typed into and makes
/// pasted indented/tabular content align.
///
/// We also reset `<pre>`'s user-agent margin so switching from a
/// `<div>` host to a `<pre>` doesn't shift the card's vertical
/// rhythm.
///
/// Both this rule and `.annotation-card-content` /
/// `.note-card-content` declare `font-size`, and
/// `pre.verbatim-card-content` outranks them (one class each, but
/// this one also names an element). Rather than pick a winner, both
/// sides point at `--note-text-size`, so the outcome is the same
/// whichever wins and a future third class on the card body cannot
/// reintroduce a size mismatch. This previously read `inherit`,
/// which won the tie and then resolved against the *container* —
/// 13px in artifacts, the terminal font size in the scrollback —
/// while the textarea stayed at 12px.
///
/// The card body carries the textarea's padding plus a transparent
/// border so the text-bearing box has identical content width in
/// both states: text cannot re-wrap on save. The visible border and
/// background tint on the textarea remain the edit-mode affordance.
/// `box-sizing` is explicit because two readers lack the `*` reset
/// that supplies it elsewhere.
///
/// Single source of truth: scrollback notes and artifact +
/// snapshot annotations apply identical rules so the card display
/// matches the edit textarea byte-for-byte.
public let verbatimCardCSS: String = """
    pre.verbatim-card-content {
        margin: 0;
        font-size: var(--note-text-size, 13px);
    }
    .verbatim-card-content {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        font-family: var(--note-text-font,
            "SF Mono", "Menlo", "Monaco",
            "Courier New", monospace);
        padding: var(--note-text-pad-y, 6px)
            var(--note-text-pad-x, 8px);
        border: 1px solid transparent;
        box-sizing: border-box;
    }
"""

/// Neutralise host document rules that match injected card UI by element name.
///
/// Card UI is injected into a document whose own stylesheet knows nothing about
/// it. A bare `pre`, `td`, or `button` rule in that stylesheet is specificity
/// (0,0,1); these selectors are (0,1,0) and outrank it. They tie with the card
/// rules that follow and lose to them on source order — **so this block must be
/// emitted first**.
///
/// Not a defence against host `!important` or ID selectors. The only surface
/// where that is a live concern is the HTML reader's full-document path, where
/// the host CSS is authored by the artifact rather than by the app.
public func hostResetCSS(prefix: String) -> String {
    """
    .\(prefix)-card, .\(prefix)-card *,
    .\(prefix)-form, .\(prefix)-form * {
        background: none;
        border: 0;
        border-radius: 0;
        padding: 0;
        margin: 0;
        overflow: visible;
        box-shadow: none;
        max-width: none;
        min-width: 0;
        float: none;
        text-align: left;
        text-indent: 0;
        text-transform: none;
        letter-spacing: normal;
        font-weight: normal;
        font-style: normal;
        list-style: none;
    }
    """
}

/// The armed state of a delete button, and the timer that disarms it.
///
/// Deleting a card takes two clicks: the first turns the button into a red
/// "Are you sure?" and starts a five-second drain, the second commits. The
/// drain is a CSS animation rather than a rendered countdown, so the visual
/// duration is declared here while the timer that actually disarms lives in the
/// card manager — **the two durations must agree**, and they are written in two
/// languages in two files.
///
/// `!important` throughout because the resting button treatment these override
/// is itself specific, and the armed state has to win from a single class.
public func deleteConfirmCSS(prefix: String) -> String {
    """
    .\(prefix)-btn-delete.confirming {
        background: rgba(220, 40, 30, 0.75) !important;
        color: #fff !important;
        font-size: 12px;
        font-weight: 600;
        font-family: -apple-system, sans-serif;
        padding: 4px 12px !important;
        position: relative;
        overflow: hidden;
    }
    .\(prefix)-btn-delete.confirming:hover {
        background: rgba(220, 40, 30, 0.85) !important;
        color: #fff !important;
    }
    .\(prefix)-btn-delete.confirming::after {
        content: '';
        position: absolute;
        bottom: 0;
        left: 0;
        height: 1.5px;
        background: rgba(255, 255, 255, 0.8);
        animation: confirmDrain 5s linear forwards;
    }
    @keyframes confirmDrain {
        from { width: 100%; }
        to { width: 0%; }
    }
    """
}

/// The emoji autocomplete popup.
///
/// Unprefixed: both surfaces build the same `.emoji-popup` DOM, because the
/// popup is produced by one shared autocomplete script rather than by either
/// card manager. That shared script is exactly why this needed unifying — the
/// two copies of the *styling* had drifted while the behaviour driving them
/// stayed identical, so one script was rendering into two different popups.
///
/// Geometry and row rules are shared. Colours are parameters, following
/// `iconButtonCSS`: the readers resolve theirs from CSS variables and the
/// scrollback from its terminal theme, and a popup floating over a dark
/// terminal legitimately wants a heavier shadow than one over a document.
public func emojiPopupCSS(
    background: String,
    border: String,
    shadow: String
) -> String {
    """
    .emoji-popup {
        position: absolute;
        z-index: 100;
        min-width: 200px;
        max-width: 300px;
        max-height: 280px;
        overflow-y: auto;
        background: \(background);
        border: 1px solid \(border);
        border-radius: 6px;
        box-shadow: 0 4px 12px \(shadow);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        padding: 4px 0;
        display: none;
    }
    .emoji-popup-row {
        display: flex;
        align-items: center;
        padding: 4px 10px;
        cursor: pointer;
        gap: 8px;
    }
    .emoji-popup-row.selected,
    .emoji-popup-row.selected:hover {
        background: rgba(88, 166, 255, 0.2);
    }
    .emoji-popup-row:hover {
        background: rgba(88, 166, 255, 0.12);
    }
    .emoji-popup-emoji {
        font-size: 18px;
        width: 24px;
        text-align: center;
        flex-shrink: 0;
    }
    .emoji-popup-name {
        color: var(--fg);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    .emoji-popup-name .emoji-match {
        font-weight: 600;
    }
    """
}
