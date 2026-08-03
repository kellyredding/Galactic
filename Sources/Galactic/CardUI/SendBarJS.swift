import Foundation

// MARK: - Shared JS-side send bar
//
// Defines `window.GalaxySendBar`, the behaviour behind the bar
// `sendBarHTML` draws: show or hide it against a count, label it, and
// report that someone pressed it.
//
// It reports the gesture and nothing else. Each surface composes its own
// message — the scrollback inlines its notes as numbered fenced blocks,
// the readers hand off to a CLI review workflow — and neither shape
// belongs to a bar. A host wires `invoke` to whatever sending means
// there.
//
// Inject before any module that calls into `GalaxySendBar` (the
// scrollback note manager, the annotation manager). Idempotent — calls
// through `if (window.GalaxySendBar) return;` so a second injection is a
// no-op.

// js-validate
public let sendBarJS: String = """
(function() {
    if (window.GalaxySendBar) return;

    window.GalaxySendBar = {
        // Both halves of the chord in one place. The glyphs used to be
        // typed into the button's label and the modifiers into a keydown
        // branch a thousand lines away, with nothing deriving one from
        // the other.
        CHORD_GLYPHS: '\\u2318\\u21e7\\u21a9',

        noun: 'note',
        invoke: null,

        // A host supplies the noun it counts in and what to do when the
        // bar is pressed. Nothing about the payload arrives here.
        configure: function(config) {
            if (!config) return;
            if (config.noun) this.noun = config.noun;
            if (config.invoke) this.invoke = config.invoke;

            var btn = document.getElementById('send-bar-button');
            // Re-configuring is normal — a reader re-runs its init
            // script after a theme reload — and must not stack a second
            // click listener on the same element.
            if (btn && !btn.dataset.wired) {
                btn.dataset.wired = '1';
                var self = this;
                btn.addEventListener('click', function() {
                    self.fire();
                });
            }
        },

        // The chord, as a predicate. Each host calls this from its own
        // keydown handler rather than the bar installing a listener,
        // because the guards differ: the scrollback suppresses keys
        // while its find bar owns them, a reader only has to stay out of
        // textareas. Sharing the predicate keeps the two in step without
        // the bar having to model either guard.
        matchesChord: function(e) {
            return e.key === 'Enter' && e.metaKey && e.shiftKey;
        },

        fire: function() {
            if (this.invoke) this.invoke();
        },

        update: function(count) {
            var bar = document.getElementById('send-bar');
            var label = document.getElementById('send-bar-count');
            if (!bar || !label) return;
            if (count > 0) {
                bar.style.display = 'flex';
                label.textContent = count + ' ' + this.noun
                    + (count === 1 ? '' : 's');
            } else {
                bar.style.display = 'none';
            }
        },

        // Uses a data attribute rather than the native `title` so the
        // CSS tooltip shows on hover with no OS delay — a multi-second
        // wait reads as broken to someone trying to work out why the
        // button is dead. Only the scrollback sets this; the readers
        // resume a stopped session rather than refusing the send.
        setState: function(enabled, tooltip) {
            var btn = document.getElementById('send-bar-button');
            if (!btn) return;
            btn.disabled = !enabled;
            if (tooltip) {
                btn.setAttribute('data-disabled-reason', tooltip);
            } else {
                btn.removeAttribute('data-disabled-reason');
            }
        }
    };
})();
"""
