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
// What is deliberately NOT here: the create/edit/delete lifecycle. The two
// managers orchestrate different things and are structured differently, and
// merging them is a separate job. This is the substrate they both stand on.

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
        ta.selectionStart = newPos;
        ta.selectionEnd = newPos;

        // Drives the autosize listener above, so the box grows to fit what was
        // just dropped into it.
        ta.dispatchEvent(new Event('input'));
        ta.focus();
    }

    window.GalaxyCardText = {
        EDIT_ICON_SVG: EDIT_ICON_SVG,
        DELETE_ICON_SVG: DELETE_ICON_SVG,
        DELETE_ARM_REJECT_MS: DELETE_ARM_REJECT_MS,
        DELETE_REVERT_MS: DELETE_REVERT_MS,
        armDeleteButton: armDeleteButton,
        disarmDeleteButton: disarmDeleteButton,
        installAutosize: installAutosize,
        insertPaths: insertPaths
    };
})();
"""
