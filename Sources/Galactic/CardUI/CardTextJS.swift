import Foundation

// MARK: - Shared JS-side card text helpers
//
// Defines `window.GalaxyCardText`, used by any card manager that edits note or
// annotation text: the two surfaces implement the same card UX under different
// names, and these are the pieces that were the same code written twice.
//
// Inject ahead of any module that calls into it. Idempotent — a second
// injection returns immediately.
//
// The delete lifecycle IS here, as a state machine the surfaces drive — it was
// the one lifecycle whose rules were identical in intent, and consolidating it
// resolved a difference between the two copies rather than papering over one.
//
// What is deliberately NOT here: creating and editing. Those two managers
// orchestrate genuinely different things — one anchors cards to source ranges
// and repositions them, the other lets them sit in the document flow — and
// merging them would mean restructuring one side for no shared behavior.

// js-validate
public let cardTextJS: String = """
(function() {
    if (window.GalaxyCardText) return;

    // Pencil and trash, sized in `em` so they track the card chrome they sit
    // in rather than a fixed pixel size.
    var EDIT_ICON_SVG =
        '<svg width="1em" height="1em" viewBox="0 0 24 24"'
        + ' fill="none" stroke="currentColor" stroke-width="2.5"'
        + ' stroke-linecap="round" stroke-linejoin="round">'
        + '<path d="M17 3a2.828 2.828 0 114 4L7.5 20.5 2 22l1.5-5.5L17 3z"/>'
        + '</svg>';

    var DELETE_ICON_SVG =
        '<svg width="1em" height="1em" viewBox="0 0 24 24"'
        + ' fill="none" stroke="currentColor" stroke-width="2.5"'
        + ' stroke-linecap="round" stroke-linejoin="round">'
        + '<path d="M3 6h18"/><path d="M8 6V4h8v2"/>'
        + '<path d="M5 6v14a1 1 0 001 1h12a1 1 0 001-1V6"/>'
        + '<path d="M10 11v6"/><path d="M14 11v6"/>'
        + '</svg>';

    // Clicks landing sooner than this after arming are ignored. Catches the
    // second click of a double-click, which would otherwise arm and confirm a
    // delete in one gesture — and does so whether or not disabling the button
    // took effect in time.
    var DELETE_ARM_REJECT_MS = 500;

    // How long an armed delete stays armed.
    //
    // Must equal the duration of the `confirmDrain` animation in the shared
    // card stylesheet: the drain IS the countdown as far as the user can see,
    // and a bar that empties before or after the button disarms reads as the
    // button being broken. Two languages, one number — keep them together.
    var DELETE_REVERT_MS = 5000;

    function armDeleteButton(btn) {
        if (!btn) return;
        btn.classList.add('confirming');
        btn.textContent = 'Are you sure?';
    }

    function disarmDeleteButton(btn) {
        if (!btn) return;
        btn.classList.remove('confirming');
        btn.innerHTML = DELETE_ICON_SVG;
    }

    // The two-click delete, as a state machine both card surfaces drive.
    //
    // Click once to arm, again to confirm. What the surfaces used to share was
    // only the timings and the button styling; the machine around them was
    // written twice, once inlined into a single method and once spread across
    // four, and the two had drifted into different behavior.
    //
    // Arming a card disarms whichever card was armed before it, so at most one
    // is ever armed. Without that rule the revert timers overlap: the first
    // card's timer fires while the second is armed and clears the shared
    // state, leaving the second button reading "Are you sure?" while a click
    // on it re-arms instead of confirming. One surface had the rule and one
    // did not.
    //
    // `findButton(id)` locates the delete button for an id — each surface
    // names its cards differently, and that is the only part of this that ever
    // legitimately differed. `onConfirmed(id)` is the surface's own way of
    // telling its host to go through with it.
    //
    // The button is resolved before any state is written, so a card that has
    // gone from the DOM leaves the machine idle rather than armed against
    // something that cannot be clicked.
    function createDeleteConfirmation(opts) {
        var findButton = opts.findButton;
        var onConfirmed = opts.onConfirmed;

        var confirmingId = null;
        var armedAt = null;
        var timer = null;
        var deleting = false;

        function clear() {
            if (timer !== null) {
                clearTimeout(timer);
                timer = null;
            }
            armedAt = null;
            var id = confirmingId;
            if (id === null) return;
            confirmingId = null;
            disarmDeleteButton(findButton(id));
        }

        function handleClick(id) {
            // A delete already in flight ignores further clicks: the card is
            // about to leave, and the host has not said so yet.
            if (deleting) return;

            if (confirmingId === id) {
                if (Date.now() - armedAt < DELETE_ARM_REJECT_MS) return;
                deleting = true;
                clear();
                onConfirmed(id);
                return;
            }

            clear();
            var btn = findButton(id);
            if (!btn) return;
            confirmingId = id;
            armedAt = Date.now();
            armDeleteButton(btn);
            timer = setTimeout(clear, DELETE_REVERT_MS);
        }

        // Called once the host has confirmed the card is gone, which is what
        // releases the machine to accept clicks again.
        function finish() {
            deleting = false;
        }

        return {
            handleClick: handleClick,
            clear: clear,
            finish: finish
        };
    }

    // What every card composer's textarea switches off.
    //
    // Five composers each listed these for themselves — three as markup, two as
    // DOM nodes. The list is not the interesting part of any of them, and a
    // composer that quietly lost one would gain macOS text substitution in the
    // middle of a sentence: the kind of thing nobody notices until it has
    // rewritten a path somebody pasted.
    var COMPOSER_TEXTAREA_ATTRS = {
        spellcheck: 'false',
        autocorrect: 'off',
        autocapitalize: 'off',
        autocomplete: 'off'
    };

    // Markup for a composer textarea, for the forms that build as HTML.
    //
    // `hint` names the action whose configured keystroke is appended to the
    // placeholder, so the prompt tells the user which key commits rather than
    // asserting one the settings may have changed.
    function composerTextareaHTML(className, opts) {
        var o = opts || {};
        var attrs = '';
        for (var name in COMPOSER_TEXTAREA_ATTRS) {
            attrs += ' ' + name + '="'
                + COMPOSER_TEXTAREA_ATTRS[name] + '"';
        }
        var placeholder = o.placeholder || '';
        if (o.hint) {
            placeholder += window.GalaxyTextEntry.placeholderHint(o.hint);
        }
        return '<textarea class="' + className + '"'
            + attrs
            + ' placeholder="' + placeholder + '"'
            + ' rows="' + (o.rows || 1) + '"></textarea>';
    }

    // The same textarea as a node, for the edit paths that swap a rendered
    // element in place rather than rebuilding a whole form.
    function createComposerTextarea(className, value, rows) {
        var ta = document.createElement('textarea');
        ta.className = className;
        for (var name in COMPOSER_TEXTAREA_ATTRS) {
            ta.setAttribute(name, COMPOSER_TEXTAREA_ATTRS[name]);
        }
        ta.value = value || '';
        if (rows) ta.rows = rows;
        return ta;
    }

    // Wire a card composer's keys.
    //
    // Every note and annotation composer — the create forms and the in-card
    // edit textareas alike — agreed on the same three rules and each spelled
    // them out again: let the emoji autocomplete claim a key first, then submit
    // on the user's configured submit keystroke, then insert a newline on the
    // configured newline keystroke. Five copies of the same listener, differing
    // only in which function submit called.
    //
    // The generic half of that already existed in the keystroke module and was
    // never wired to anything. This supplies the part that is specific to a
    // card — that an emoji popup is what gets first claim — and hands the rest
    // to it.
    //
    // `onEscape` is optional and passes straight through: a surface that
    // answers Escape on the textarea supplies it, and a surface that reports
    // its context to the host instead leaves it out so the key propagates.
    function bindCardComposer(ta, handlers) {
        var opts = handlers || {};
        window.GalaxyTextEntry.bind(ta, {
            guard: function(e) {
                if (typeof EmojiAutocomplete !== 'undefined'
                    && EmojiAutocomplete.handleKeyDown(ta, e)) {
                    return true;
                }
                // A composer with a key of its own gets it after the popup
                // and before the matcher. The send bar's comment is the one
                // that needs this: the document-level handler that answers
                // the send chord stands aside for textareas on purpose, so
                // the composer has to answer it or nothing will. Passing the
                // guard through rather than letting that caller call `bind`
                // directly is what keeps the popup's first claim stated once.
                return opts.guard ? opts.guard(e) : false;
            },
            submit: opts.onSubmit,
            escape: opts.onEscape
        });
    }

    // Grow a textarea to fit its content, debounced.
    //
    // Resizing on every keystroke is visibly jumpy while typing, but waiting
    // out a fixed delay makes a pasted block or a new line lag behind the
    // caret. So a change that alters the shape of the text — a newline added
    // or removed, or an edit that is not a single character — resizes at once,
    // and ordinary typing settles.
    //
    // WAIT is how long a quiet keystroke waits; MAX_WAIT caps how long a
    // sustained burst can defer the resize, so holding a key still grows the
    // box rather than deferring forever.
    //
    // `onGrow` runs after each resize, for a surface that has to reposition
    // anything anchored to the box.
    function installAutosize(ta, onGrow) {
        var WAIT = 250;
        var MAX_WAIT = 500;
        var lastNewlineCount = (ta.value.match(/\\n/g) || []).length;
        var lastLength = ta.value.length;
        var timer = null;
        var pendingFrame = null;
        var burstStart = 0;

        function fire() {
            timer = null;
            if (pendingFrame !== null) return;
            pendingFrame = requestAnimationFrame(function() {
                pendingFrame = null;
                ta.style.height = 'auto';
                ta.style.height = ta.scrollHeight + 'px';
                if (typeof onGrow === 'function') onGrow(ta);
            });
        }

        ta.addEventListener('input', function() {
            var newlineCount = (ta.value.match(/\\n/g) || []).length;
            var length = ta.value.length;
            var structural =
                newlineCount !== lastNewlineCount
                || Math.abs(length - lastLength) !== 1;
            lastNewlineCount = newlineCount;
            lastLength = length;

            if (structural) {
                if (timer !== null) clearTimeout(timer);
                fire();
                return;
            }

            var now = Date.now();
            if (timer === null) {
                burstStart = now;
            } else {
                clearTimeout(timer);
            }
            var delay = Math.min(
                WAIT, Math.max(0, MAX_WAIT - (now - burstStart))
            );
            timer = setTimeout(fire, delay);
        });
    }

    // Insert dropped file paths at the caret.
    //
    // Bracketed so a path with spaces stays one token to whoever reads the
    // text later, and placed on its own line — a path dropped mid-sentence is
    // almost always a reference rather than prose, and the newlines keep it
    // from running into what is already there. The leading newline is skipped
    // when the caret already sits at the start of a line.
    //
    // Finding the textarea is the caller's job: each surface knows its own
    // DOM, and that is the only part of this that ever differed between them.
    function insertPaths(ta, paths) {
        if (!ta || !paths || !paths.length) return;

        var text = paths.map(function(p) { return '[' + p + ']'; }).join(' ');

        var start = ta.selectionStart;
        var end = ta.selectionEnd;
        var before = ta.value.substring(0, start);
        var after = ta.value.substring(end);

        var prefix = '';
        if (before.length > 0 && before[before.length - 1] !== '\\n') {
            prefix = '\\n';
        }
        var suffix = '\\n';

        ta.value = before + prefix + text + suffix + after;

        var newPos = start + prefix.length + text.length + suffix.length;
        ta.setSelectionRange(newPos, newPos);

        // Order matters, and it is the reverse of what reads naturally.
        //
        // Focus is taken *before* the event is dispatched, because the input
        // listeners this wakes can reflow the surface — on a surface whose
        // cards are absolutely positioned, growing this box repositions
        // everything below it. Focusing after that reflow lands on an element
        // the layout has already moved out from under, and the caret is lost
        // even though the text arrived. Focusing first survives it.
        //
        // The event bubbles for the same reason the suggestion button's does:
        // a listener delegated to a container never sees an event that does
        // not travel, and the two insertion paths write into the same forms.
        ta.focus();
        ta.dispatchEvent(new Event('input', { bubbles: true }));
    }

    window.GalaxyCardText = {
        EDIT_ICON_SVG: EDIT_ICON_SVG,
        DELETE_ICON_SVG: DELETE_ICON_SVG,
        DELETE_ARM_REJECT_MS: DELETE_ARM_REJECT_MS,
        DELETE_REVERT_MS: DELETE_REVERT_MS,
        armDeleteButton: armDeleteButton,
        disarmDeleteButton: disarmDeleteButton,
        createDeleteConfirmation: createDeleteConfirmation,
        composerTextareaHTML: composerTextareaHTML,
        createComposerTextarea: createComposerTextarea,
        bindCardComposer: bindCardComposer,
        installAutosize: installAutosize,
        insertPaths: insertPaths
    };
})();
"""
