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
// A host may also ask for an overall comment, which opens on the first
// press and sends on the second. That text does arrive on `invoke`, and it
// is not an exception to the paragraph above: what the surface holds is
// still the surface's, and what the person pressing the bar said about it
// is part of the press.
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

        // What `update` was last told.
        //
        // Held here so one place can refuse a send with nothing to send. The
        // scrollback tested its note count at its own keydown and the reader
        // branch tested nothing at all, which is how the chord came to fire
        // into a reader with no pending annotations — closing it, and then
        // being refused by the CLI with the reader already gone.
        count: 0,

        // Whether this host wants an overall comment ahead of the send. Off
        // unless asked for, so a host that has not opted in keeps sending on
        // the first press exactly as it did.
        commentEnabled: false,
        expanded: false,

        // A host supplies the noun it counts in and what to do when the
        // bar is pressed. Nothing about the surface's payload arrives here —
        // what does now arrive, on `invoke`, is the presser's own words.
        configure: function(config) {
            if (!config) return;
            if (config.noun) this.noun = config.noun;
            if (config.invoke) this.invoke = config.invoke;
            if (config.comment) this.commentEnabled = true;

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

        // First press opens the overall comment, second one sends. A host
        // that never asked for the comment sends on the first, which is the
        // whole of what this used to do.
        fire: function() {
            if (!this.invoke) return;
            if (this.count <= 0) return;
            if (!this.commentEnabled) {
                this.invoke('');
                return;
            }
            if (!this.expanded) {
                this.expand();
                return;
            }
            this.submit();
        },

        submit: function() {
            // Deliberately not cleared. A host may bounce the send through a
            // confirmation sheet and re-enter afterwards, and it has to still
            // find what was typed.
            this.invoke(this.commentText());
        },

        commentText: function() {
            var ta = document.getElementById('send-bar-comment-input');
            return ta ? ta.value.trim() : '';
        },

        // Emptied by the host, once the review has actually gone.
        //
        // `submit` cannot do it, for the reason stated there: a host may bounce
        // the send through a confirmation sheet and re-enter, and has to still
        // find what was typed. So clearing belongs to whoever knows the send
        // succeeded.
        //
        // A host that rebuilds this page on the way back got it for free and
        // never had to call this, which is why nothing missed it until one
        // arrived whose panes stay mounted behind an opacity switch. There, the
        // sent comment stayed in the field and led the *next* review — a
        // summary of work already sent, sitting above unrelated notes.
        clearComment: function() {
            var ta = document.getElementById('send-bar-comment-input');
            if (ta) {
                ta.value = '';
                this.fitComment();
            }
            this.collapse();
        },

        expand: function() {
            var box = document.getElementById('send-bar-comment');
            if (!box) return;
            var ta = this.buildComment(box);
            if (!ta) return;
            box.style.display = '';
            this.expanded = true;
            // Fitted here rather than wherever the text arrived from. A
            // hidden element has a scrollHeight of zero, so anything that
            // fills this field while the box is closed — a rescue from a
            // page being rebuilt — cannot measure it and must not try.
            // This is the first moment it has a height at all.
            this.fitComment();
            ta.focus();
        },

        // Grow the field to its content, and pay the gutter what that costs.
        fitComment: function() {
            var ta = document.getElementById('send-bar-comment-input');
            if (!ta) return;
            ta.style.height = 'auto';
            ta.style.height = ta.scrollHeight + 'px';
            this.syncGutter();
        },

        // Keeps the text.
        //
        // Escape here means "not yet", and of the two failures available —
        // holding text nobody asked to keep, or making someone retype an
        // overall review because a key went astray — the second is worse.
        collapse: function() {
            var box = document.getElementById('send-bar-comment');
            if (!box) return;
            box.style.display = 'none';
            this.expanded = false;
            this.syncGutter();
        },

        // The bar declares the body gutter that keeps it off the last line,
        // so a bar that changed height owes the body a new one.
        syncGutter: function() {
            var bar = document.getElementById('send-bar');
            if (!bar) return;
            if (bar.style.display === 'none') {
                // Back to the stylesheet's value: a hidden bar covers nothing,
                // and its offsetHeight would read zero anyway.
                document.body.style.paddingBottom = '';
                return;
            }
            document.body.style.paddingBottom
                = (bar.offsetHeight + 8) + 'px';
        },

        // Built on first expand rather than shipped in the markup, so the
        // attributes every composer switches off are declared once, next to
        // the four other composers that switch them off.
        buildComment: function(box) {
            var existing
                = document.getElementById('send-bar-comment-input');
            if (existing) return existing;
            if (!window.GalaxyCardText) return null;

            var self = this;
            var ta = window.GalaxyCardText.createComposerTextarea(
                'send-bar-comment-input', '', 1);
            ta.id = 'send-bar-comment-input';
            ta.placeholder = 'Overall comment'
                + (window.GalaxyTextEntry
                    ? window.GalaxyTextEntry.placeholderHint('send')
                    : '');
            box.appendChild(ta);

            // Growing the box moves the bar's top edge, which is the gutter's
            // problem and nothing else's — the cards on either surface are
            // laid out against the document, not against this.
            window.GalaxyCardText.installAutosize(ta, function() {
                self.syncGutter();
            });

            window.GalaxyCardText.bindCardComposer(ta, {
                guard: function(e) {
                    if (!self.matchesChord(e)) return false;
                    e.preventDefault();
                    self.submit();
                    return true;
                },
                onSubmit: function() { self.submit(); },
                onEscape: function() { self.collapse(); }
            });
            return ta;
        },

        update: function(count) {
            this.count = count;
            var bar = document.getElementById('send-bar');
            var label = document.getElementById('send-bar-count');
            if (!bar || !label) return;
            if (count > 0) {
                bar.style.display = 'flex';
                label.textContent = count + ' ' + this.noun
                    + (count === 1 ? '' : 's');
            } else {
                bar.style.display = 'none';
                // Nothing left for a comment to lead. Hidden rather than
                // discarded, for the reason `collapse` keeps it.
                var box = document.getElementById('send-bar-comment');
                if (box) box.style.display = 'none';
                this.expanded = false;
            }
            this.syncGutter();
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
