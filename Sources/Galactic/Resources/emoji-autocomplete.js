// emoji-autocomplete.js — Slack-style :shortcode: emoji autocomplete
// Attach to any textarea: EmojiAutocomplete.attach(textareaElement)

const EmojiAutocomplete = {
    // --- Configuration ---
    maxResults: 8,
    minQueryLength: 1,
    triggerChar: ':',

    // --- State (per-textarea instance tracking) ---
    instances: new WeakMap(),

    // --- Public API ---

    attach: function(textarea) {
        if (this.instances.has(textarea)) return;

        var self = this;
        var instance = {
            popup: null,
            selectedIndex: 0,
            results: [],
            triggerStartIndex: null,
            suppressNextInput: false,
            inputHandler: null,
            blurHandler: null
        };

        instance.inputHandler = function() { self.onInput(textarea); };
        instance.blurHandler = function() { self.hidePopup(textarea); };

        textarea.addEventListener('input', instance.inputHandler);
        textarea.addEventListener('blur', instance.blurHandler);

        this.instances.set(textarea, instance);
    },

    detach: function(textarea) {
        var instance = this.instances.get(textarea);
        if (!instance) return;

        textarea.removeEventListener('input', instance.inputHandler);
        textarea.removeEventListener('blur', instance.blurHandler);

        if (instance.popup && instance.popup.parentNode) {
            instance.popup.parentNode.removeChild(instance.popup);
        }

        this.instances.delete(textarea);
    },

    // --- Query: Is Popup Visible? ---

    isActive: function(textarea) {
        var instance = this.instances.get(textarea);
        return instance && instance.popup &&
               instance.popup.style.display !== 'none';
    },

    dismiss: function(textarea) {
        this.hidePopup(textarea);
    },

    // --- Trigger Detection ---

    detectTrigger: function(textarea) {
        var text = textarea.value;
        var cursor = textarea.selectionEnd;

        var i = cursor - 1;
        while (i >= 0) {
            var ch = text[i];
            if (ch === this.triggerChar) {
                if (i === 0 || /[\s]/.test(text[i - 1])) {
                    var query = text.substring(i + 1, cursor);
                    if (query.length >= this.minQueryLength && !/\s/.test(query)) {
                        return { query: query.toLowerCase(), startIndex: i };
                    }
                }
                return null;
            }
            if (/\s/.test(ch)) return null;
            i--;
        }
        return null;
    },

    // --- Input Handler ---

    onInput: function(textarea) {
        var instance = this.instances.get(textarea);
        if (!instance) return;

        if (instance.suppressNextInput) {
            instance.suppressNextInput = false;
            return;
        }

        var trigger = this.detectTrigger(textarea);
        if (!trigger) {
            this.hidePopup(textarea);
            return;
        }

        var results = this.search(trigger.query);
        if (results.length === 0) {
            this.hidePopup(textarea);
            return;
        }

        instance.results = results;
        instance.selectedIndex = 0;
        instance.triggerStartIndex = trigger.startIndex;
        var coords = this.getCaretCoordinates(textarea, trigger.startIndex);
        this.showPopup(textarea, results, coords);
    },

    // --- Search ---

    search: function(query) {
        var prefixMatches = [];
        var containsMatches = [];
        var tagMatches = [];

        for (var name in EMOJI_DATA.map) {
            if (name.startsWith(query)) {
                prefixMatches.push({ shortcode: name, emoji: EMOJI_DATA.map[name] });
            } else if (name.includes(query)) {
                containsMatches.push({ shortcode: name, emoji: EMOJI_DATA.map[name] });
            }
        }

        if (EMOJI_DATA.tags) {
            for (var name in EMOJI_DATA.tags) {
                var tags = EMOJI_DATA.tags[name];
                for (var t = 0; t < tags.length; t++) {
                    if (tags[t].startsWith(query)) {
                        if (!prefixMatches.some(function(m) { return m.shortcode === name; }) &&
                            !containsMatches.some(function(m) { return m.shortcode === name; })) {
                            tagMatches.push({ shortcode: name, emoji: EMOJI_DATA.map[name] });
                        }
                        break;
                    }
                }
            }
        }

        var byName = function(a, b) { return a.shortcode.localeCompare(b.shortcode); };
        prefixMatches.sort(byName);
        containsMatches.sort(byName);
        tagMatches.sort(byName);

        return prefixMatches
            .concat(containsMatches)
            .concat(tagMatches)
            .slice(0, this.maxResults);
    },

    // --- Caret Coordinate Calculation ---

    getCaretCoordinates: function(textarea, position) {
        var properties = [
            'direction', 'boxSizing', 'width', 'overflowX',
            'fontFamily', 'fontSize', 'fontWeight', 'fontStyle',
            'letterSpacing', 'textTransform', 'wordSpacing',
            'textIndent', 'paddingTop', 'paddingRight',
            'paddingBottom', 'paddingLeft', 'borderTopWidth',
            'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
            'lineHeight', 'whiteSpace', 'wordWrap'
        ];

        var div = document.createElement('div');
        div.id = 'emoji-caret-mirror';
        div.style.position = 'absolute';
        div.style.visibility = 'hidden';
        div.style.top = '0';
        div.style.left = '0';

        var style = window.getComputedStyle(textarea);
        for (var i = 0; i < properties.length; i++) {
            div.style[properties[i]] = style[properties[i]];
        }

        div.textContent = textarea.value.substring(0, position);

        var marker = document.createElement('span');
        marker.textContent = '|';
        div.appendChild(marker);

        document.body.appendChild(div);
        var coords = {
            top: marker.offsetTop,
            left: marker.offsetLeft,
            height: parseInt(style.lineHeight) || parseInt(style.fontSize) * 1.2
        };
        document.body.removeChild(div);

        return coords;
    },

    // --- Popup Rendering ---

    showPopup: function(textarea, results, caretCoords) {
        var instance = this.instances.get(textarea);
        if (!instance) return;

        var self = this;

        // Create popup on first use
        if (!instance.popup) {
            instance.popup = document.createElement('div');
            instance.popup.className = 'emoji-popup';
            instance.popup.addEventListener('mousedown', function(e) {
                e.preventDefault();
            });
            document.body.appendChild(instance.popup);
        }

        var popup = instance.popup;

        // Made visible and placed horizontally before the rows go in, because a
        // display:none element measures as a zero rect and the vertical
        // placement below depends on a real height.
        var rect = textarea.getBoundingClientRect();
        popup.style.left =
            (rect.left + window.scrollX + caretCoords.left) + 'px';
        popup.style.display = 'block';

        // Render rows
        var query = textarea.value.substring(
            instance.triggerStartIndex + 1,
            textarea.selectionEnd
        ).toLowerCase();

        var html = '';
        for (var i = 0; i < results.length; i++) {
            var r = results[i];
            var selectedClass = i === instance.selectedIndex ? ' selected' : '';

            // Bold the matched portion of the shortcode
            var nameHTML;
            var matchIdx = r.shortcode.indexOf(query);
            if (matchIdx >= 0) {
                nameHTML = r.shortcode.substring(0, matchIdx) +
                    '<span class="emoji-match">' +
                    r.shortcode.substring(matchIdx, matchIdx + query.length) +
                    '</span>' +
                    r.shortcode.substring(matchIdx + query.length);
            } else {
                nameHTML = r.shortcode;
            }

            html += '<div class="emoji-popup-row' + selectedClass +
                    '" data-index="' + i + '">' +
                    '<span class="emoji-popup-emoji">' +
                    self.emojiPresentation(r.emoji) + '</span>' +
                    '<span class="emoji-popup-name">:' + nameHTML + ':</span>' +
                    '</div>';
        }
        popup.innerHTML = html;

        // Wire row events (re-wired on each render since innerHTML replaces rows)
        var rows = popup.querySelectorAll('.emoji-popup-row');
        for (var j = 0; j < rows.length; j++) {
            (function(row, idx) {
                row.addEventListener('mouseenter', function() {
                    instance.selectedIndex = idx;
                    self.updateSelection(textarea);
                });
                row.addEventListener('click', function() {
                    var selected = instance.results[idx];
                    if (selected) {
                        self.insertEmoji(textarea, selected.emoji,
                            instance.triggerStartIndex);
                    }
                });
            })(rows[j], parseInt(rows[j].getAttribute('data-index')));
        }

        // Vertical placement happens last, against the height the popup
        // actually has now.
        //
        // Measuring before the rows were written meant measuring the previous
        // query's popup: narrowing ':za' to ':zap' dropped eight rows to one,
        // but the flip-above placement had already subtracted the eight-row
        // height, leaving the popup stranded far above the caret with the gap
        // where the old rows used to be.
        var caretTop = rect.top + window.scrollY + caretCoords.top;
        popup.style.top = (caretTop + caretCoords.height) + 'px';

        var popupRect = popup.getBoundingClientRect();
        if (popupRect.bottom > window.innerHeight) {
            var aboveTop = caretTop - popupRect.height;
            if (aboveTop > 0) {
                popup.style.top = aboveTop + 'px';
            }
        }
    },

    hidePopup: function(textarea) {
        var instance = this.instances.get(textarea);
        if (!instance || !instance.popup) return;
        instance.popup.style.display = 'none';
        instance.selectedIndex = 0;
    },

    updateSelection: function(textarea) {
        var instance = this.instances.get(textarea);
        if (!instance || !instance.popup) return;

        var rows = instance.popup.querySelectorAll('.emoji-popup-row');
        for (var i = 0; i < rows.length; i++) {
            if (i === instance.selectedIndex) {
                rows[i].classList.add('selected');
                rows[i].scrollIntoView({ block: 'nearest' });
            } else {
                rows[i].classList.remove('selected');
            }
        }
    },

    // --- Keyboard Navigation (Semi-Modal) ---

    handleKeyDown: function(textarea, event) {
        if (!this.isActive(textarea)) return false;

        // Swallow all modifier combos FIRST (⌘Enter, ⌘A, Ctrl-anything)
        if (event.metaKey || event.ctrlKey) {
            event.preventDefault();
            return true;
        }

        var instance = this.instances.get(textarea);
        if (!instance) return false;

        switch (event.key) {
            case 'ArrowUp':
                event.preventDefault();
                instance.selectedIndex =
                    (instance.selectedIndex - 1 + instance.results.length)
                    % instance.results.length;
                this.updateSelection(textarea);
                return true;
            case 'ArrowDown':
                event.preventDefault();
                instance.selectedIndex =
                    (instance.selectedIndex + 1) % instance.results.length;
                this.updateSelection(textarea);
                return true;
            case 'ArrowLeft':
            case 'ArrowRight':
            case 'Home':
            case 'End':
            case 'PageUp':
            case 'PageDown':
                event.preventDefault();
                return true;
            case 'Enter':
            case 'Tab':
                event.preventDefault();
                var selected = instance.results[instance.selectedIndex];
                if (selected) {
                    this.insertEmoji(textarea, selected.emoji,
                        instance.triggerStartIndex);
                }
                return true;
            case 'Escape':
                event.preventDefault();
                this.hidePopup(textarea);
                return true;
            default:
                return false;
        }
    },

    // --- Text Insertion ---

    // Force colour-emoji presentation on the characters that would otherwise
    // lose it to the surrounding font.
    //
    // A composer renders in a monospace stack, and several of these emoji are
    // old enough to predate emoji — U+26A1 ⚡, U+2B50 ⭐, U+2705 ✅, the zodiac,
    // 64 in all. Menlo and its relatives carry monochrome text glyphs for
    // them, and a font earlier in the stack wins per glyph regardless of what
    // Unicode says the default presentation should be. So ⚡ arrived as a thin
    // grey bolt at text size while 💯 beside it rendered full colour: 💯 lives
    // outside the BMP, no text font has it, and it fell through to the emoji
    // font. Nothing was wrong with the sizing — the two characters were being
    // drawn from different fonts.
    //
    // U+FE0F makes the text font's glyph ineligible. Applied only to a lone
    // BMP character: the dataset already carries the selector where it is
    // required, and appending one to a flag, a skin-tone modifier, or a ZWJ
    // sequence would corrupt it.
    emojiPresentation: function(emoji) {
        if (!emoji) return emoji;
        var chars = Array.from(emoji);
        if (chars.length === 1 && emoji.codePointAt(0) <= 0xFFFF) {
            return emoji + '\uFE0F';
        }
        return emoji;
    },

    insertEmoji: function(textarea, emoji, triggerStartIndex) {
        var instance = this.instances.get(textarea);
        if (instance) instance.suppressNextInput = true;

        emoji = this.emojiPresentation(emoji);

        var before = textarea.value.substring(0, triggerStartIndex);
        var after = textarea.value.substring(textarea.selectionEnd);
        textarea.value = before + emoji + after;

        var newPos = triggerStartIndex + emoji.length;
        textarea.setSelectionRange(newPos, newPos);

        textarea.dispatchEvent(new Event('input', { bubbles: true }));
        textarea.focus();

        this.hidePopup(textarea);
    }
};
