import Foundation

// MARK: - Shared JS-side text-entry matcher
//
// Defines `window.GalaxyTextEntry`, the WebView twin of the Swift
// `TextEntryBindings` resolver. Any WKWebView module with a composer
// textarea — scrollback notes, annotation forms — asks it whether a
// keydown commits, inserts a newline, or is none of its business.
//
// Two things keep it honest against the Swift side:
//
//   1. The modifier bitmask is shared verbatim. The bit positions
//      below are the same ones `Keystroke.Modifiers` uses.
//   2. Bindings arrive keyed by DOM `code` strings, because a WebView
//      never sees a macOS virtual key code. Swift translates through
//      `Keystroke.domCode` when it injects the configuration, so no
//      key table lives on this side.
//
// `fixtures/text-entry-cases.json` pins both, and
// `scripts/verify-text-entry.mjs` runs this literal against it. A
// disagreement between the two matchers fails the build rather than
// surfacing months later as a key that quietly stopped working.
//
// Inject before any module that calls into `GalaxyTextEntry`.
// Idempotent — a second injection is a no-op.

// js-validate
public let textEntryJS: String = """
(function() {
    if (window.GalaxyTextEntry) return;

    // Must match Keystroke.Modifiers on the Swift side.
    var MOD_COMMAND = 1;
    var MOD_OPTION = 2;
    var MOD_CONTROL = 4;
    var MOD_SHIFT = 8;

    // Mirrors TextEntryBindings.default on the Swift side. A document that
    // never calls configure still behaves exactly as every composer did
    // before this module existed.
    //
    // Failing safe matters more than failing loudly here. An unconfigured
    // composer that silently stopped submitting is easy to ship and hard to
    // notice, whereas one that keeps working is at worst out of date.
    var DEFAULT_BINDINGS = {
        submit: [{ code: 'Enter', modifiers: 0 }],
        newline: [
            { code: 'Enter', modifiers: MOD_OPTION },
            { code: 'KeyJ', modifiers: MOD_CONTROL }
        ]
    };

    var bindings = DEFAULT_BINDINGS;

    // Caps-lock, fn, and the numeric-pad flag are deliberately not read,
    // which is how this stays in step with the normalisation
    // Modifiers.init(deviceFlags:) performs on the Swift side. Incidental
    // modifier state must never decide whether a binding matches.
    function modifiersOf(e) {
        var m = 0;
        if (e.metaKey) m |= MOD_COMMAND;
        if (e.altKey) m |= MOD_OPTION;
        if (e.ctrlKey) m |= MOD_CONTROL;
        if (e.shiftKey) m |= MOD_SHIFT;
        return m;
    }

    function matches(list, code, mods) {
        if (!list) return false;
        for (var i = 0; i < list.length; i++) {
            if (list[i].code === code && list[i].modifiers === mods) {
                return true;
            }
        }
        return false;
    }

    // Render a binding as a key label.
    //
    // Swift sends the label alongside the binding, because the key table it
    // comes from is large and lives there. Recomputing it here would mean two
    // copies of that table, and the placeholder would eventually disagree with
    // the settings card about the same keystroke.
    //
    // The fallback only runs for a payload that predates the label field, and
    // spells the modifiers in Apple's canonical order: control, option, shift,
    // command.
    function describeBinding(binding) {
        if (binding.label) return binding.label;
        var m = binding.modifiers || 0;
        var out = '';
        if (m & MOD_CONTROL) out += '\\u2303';
        if (m & MOD_OPTION) out += '\\u2325';
        if (m & MOD_SHIFT) out += '\\u21e7';
        if (m & MOD_COMMAND) out += '\\u2318';
        if (binding.code === 'Enter' || binding.code === 'NumpadEnter') {
            return out + 'Enter';
        }
        return out + binding.code;
    }

    // Insert text at the caret, preferring execCommand so the undo stack
    // and input events behave as if the user typed it. The manual fallback
    // has to dispatch 'input' itself, or the auto-grow listeners installed
    // on these textareas never fire and the box stops growing.
    function insertText(textarea, text) {
        if (typeof document !== 'undefined'
            && document.execCommand
            && document.execCommand('insertText', false, text)) {
            return;
        }
        var start = textarea.selectionStart;
        var end = textarea.selectionEnd;
        var value = textarea.value;
        textarea.value = value.slice(0, start) + text + value.slice(end);
        textarea.selectionStart = start + text.length;
        textarea.selectionEnd = textarea.selectionStart;
        if (typeof Event !== 'undefined') {
            textarea.dispatchEvent(
                new Event('input', { bubbles: true }));
        }
    }

    window.GalaxyTextEntry = {
        // cfg: { submit: [{code, modifiers}], newline: [{code, modifiers}] }
        //
        // A missing list falls back to its default rather than to nothing, so
        // a malformed payload cannot leave a composer unable to submit. An
        // explicitly empty list is honoured — that is a user unbinding an
        // action, which is different from a payload that forgot to mention it.
        configure: function (cfg) {
            bindings = {
                submit: (cfg && cfg.submit) || DEFAULT_BINDINGS.submit,
                newline: (cfg && cfg.newline) || DEFAULT_BINDINGS.newline
            };
        },

        // Returns 'submit' | 'newline' | null.
        //
        // Null means "not ours" and the caller MUST let the event through
        // untouched. Swallowing it would break every key the app does not
        // own, which is most of them.
        //
        // Submit is tested first, so a keystroke present in both lists
        // commits — the same tie-break the Swift resolver makes.
        actionFor: function (e) {
            var mods = modifiersOf(e);
            if (matches(bindings.submit, e.code, mods)) return 'submit';
            if (matches(bindings.newline, e.code, mods)) return 'newline';
            return null;
        },

        // A short glyph label for the first keystroke bound to submit, or ''
        // when submit is unbound.
        submitHint: function () {
            var list = bindings.submit;
            if (!list || !list.length) return '';
            return describeBinding(list[0]);
        },

        // The parenthesised placeholder hint the composers share, derived from
        // the live binding so the copy cannot drift from the behaviour.
        //
        // When submit is unbound the submit half is dropped rather than
        // rendered empty — advertising a keystroke that does nothing is worse
        // than not mentioning one.
        placeholderHint: function (verb) {
            var key = this.submitHint();
            if (!key) return ' (Esc to dismiss)';
            return ' (' + key + ' to ' + verb
                + ' \\u00b7 Esc to dismiss)';
        },

        // Perform the 'newline' action, returning true if it was handled
        // here and false if the caller should let the browser's own default
        // do it.
        //
        // A bare or shifted Return already inserts a newline in a textarea.
        // Standing aside for those keeps the undo stack, IME composition, and
        // input events byte-for-byte what they were before this matcher
        // existed — which is what makes the default configuration a genuine
        // no-op rather than a re-implementation that merely looks the same.
        // Any other chord the user binds to newline gets inserted manually,
        // because the browser would do nothing at all for it.
        handleNewline: function (textarea, e) {
            if (e.key === 'Enter'
                && !e.metaKey && !e.ctrlKey && !e.altKey) {
                return false;
            }
            e.preventDefault();
            insertText(textarea, '\\n');
            return true;
        },

        // handlers: { submit: fn, guard: fn, newline: fn, escape: fn }
        //
        // `guard` runs before the matcher and bails out entirely when it
        // returns true — that is how an autocomplete popup keeps first claim
        // on a keystroke. Newline is handled by handleNewline unless the
        // caller supplies its own.
        //
        // `escape` is optional and deliberately last, because the surfaces
        // that use this disagree about Escape: some answer it on the textarea,
        // others report their state to a host and let it decide. Supplying a
        // handler claims the key — the default and the propagation are both
        // stopped before it runs. Omitting it leaves Escape untouched, which is
        // what a surface answering it elsewhere needs.
        bind: function (textarea, handlers) {
            var opts = handlers || {};
            textarea.addEventListener('keydown', function (e) {
                if (opts.guard && opts.guard(e)) return;
                var action = window.GalaxyTextEntry.actionFor(e);
                if (action === 'submit') {
                    if (!opts.submit) return;
                    e.preventDefault();
                    opts.submit(e);
                    return;
                }
                if (action === 'newline') {
                    if (opts.newline) {
                        e.preventDefault();
                        opts.newline(e);
                        return;
                    }
                    window.GalaxyTextEntry.handleNewline(textarea, e);
                    return;
                }
                if (e.key === 'Escape' && opts.escape) {
                    e.preventDefault();
                    e.stopPropagation();
                    opts.escape(e);
                }
            });
        }
    };
})();
"""
