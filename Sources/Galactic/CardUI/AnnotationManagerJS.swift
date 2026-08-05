import Foundation

// MARK: - Generalized AnnotationManager JS

/// Returns the AnnotationManager JS module, generalized
/// for different block selectors and anchor types.
///
/// Config parameters (passed to initialize()):
///   - anchorType: 'line_range'|'row_range'|'block_range'
///   - blockSelector: CSS selector for selectable elements
///   - lineAttr: data attribute name for block index/line
///   - refPrefix: display prefix ('Line', 'Row', 'Block')
///   - itemLabel: header label ('Artifact #3', etc.)
///   - annotations: array of annotation objects
///   - htmlMap: map of number -> rendered HTML
// js-validate
public let annotationManagerJS: String = """
    function autoGrow(el) {
        el.style.height = 'auto';
        el.style.height = el.scrollHeight + 'px';
        syncPositionsAfterGrow();
    }

    // Cards are absolutely positioned relative to the blocks they annotate, so
    // a box that changed height moves everything below it.
    function syncPositionsAfterGrow() {
        if (typeof AnnotationManager !== 'undefined'
            && AnnotationManager.syncAllPositions) {
            AnnotationManager.syncAllPositions();
        }
    }

    // Why the shared autosize debounces at all is sharpest on this surface.
    //
    // Repositioning after a resize is a forced layout whose cost scales with
    // the size of the host artifact and the number of annotations on it, so
    // running it per keystroke lags typing on large items. The debounce is
    // what keeps that off the hot path: a structural change — a newline, or a
    // bulk insert from paste, dictation, or a file drop — resizes at once
    // because the user expects an instant jump, while ordinary typing settles
    // first and coalesces a burst into one layout.
    //
    // The scrollback passes no callback and pays none of this: its notes sit
    // in the document flow and nothing below them has to move.
    function installAutoGrow(ta) {
        window.GalaxyCardText.installAutosize(ta, syncPositionsAfterGrow);
    }

    const AnnotationManager = {
        blocks: [],
        currentBlockIndex: 0,
        highlightStart: 0,
        highlightEnd: 0,
        annotations: [],
        annotationHTMLMap: {},
        artifactContent: null,
        formElement: null,
        formSpacer: null,
        formSpacerRow: null,
        // True while the form is showing only its header row as a
        // toolbar over a live selection, with no textarea and
        // nothing focused.
        selectionOnly: false,
        cardSpacers: {},
        resizeObserver: null,
        editingNumber: null,
        expandedNumber: null,
        _deleteConfirmation: null,
        submitting: false,
        deleting: false,
        // Config
        anchorType: 'line_range',
        blockSelector: '.md-block',
        lineAttr: 'data-line-start',
        endLineAttr: null,
        refPrefix: 'Line',
        itemLabel: '',
        editIconSVG: window.GalaxyCardText.EDIT_ICON_SVG,
        deleteIconSVG: window.GalaxyCardText.DELETE_ICON_SVG,

        initialize(data) {
            this.anchorType = data.anchorType || \
'line_range';
            this.blockSelector = data.blockSelector || \
'.md-block';
            this.lineAttr = data.lineAttr || \
'data-line-start';
            this.endLineAttr = data.endLineAttr || null;
            this.refPrefix = data.refPrefix || 'Line';
            // Path of the file this artifact came from, when
            // there was one. Read only when building a
            // copy-able reference; nothing about anchoring or
            // persistence consults it.
            this.referencePath = data.referencePath || null;
            // Hand the composer keystroke bindings to the shared matcher.
            // Absent payload leaves it on its defaults, which are the
            // keystrokes these forms used before the setting existed.
            if (window.GalaxyTextEntry && data.textEntry) {
                window.GalaxyTextEntry.configure(\
data.textEntry);
            }
            this.itemLabel = data.itemLabel || '';
            this.annotations = data.annotations || [];
            this.annotationHTMLMap = data.htmlMap || {};
            this.artifactContent =
                typeof data.artifactContent === 'string'
                    ? data.artifactContent
                    : null;

            // Whole-type mode: no blocks, form/cards
            // appended to a container at the bottom
            if (this.anchorType === 'whole') {
                this.blocks = [];
                this.initWholeMode();
                return;
            }

            var allBlocks = document.querySelectorAll(
                this.blockSelector
            );
            // For md-block, filter to leaf blocks
            if (this.blockSelector === '.md-block') {
                this.blocks = Array.from(allBlocks)\
.filter(
                    function(el) {
                        return !el.querySelector(\
'.md-block');
                    }
                );
            } else {
                this.blocks = Array.from(allBlocks);
            }

            if (this.blocks.length === 0) return;

            this.currentBlockIndex = -1;
            this.highlightStart = -1;
            this.highlightEnd = -1;

            this.createForm();
            this.renderAllAnnotations();

            var self = this;
            document.addEventListener(\
'mouseup', function(e) {
                if (e.target.closest(\
'.annotation-form')) return;
                // Pressing the bar must not be read as a click
                // that dismisses the toolbar over the selection
                // it is about to send.
                if (e.target.closest('.send-bar')) return;
                // A click on an existing card expands it, so a
                // toolbar over some other range is no longer
                // about anything the user is looking at.
                if (e.target.closest(\
'.annotation-card')) {
                    if (self.selectionOnly)
                        self.dismissForm();
                    return;
                }

                var sel = window.getSelection();
                // A plain click collapses the selection. Nothing
                // needed to handle this before, because the
                // selection was destroyed the moment it was read.
                if (!sel || sel.isCollapsed) {
                    if (self.selectionOnly)
                        self.dismissForm();
                    return;
                }

                var range = sel.getRangeAt(0);
                var startBlock = self.findBlockElement(\
range.startContainer);
                var endBlock = self.findBlockElement(\
range.endContainer);

                // Landed somewhere with no row — a file header, a
                // gap marker. Don't leave a toolbar pointing at a
                // range the user has moved away from.
                if (!startBlock || !endBlock) {
                    if (self.selectionOnly)
                        self.dismissForm();
                    return;
                }

                var startIdx = self.blocks.indexOf(\
startBlock);
                var endIdx = self.blocks.indexOf(\
endBlock);
                if (startIdx < 0 || endIdx < 0) {
                    if (self.selectionOnly)
                        self.dismissForm();
                    return;
                }

                var lo = Math.min(startIdx, endIdx);
                var hi = Math.max(startIdx, endIdx);

                // Only a form being written into can lose work. A
                // toolbar holds nothing, so re-pointing it at a
                // new range needs no confirmation.
                if (self.isFormVisible()
                    && !self.selectionOnly) {
                    var ta = self.formElement
                        ? self.formElement.querySelector(\
'textarea')
                        : null;
                    if (ta && ta.value.trim()) {
                        window.webkit.messageHandlers\
.annotation
                            .postMessage({
                                action: \
'confirmDragReplace',
                                startIdx: lo,
                                endIdx: hi
                            });
                        sel.removeAllRanges();
                        return;
                    }
                }

                // The selection deliberately survives: it is what
                // a plain Cmd+C acts on, and what tells the user
                // that copying is available right now.
                self.showSelectionToolbar(lo, hi);
            });

            // Enter promotes a toolbar into the form, so drag
            // then Enter arrives where dragging alone used to.
            // Guarded on the focused element — while composing,
            // Enter belongs to the textarea.
            document.addEventListener(\
'keydown', function(e) {
                if (e.key !== 'Enter') return;
                var t = e.target;
                if (t && (t.tagName === 'TEXTAREA'
                    || t.tagName === 'INPUT')) return;
                // The send chord, matched against the shared
                // predicate so this and the glyphs on the bar's
                // button cannot drift apart. It has to be tested
                // before the modifier guard below, which is there
                // to stop a held chord promoting a toolbar and
                // would otherwise swallow this too. Composing is
                // still exempt: the textarea guard above returns
                // first, matching the scrollback, where Send is
                // unreachable while a note is being typed.
                if (window.GalaxySendBar
                    && window.GalaxySendBar.matchesChord(e)) {
                    e.preventDefault();
                    window.GalaxySendBar.fire();
                    return;
                }
                if (e.metaKey || e.ctrlKey || e.altKey) return;
                if (!self.selectionOnly
                    || !self.isFormVisible()) return;
                e.preventDefault();
                self.promoteToForm();
            });
        },

        // Report that the send bar was pressed, with whatever overall
        // comment was typed into it. The app holds the annotations
        // and composes its own message, so what crosses is the
        // gesture and the words that came with it — never the
        // annotations themselves.
        requestReview(comment) {
            window.webkit.messageHandlers.annotation.postMessage({
                action: 'reviewWithClaude',
                comment: comment || ''
            });
        },

        // --- Whole-type Mode ---

        initWholeMode() {
            // Create container at bottom of body
            var container = document.createElement('div');
            container.id = 'annotation-whole-container';
            container.style.cssText = 'padding: 0 24px '
                + '24px 24px;';
            document.body.appendChild(container);
            this.wholeContainer = container;

            this.renderWholeAnnotations();
            this.createWholeForm();

            // Double-click anywhere (except form/cards)
            // opens the annotation form
            var self = this;
            document.addEventListener(\
'dblclick', function(e) {
                if (e.target.closest(\
'.annotation-form') ||
                    e.target.closest(\
'.annotation-card')) return;
                if (!self.isFormVisible()) {
                    self.showWholeForm();
                }
            });
        },

        createWholeForm() {
            var form = document.createElement('div');
            form.className = 'annotation-form';
            form.style.cssText = 'position: relative; '
                + 'left: 0; right: 0; display: none; '
                + 'margin-bottom: 12px;';
            var label = this.itemLabel || '';
            form.innerHTML =
                '<div class="annotation-form-header">'
                + '<span class="annotation-form-ref">'
                + label + '</span></div>'
                + window.GalaxyCardText.composerTextareaHTML(
                    'annotation-textarea',
                    { placeholder: 'Add annotation\\u2026', hint: 'save' }
                );

            var ta = form.querySelector('textarea');
            installAutoGrow(ta);
            // Escape is deliberately not claimed here: this surface reports
            // its escape context to the host, which decides between closing a
            // popup, abandoning the form, and leaving the reader.
            window.GalaxyCardText.bindCardComposer(ta, {
                onSubmit: function() {
                    AnnotationManager.submitCreate();
                }
            });

            if (typeof EmojiAutocomplete \
!== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            this.formElement = form;
            this.wholeContainer.appendChild(form);
        },

        showWholeForm() {
            this.collapseExpanded();
            this.formElement.style.display = '';
            var ta = this.formElement.querySelector(\
'textarea');
            if (ta) { ta.value = ''; autoGrow(ta); }
            requestAnimationFrame(function() {
                if (ta) ta.focus();
            });
        },

        renderWholeAnnotations() {
            // Remove existing cards
            var existing = this.wholeContainer\
.querySelectorAll('.annotation-card');
            existing.forEach(function(c) { c.remove(); });

            for (var i = 0; i < this.annotations.length;\
 i++) {
                var ann = this.annotations[i];
                var html = this.annotationHTMLMap[\
ann.number] || '';
                this.insertWholeCard(ann, html);
            }
        },

        insertWholeCard(annotation, renderedHTML) {
            var isExpanded = this.expandedNumber \
=== annotation.number;
            var hasReview = !!annotation.review_number;

            var metaText = '#' + annotation.number;
            if (hasReview) {
                metaText += ' \\u00B7 Review #'
                    + annotation.review_number;
                if (annotation.review_reviewed_at) {
                    metaText += ' \\u00B7 '
                        + this.formatReviewDate(\
annotation.review_reviewed_at);
                }
            }

            var actionsHTML = hasReview ? '' :
                '<span class=\
"annotation-card-actions">' +
                    '<button class=\
"annotation-btn-edit" title="Edit">' +
                        this.editIconSVG + '</button>' +
                    '<button class=\
"annotation-btn-delete" title="Delete">' +
                        this.deleteIconSVG
                        + '</button>' +
                '</span>';

            var card = document.createElement('div');
            card.className = 'annotation-card'
                + (isExpanded ? ' expanded' : '');
            card.style.cssText = 'position: relative; '
                + 'left: 0; right: 0; '
                + 'margin-bottom: 8px;';
            card.setAttribute('data-number',
                annotation.number);
            card.innerHTML =
                '<div class=\
"annotation-card-header">' +
                    '<span class=\
"annotation-card-meta">'
                    + metaText + '</span>' +
                    '<span class=\
"annotation-expand-hint"'
                    + (isExpanded
                        ? ' style="display:none"'
                        : '')
                    + '>Click to expand</span>' +
                    actionsHTML +
                '</div>' +
                '<pre class=\
"annotation-card-content verbatim-card-content'
                + (isExpanded ? '' : ' collapsed') + '">'
                + renderedHTML + '</pre>';

            var self = this;
            card.addEventListener('click', function(e) {
                if (e.target.closest(\
'.annotation-btn-edit') ||
                    e.target.closest(\
'.annotation-btn-delete') ||
                    e.target.closest(\
'.annotation-edit-textarea'))
                    return;
                self.expandAnnotation(annotation.number);
            });

            var editBtn = card.querySelector(\
'.annotation-btn-edit');
            if (editBtn) {
                editBtn.addEventListener(\
'click', function(e) {
                    e.stopPropagation();
                    self.startEdit(annotation.number);
                });
            }
            var deleteBtn = card.querySelector(\
'.annotation-btn-delete');
            if (deleteBtn) {
                deleteBtn.addEventListener(\
'click', function(e) {
                    e.stopPropagation();
                    self.handleDeleteClick(\
annotation.number);
                });
            }

            // Suppress the 2nd click of a double-click so it
            // doesn't toggle expand. Capture phase +
            // stopImmediatePropagation ensures this runs before
            // the bubble-phase toggle handler and prevents it
            // from firing on the 2nd click.
            card.addEventListener('click', function(e) {
                if (e.detail >= 2) {
                    e.stopImmediatePropagation();
                }
            }, true);

            // Double-click anywhere on the card → enter edit,
            // same path as the pencil icon. Same exclusions as
            // the toggle handler. Gated on editBtn matching the
            // existing edit-button gate (review-locked
            // annotations have no editBtn and no edit path).
            if (editBtn) {
                card.addEventListener(\
'dblclick', function(e) {
                    if (e.target.closest(\
'.annotation-btn-edit') ||
                        e.target.closest(\
'.annotation-btn-delete') ||
                        e.target.closest(\
'.annotation-edit-textarea'))
                        return;
                    self.startEdit(annotation.number);
                });
            }

            if (this.formElement &&
                this.formElement.parentNode ===
                    this.wholeContainer) {
                this.wholeContainer.insertBefore(
                    card, this.formElement
                );
            } else {
                this.wholeContainer.appendChild(card);
            }
        },

        findBlockElement(node) {
            var el = node.nodeType === 3
                ? node.parentElement : node;
            var selector = this.blockSelector;
            while (el && !el.matches(selector)) {
                el = el.parentElement;
            }
            if (!el) return null;
            // For md-block, walk to leaf
            if (selector === '.md-block') {
                while (el.querySelector('.md-block')) {
                    el = el.querySelector('.md-block');
                }
            }
            return el;
        },

        // Every selection lands here, whatever was on screen
        // before: the toolbar is the only thing a range opens.
        // Reaching the form is a separate, deliberate step, so
        // nothing here focuses anything — focusing would collapse
        // the browser selection the user still needs for Cmd+C.
        showSelectionToolbar(startIdx, endIdx) {
            this.collapseExpanded();
            this.currentBlockIndex = endIdx;
            this.highlightStart = startIdx;
            this.highlightEnd = endIdx;
            this.selectionOnly = true;
            this.formElement.classList.add('selection-only');
            this.updateHighlights();
            this.positionForm();
            this.formElement.style.display = '';

            var ta = this.formElement.querySelector(\
'textarea');
            if (ta) { ta.value = ''; autoGrow(ta); }
            this.updateFormReference();
        },

        // Toolbar to form, from the add-note button or Enter.
        promoteToForm() {
            if (!this.selectionOnly) return;
            this.selectionOnly = false;
            this.formElement.classList.remove(
                'selection-only');
            this.syncAllPositions();
            var ta = this.formElement.querySelector(\
'textarea');
            if (ta) { autoGrow(ta); ta.focus(); }
        },

        restoreFormState(state) {
            if (!state || this.blocks.length === 0) \
return;
            var maxIdx = this.blocks.length - 1;

            if (state.formVisible
                && state.currentBlockIndex >= 0) {
                this.currentBlockIndex = Math.min(\
state.currentBlockIndex, maxIdx);
                this.highlightStart = Math.min(\
state.highlightStart || 0, maxIdx);
                this.highlightEnd = Math.min(\
state.highlightEnd || 0, maxIdx);
                // A toolbar comes back as a toolbar. The browser
                // selection cannot survive a reload, so Cmd+C is
                // gone, but the row highlight and the copy button
                // both work off the restored range — promoting
                // into the form from here behaves as it would
                // have before the content changed underneath.
                this.selectionOnly = !!state.selectionOnly;
                this.formElement.classList.toggle(
                    'selection-only', this.selectionOnly);
                this.updateHighlights();
                this.positionForm();
                this.formElement.style.display = '';
                this.updateFormReference();
                if (state.textareaValue) {
                    var ta = this.formElement\
.querySelector('textarea');
                    if (ta) {
                        ta.value = state.textareaValue;
                        autoGrow(ta);
                    }
                }
            }
            if (state.expandedNumber != null) {
                this.expandAnnotation(\
state.expandedNumber);
            }
        },

        focusTextarea() {
            var ta = this.formElement
                ? this.formElement.querySelector(\
'textarea')
                : null;
            if (ta) ta.focus();
        },

        updateHighlights() {
            var hs = this.highlightStart;
            var he = this.highlightEnd;
            this.blocks.forEach(function(block, i) {
                var inFormRange = hs >= 0 && he >= 0
                    && i >= hs && i <= he;
                var hasExpanded = block.classList\
.contains(\
'annotation-expanded-highlight');
                block.classList.toggle(\
'annotation-highlight',
                    inFormRange && !hasExpanded);
            });
        },

        createForm() {
            var form = document.createElement('div');
            form.className = 'annotation-form';
            form.id = 'annotation-form';
            form.style.display = 'none';
            // Whole-artifact annotations have no "lines" to
            // copy — skip the affordance there. Ranged
            // forms are display:none until a selection is
            // made, so the button is effectively hidden
            // until a range exists.
            var copyBtnHTML =
                (this.anchorType === 'whole' ||
                 typeof window.GalaxyClipboard
                     === 'undefined')
                    ? ''
                    : window.GalaxyClipboard.buttonHTML(
                        'annotation-copy-lines',
                        'Copy lines');
            // Suggestion-insert affordance — same gate
            // as copy. Inserts the captured text into the
            // form textarea wrapped in a `suggestion`
            // fenced block.
            var suggestBtnHTML =
                (this.anchorType === 'whole' ||
                 typeof window.GalaxySuggestion
                     === 'undefined')
                    ? ''
                    : window.GalaxySuggestion.buttonHTML(
                        'annotation-suggest',
                        'Add a suggestion');
            // Copies the location rather than the content.
            // Only offered where a reference can actually name
            // something — a path plus real lines.
            var refBtnHTML =
                (this.anchorType === 'whole' ||
                 !this.canReference() ||
                 typeof window.GalaxyClipboard
                     === 'undefined')
                    ? ''
                    : window.GalaxyClipboard.refButtonHTML(
                        'annotation-copy-ref',
                        'Copy reference');
            // Promotes the selection toolbar into this form.
            // Same gate as the other two: whole-anchor mode has
            // no selection to promote from.
            var addNoteBtnHTML =
                (this.anchorType === 'whole' ||
                 typeof window.GalaxyAddNote
                     === 'undefined')
                    ? ''
                    : window.GalaxyAddNote.buttonHTML(
                        'annotation-addnote',
                        'Add a note');
            form.innerHTML =
                '<div class="annotation-form-header">'
                + '<span class="annotation-form-ref">'
                + '</span>'
                + copyBtnHTML
                + refBtnHTML
                + suggestBtnHTML
                + addNoteBtnHTML
                + '</div>'
                + window.GalaxyCardText.composerTextareaHTML(
                    'annotation-textarea',
                    { placeholder: 'Add annotation\\u2026', hint: 'save' }
                );

            var ta = form.querySelector('textarea');
            ta.addEventListener('focus', function() {
                AnnotationManager.collapseExpanded();
            });
            installAutoGrow(ta);
            // Escape is deliberately not claimed here: this surface reports
            // its escape context to the host, which decides between closing a
            // popup, abandoning the form, and leaving the reader.
            window.GalaxyCardText.bindCardComposer(ta, {
                onSubmit: function() {
                    AnnotationManager.submitCreate();
                }
            });

            if (typeof EmojiAutocomplete \
!== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            // Wire the form's copy-lines button (omitted
            // for whole-anchor mode in the innerHTML
            // above — querySelector returns null there
            // and we no-op).
            var formCopyBtn = form.querySelector(
                '.annotation-copy-lines');
            if (formCopyBtn
                && window.GalaxyClipboard) {
                var managerRef = AnnotationManager;
                window.GalaxyClipboard.bindCopyButton(
                    formCopyBtn,
                    function() {
                        return managerRef
                            .capturedTextForForm();
                    },
                    'Copy lines'
                );
            }

            // Wire the form's suggestion-insert button
            // (omitted in whole-anchor mode by the same
            // gate as copy). Reuses capturedTextForForm
            // so the suggestion block matches what would
            // be copied or persisted byte-for-byte.
            var formSuggestBtn = form.querySelector(
                '.annotation-suggest');
            if (formSuggestBtn
                && window.GalaxySuggestion) {
                var suggestManagerRef = AnnotationManager;
                window.GalaxySuggestion.bindSuggestionButton(
                    formSuggestBtn,
                    function() {
                        return suggestManagerRef
                            .capturedTextForForm();
                    },
                    function() {
                        return form.querySelector(
                            '.annotation-textarea');
                    }
                );
            }

            // Copy the location. Same binding helper as the
            // copy-lines button, so it inherits the clipboard
            // write and the copied confirmation; only the text
            // it produces differs.
            var formRefBtn = form.querySelector(
                '.annotation-copy-ref');
            if (formRefBtn && window.GalaxyClipboard) {
                var refManagerRef = AnnotationManager;
                window.GalaxyClipboard.bindCopyButton(
                    formRefBtn,
                    function() {
                        return refManagerRef
                            .referenceForForm();
                    },
                    'Copy reference'
                );
            }

            // Promote the toolbar into this form. Only visible
            // while the form is in its selection-only state.
            var formAddNoteBtn = form.querySelector(
                '.annotation-addnote');
            if (formAddNoteBtn && window.GalaxyAddNote) {
                var promoteRef = AnnotationManager;
                window.GalaxyAddNote.bindAddNoteButton(
                    formAddNoteBtn,
                    function() {
                        promoteRef.promoteToForm();
                    }
                );
            }

            this.formElement = form;
            document.body.appendChild(form);

            this.resizeObserver = new ResizeObserver(\
function() {
                AnnotationManager.syncAllPositions();
            });
            this.resizeObserver.observe(form);
        },

        positionForm(skipScroll) {
            var targetBlock = this.blocks[\
this.highlightEnd];
            if (!targetBlock || !this.formElement) \
return;

            this.removeSpacer(this.formSpacer,
                this.formSpacerRow);

            var insertBefore = targetBlock\
.nextElementSibling;
            while (insertBefore && (
                insertBefore.classList.contains(\
'annotation-spacer') ||
                insertBefore.classList.contains(\
'annotation-spacer-row')
            )) {
                insertBefore = insertBefore\
.nextElementSibling;
            }

            var result = this.createSpacer(
                targetBlock.parentNode,
                insertBefore, 'form-spacer'
            );
            this.formSpacer = result.spacer;
            this.formSpacerRow = result.spacerRow;

            this.updateFormReference();
            this.syncAllPositions();
            if (!skipScroll) {
                this.formElement.scrollIntoView({
                    behavior: 'smooth',
                    block: 'nearest'
                });
            }
        },

        updateFormReference() {
            var range = this.getLineRange(\
this.highlightStart, this.highlightEnd);
            // In a diff reader the selected rows carry
            // file/old/new line attributes; prefer the real
            // file line numbers over the generic "line N"
            // keyed off the global data-line counter.
            var fileRef = this.computeDiffRangeFileRef(
                range.startLine, range.endLine);
            var formatted = this.formatDiffLineRef(
                fileRef);
            var ref;
            if (formatted) {
                ref = formatted;
            } else if (range.startLine
                === range.endLine) {
                ref = this.refPrefix.toLowerCase()
                    + ' ' + range.startLine;
            } else {
                ref = this.refPrefix.toLowerCase()
                    + 's ' + range.startLine
                    + '\\u2013' + range.endLine;
            }
            var label = this.itemLabel
                ? this.itemLabel + ': ' : '';
            var refEl = this.formElement.querySelector(\
'.annotation-form-ref');
            if (refEl) {
                refEl.textContent = label + ref;
            }
        },

        getLineRange(startIdx, endIdx) {
            var startBlock = this.blocks[startIdx];
            var endBlock = this.blocks[endIdx];
            var startLine = parseInt(
                startBlock.getAttribute(this.lineAttr)
            ) || 0;
            var endLine;
            if (this.endLineAttr) {
                endLine = parseInt(
                    endBlock.getAttribute(\
this.endLineAttr)
                ) || 0;
            } else {
                endLine = parseInt(
                    endBlock.getAttribute(this.lineAttr)
                ) || 0;
            }
            return {
                startLine: startLine,
                endLine: endLine
            };
        },

        // Scan rendered .code-line rows inside the
        // global data-line range and lift the file
        // reference (path + per-file line range + which
        // side the numbers reference). Used for both
        // the form preview label while typing and the
        // message payload on submit so the anchor_data
        // stored on disk carries this structured ref.
        //
        // Returns null keys when the selection has no
        // file/line context (header-only range in a
        // non-diff view, or a selection that hit rows
        // without data-file-path).
        //
        // Rule for side: prefer the new-side number if
        // any row in the range has one (add / context /
        // renamed rows all do). Fall back to old-side
        // only when the entire selection is on delete
        // rows. Mixed ranges still show new-side only —
        // keeps the display unambiguous.
        computeDiffRangeFileRef(startLine, endLine) {
            var filePath = null;
            var newNums = [];
            var oldNums = [];
            for (var li = startLine; li <= endLine;
                 li++) {
                var tr = document.querySelector(
                    '[data-line="' + li + '"]');
                if (!tr) continue;
                var fp = tr.getAttribute(
                    'data-file-path');
                if (!filePath && fp) filePath = fp;
                var na = tr.getAttribute(
                    'data-new-line');
                if (na != null && na !== '') {
                    newNums.push(parseInt(na, 10));
                }
                var oa = tr.getAttribute(
                    'data-old-line');
                if (oa != null && oa !== '') {
                    oldNums.push(parseInt(oa, 10));
                }
            }
            var nums, side;
            if (newNums.length > 0) {
                nums = newNums; side = 'new';
            } else if (oldNums.length > 0) {
                nums = oldNums; side = 'old';
            } else {
                return {
                    file_path: filePath,
                    file_start_line: null,
                    file_end_line: null,
                    file_line_side: null
                };
            }
            var min = nums[0], max = nums[0];
            for (var j = 1; j < nums.length; j++) {
                if (nums[j] < min) min = nums[j];
                if (nums[j] > max) max = nums[j];
            }
            return {
                file_path: filePath,
                file_start_line: min,
                file_end_line: max,
                file_line_side: side
            };
        },

        // Render a fileRef object into a display string
        // like "tools/diff/foo.cr:146" or
        // "tools/diff/foo.cr:140\\u2013146" for ranges.
        // Returns null when the ref has no path — caller
        // falls back to the generic "line N" label.
        // Labels a diff selection by its line numbers in the
        // file, not by the diff's own flattened row indices.
        // The path is deliberately left out: a card sits among
        // the rows of the file it annotates, directly under a
        // header naming that file, so repeating it says nothing
        // the reader cannot already see and costs enough width
        // on a nested path to wrap the label onto a second line.
        // The path is still captured and sent with the
        // annotation — this governs the label alone.
        //
        // Requires file_path even though it goes unprinted: its
        // presence is what marks these numbers as file lines
        // rather than row indices. Without it the caller falls
        // back to labelling by row index.
        formatDiffLineRef(fileRef) {
            if (!fileRef || !fileRef.file_path) {
                return null;
            }
            if (fileRef.file_start_line == null) {
                return null;
            }
            if (fileRef.file_start_line
                === fileRef.file_end_line) {
                return this.refPrefix.toLowerCase()
                    + ' ' + fileRef.file_start_line;
            }
            return this.refPrefix.toLowerCase()
                + 's ' + fileRef.file_start_line
                + '\\u2013'
                + fileRef.file_end_line;
        },

        renderAllAnnotations() {
            if (typeof EmojiAutocomplete \
!== 'undefined') {
                var editTas = document.querySelectorAll(\
'.annotation-edit-textarea');
                editTas.forEach(function(ta) {
                    EmojiAutocomplete.detach(ta);
                });
            }
            this.clearDeleteConfirmation();
            for (var num in this.cardSpacers) {
                var entry = this.cardSpacers[num];
                this.removeSpacer(entry.spacer,
                    entry.spacerRow);
                if (this.resizeObserver && entry.card) {
                    this.resizeObserver.unobserve(\
entry.card);
                }
                if (entry.card && entry.card.parentNode)
                    entry.card.remove();
            }
            this.cardSpacers = {};
            // The registry above is keyed by annotation number, so
            // two records sharing a number leave the first card
            // untracked once the second insert overwrites its entry,
            // and the loop cannot reach it. Sweep the document so a
            // render always starts from no cards at all, whatever
            // state the registry was left in. The loop below rebuilds
            // one card per current annotation.
            var strays = document.querySelectorAll(
                '.annotation-card');
            for (var s = 0; s < strays.length; s++) {
                if (this.resizeObserver)
                    this.resizeObserver.unobserve(strays[s]);
                strays[s].remove();
            }
            for (var i = 0; i < this.annotations.length;
                 i++) {
                var ann = this.annotations[i];
                var html = this.annotationHTMLMap[\
ann.number] || '';
                this.insertCard(ann, html);
            }
            if (this.formElement)
                this.positionForm(true);
            if (this.expandedNumber !== null) {
                this.applyExpandedHighlight(\
this.expandedNumber);
            }
        },

        refreshAnnotationData(annotations, htmlMap) {
            this.annotations = annotations;
            // Card bodies are spliced from HTML that Swift escapes
            // and owns, so a set carrying annotations this page has
            // not seen before has to arrive with their HTML too.
            // Without it the body lookup falls back to an empty
            // string and the card renders as a shell: the header
            // resolves from the anchor, but nothing goes inside.
            // Callers that only re-render already-known annotations
            // may omit it and keep the existing map.
            if (htmlMap) {
                this.annotationHTMLMap = htmlMap;
            }
            if (this.anchorType === 'whole') {
                this.renderWholeAnnotations();
            } else {
                this.renderAllAnnotations();
            }
        },

        // Re-query the DOM for anchorable rows and
        // re-render all annotation cards against the
        // updated block set. Called after the diff
        // reader dynamically inserts rows — e.g. when
        // the user expands an unchanged-region gap —
        // so annotations anchored to the newly-revealed
        // data-line values can finally find their
        // target rows.
        rescanBlocks() {
            if (this.anchorType === 'whole') return;
            var allBlocks = document.querySelectorAll(
                this.blockSelector
            );
            if (this.blockSelector === '.md-block') {
                this.blocks = Array.from(allBlocks)\
.filter(
                    function(el) {
                        return !el.querySelector(\
'.md-block');
                    }
                );
            } else {
                this.blocks = Array.from(allBlocks);
            }
            this.renderAllAnnotations();
        },

        findBlockIndexForEndLine(endLine) {
            var attr = this.endLineAttr || this.lineAttr;
            for (var i = this.blocks.length - 1;
                 i >= 0; i--) {
                var blockEnd = parseInt(
                    this.blocks[i].getAttribute(attr)
                );
                if (blockEnd <= endLine) return i;
            }
            return 0;
        },

        findBlockIndexForStartLine(startLine) {
            for (var i = 0; i < this.blocks.length;
                 i++) {
                var blockStart = parseInt(
                    this.blocks[i].getAttribute(\
this.lineAttr)
                );
                if (blockStart >= startLine) return i;
            }
            return this.blocks.length - 1;
        },

        insertCard(annotation, renderedHTML) {
            var startKey = this.anchorStartKey();
            var endKey = this.anchorEndKey();
            var endVal = annotation[endKey]
                || annotation[startKey];
            var blockIdx = this.findBlockIndexForEndLine(\
endVal);
            var block = this.blocks[blockIdx];
            if (!block) return;

            var startVal = annotation[startKey];
            var lineRef;
            // Prefer the structured file reference when
            // the annotation was captured with it
            // (diff_range annotations on .gdiff
            // artifacts after this change). Older
            // annotations — including diff_range ones
            // saved before this field was added — lack
            // `file_path` and fall through to the
            // legacy "line N" label keyed off the
            // global data-line counter.
            var fileFormatted = this.formatDiffLineRef({
                file_path: annotation.file_path,
                file_start_line:
                    annotation.file_start_line,
                file_end_line:
                    annotation.file_end_line,
                file_line_side:
                    annotation.file_line_side
            });
            if (fileFormatted) {
                lineRef = fileFormatted;
            } else if (startVal === endVal) {
                lineRef = this.refPrefix.toLowerCase()
                    + ' ' + startVal;
            } else {
                lineRef = this.refPrefix.toLowerCase()
                    + 's ' + startVal
                    + '\\u2013' + endVal;
            }

            var isExpanded = this.expandedNumber
                === annotation.number;
            var hasReview = !!annotation.review_number;

            var metaText = '#' + annotation.number;
            if (hasReview) {
                metaText += ' \\u00B7 Review #'
                    + annotation.review_number;
                if (annotation.review_reviewed_at) {
                    metaText += ' \\u00B7 '
                        + this.formatReviewDate(\
annotation.review_reviewed_at);
                }
            }

            var actionsHTML = hasReview ? '' :
                '<span class=\
"annotation-card-actions">' +
                    '<button class=\
"annotation-btn-edit" title="Edit">' +
                        this.editIconSVG + '</button>' +
                    '<button class=\
"annotation-btn-delete" title="Delete">' +
                        this.deleteIconSVG
                        + '</button>' +
                '</span>';

            // Copy-lines button. Lives outside the
            // hasReview gate — copy is read-only and stays
            // available on review-locked cards (which
            // hide edit + delete).
            var copyBtnHTML =
                (typeof window.GalaxyClipboard
                    === 'undefined')
                    ? ''
                    : window.GalaxyClipboard.buttonHTML(
                        'annotation-copy-lines',
                        'Copy lines');
            // Copies this card's location. Gated the same way
            // as in the form — a reader with no path and no
            // per-row path never renders it.
            var refBtnHTML =
                (!this.canReference() ||
                 typeof window.GalaxyClipboard
                     === 'undefined')
                    ? ''
                    : window.GalaxyClipboard.refButtonHTML(
                        'annotation-copy-ref',
                        'Copy reference');
            // Suggestion-insert button. Always rendered;
            // CSS hides it in the show state and reveals
            // it once an edit textarea is active. Review-
            // locked cards never reach edit so the button
            // never surfaces there.
            var suggestBtnHTML =
                (typeof window.GalaxySuggestion
                    === 'undefined')
                    ? ''
                    : window.GalaxySuggestion.buttonHTML(
                        'annotation-suggest',
                        'Add a suggestion');

            var card = document.createElement('div');
            card.className = 'annotation-card'
                + (isExpanded ? ' expanded' : '');
            card.setAttribute('data-number',
                annotation.number);
            // Stamp the file path on the card so the
            // file-collapse handler can find + hide
            // annotations anchored inside a given file
            // without re-reading the annotation record.
            //
            // Prefer the annotation's explicit
            // file_path (captured at save time for
            // diff_range annotations created after this
            // change). Fall back to the target block's
            // data-file-path so legacy annotations
            // (diff_range records saved before the
            // file_path field existed, plus any future
            // anchor type whose target row exposes the
            // attribute) participate in file-collapse
            // just the same. Only diff rows carry
            // data-file-path — in non-diff views the
            // attribute is absent and we simply don't
            // stamp anything.
            var cardFilePath = annotation.file_path;
            if (!cardFilePath && block) {
                cardFilePath = block.getAttribute(
                    'data-file-path');
            }
            if (cardFilePath) {
                card.setAttribute('data-file-path',
                    cardFilePath);
                // If the owning file-card is currently
                // collapsed, apply file-hidden at
                // creation so this freshly-inserted
                // card doesn't pop into view. Needed
                // because rescanBlocks (triggered by
                // gap-expand in any other file) wipes
                // and re-creates every card — without
                // this check, collapsed files would
                // leak their annotations whenever a
                // rescan happened elsewhere. Iterating
                // .file-card.collapsed avoids the CSS
                // attribute-selector escaping trap for
                // paths containing special chars.
                var collapsedCards = document
                    .querySelectorAll(
                        '.file-card.collapsed');
                for (var ci = 0;
                     ci < collapsedCards.length; ci++) {
                    if (collapsedCards[ci]
                        .getAttribute(
                            'data-file-path')
                        === cardFilePath) {
                        card.classList.add(
                            'file-hidden');
                        break;
                    }
                }
            }
            card.innerHTML =
                '<div class=\
"annotation-card-header">' +
                    '<span class=\
"annotation-card-ref">'
                    + lineRef + '</span>' +
                    '<span class=\
"annotation-card-meta">'
                    + metaText + '</span>' +
                    copyBtnHTML +
                    refBtnHTML +
                    suggestBtnHTML +
                    '<span class=\
"annotation-expand-hint"'
                    + (isExpanded
                        ? ' style="display:none"'
                        : '')
                    + '>Click to expand</span>' +
                    actionsHTML +
                '</div>' +
                '<pre class=\
"annotation-card-content verbatim-card-content'
                + (isExpanded ? '' : ' collapsed')
                + '">' +
                    renderedHTML +
                '</pre>';

            var self = this;
            card.addEventListener('click', function(e) {
                if (e.target.closest(\
'.annotation-card-actions') ||
                    e.target.closest(\
'.annotation-copy-lines') ||
                    e.target.closest(\
'.annotation-copy-ref') ||
                    e.target.closest(\
'.annotation-suggest') ||
                    e.target.closest(\
'.annotation-edit-textarea')) return;
                self.expandAnnotation(\
annotation.number);
            });

            if (!hasReview) {
                card.querySelector(\
'.annotation-btn-edit').addEventListener(
                    'click', function(e) {
                        e.stopPropagation();
                        self.startEdit(\
annotation.number);
                    }
                );
                card.querySelector(\
'.annotation-btn-delete').addEventListener(
                    'click', function(e) {
                        e.stopPropagation();
                        self.handleDeleteClick(\
annotation.number);
                    }
                );
            }

            // Wire the copy-lines button. Renders for
            // every ranged annotation (including
            // review-locked) — copy is read-only.
            var cardCopyBtn = card.querySelector(
                '.annotation-copy-lines');
            if (cardCopyBtn
                && window.GalaxyClipboard) {
                window.GalaxyClipboard.bindCopyButton(
                    cardCopyBtn,
                    function() {
                        return self
                            .capturedTextForAnnotation(
                                annotation);
                    },
                    'Copy lines'
                );
            }

            // Wire the copy-reference button. Reads the
            // annotation's own stored range, so a card names
            // where it is anchored rather than wherever the
            // selection happens to be.
            var cardRefBtn = card.querySelector(
                '.annotation-copy-ref');
            if (cardRefBtn && window.GalaxyClipboard) {
                window.GalaxyClipboard.bindCopyButton(
                    cardRefBtn,
                    function() {
                        return self
                            .referenceForAnnotation(
                                annotation);
                    },
                    'Copy reference'
                );
            }

            // Wire the suggestion-insert button. CSS
            // hides this in the show state, reveals it
            // when an edit textarea is active. Target
            // textarea is looked up at click time so it
            // picks up the freshly-mounted edit textarea
            // created by startEdit.
            var cardSuggestBtn = card.querySelector(
                '.annotation-suggest');
            if (cardSuggestBtn
                && window.GalaxySuggestion) {
                window.GalaxySuggestion.bindSuggestionButton(
                    cardSuggestBtn,
                    function() {
                        return self
                            .capturedTextForAnnotation(
                                annotation);
                    },
                    function() {
                        return card.querySelector(
                            '.annotation-edit-textarea');
                    }
                );
            }

            // Suppress the 2nd click of a double-click so it
            // doesn't toggle expand. Capture phase +
            // stopImmediatePropagation ensures this runs before
            // the bubble-phase toggle handler and prevents it
            // from firing on the 2nd click.
            card.addEventListener('click', function(e) {
                if (e.detail >= 2) {
                    e.stopImmediatePropagation();
                }
            }, true);

            // Double-click anywhere on the card → enter edit,
            // same path as the pencil icon. Same exclusions as
            // the toggle handler. Gated on !hasReview matching
            // the existing edit-button gate (review-locked
            // annotations have no edit affordance).
            if (!hasReview) {
                card.addEventListener(\
'dblclick', function(e) {
                    if (e.target.closest(\
'.annotation-card-actions') ||
                        e.target.closest(\
'.annotation-copy-lines') ||
                        e.target.closest(\
'.annotation-copy-ref') ||
                        e.target.closest(\
'.annotation-suggest') ||
                        e.target.closest(\
'.annotation-edit-textarea'))
                        return;
                    self.startEdit(annotation.number);
                });
            }

            var insertBefore = block\
.nextElementSibling;
            while (insertBefore && (
                insertBefore.classList.contains(\
'annotation-spacer') ||
                insertBefore.classList.contains(\
'annotation-spacer-row')
            )) {
                insertBefore = insertBefore\
.nextElementSibling;
            }
            var result = this.createSpacer(
                block.parentNode,
                insertBefore, 'card-spacer'
            );

            document.body.appendChild(card);
            this.cardSpacers[annotation.number] = {
                spacer: result.spacer,
                spacerRow: result.spacerRow,
                card: card
            };
            if (this.resizeObserver)
                this.resizeObserver.observe(card);
        },

        anchorStartKey() {
            switch (this.anchorType) {
                case 'row_range': return 'start_row';
                case 'block_range': return 'start_block';
                default: return 'start_line';
            }
        },

        anchorEndKey() {
            switch (this.anchorType) {
                case 'row_range': return 'end_row';
                case 'block_range': return 'end_block';
                default: return 'end_line';
            }
        },

        // Returns the captured source text for an existing
        // annotation. Prefers the field that was persisted
        // at save time (line_content / row_content /
        // block_content — see ArtifactsView.swift's
        // create-annotation handler ~L1895-L2055). Falls
        // back to slicing this.artifactContent for
        // surfaces that don't ship the captured fields
        // (snapshots — SnapshotAnnotation has no
        // anchorData), then to a DOM scan as last resort.
        capturedTextForAnnotation(annotation) {
            if (!annotation) return '';
            // Diff rows first, and ahead of line_content,
            // because that one is deliberately prefixed
            // with add and delete markers for a reviewing
            // agent — text nobody wants pasted back into a
            // file. Use the unmarked form when the
            // annotation carries one, and otherwise rebuild
            // it from the rendered rows, which is how
            // annotations written before that field existed
            // still come out clean.
            if (typeof annotation.source_content
                === 'string'
                && annotation.source_content.length > 0) {
                return annotation.source_content;
            }
            var ds = annotation[this.anchorStartKey()];
            var de = annotation[this.anchorEndKey()];
            if (typeof ds === 'number'
                && typeof de === 'number') {
                var diffSource = this
                    .extractDiffRangeText(ds, de);
                if (diffSource !== null) return diffSource;
            }
            if (typeof annotation.line_content === 'string'
                && annotation.line_content.length > 0) {
                return annotation.line_content;
            }
            if (typeof annotation.row_content === 'string'
                && annotation.row_content.length > 0) {
                return annotation.row_content;
            }
            if (typeof annotation.block_content
                === 'string'
                && annotation.block_content.length > 0) {
                return annotation.block_content;
            }
            var startKey = this.anchorStartKey();
            var endKey = this.anchorEndKey();
            var s = annotation[startKey];
            var e = annotation[endKey];
            if (typeof s !== 'number'
                || typeof e !== 'number') return '';
            // Prefer the source artifact content (1:1
            // with what Swift would persist) for line /
            // row ranges. Falls through to the DOM scan
            // for block_range and for surfaces where
            // artifactContent wasn't plumbed.
            if (this.anchorType === 'line_range'
                || this.anchorType === 'row_range') {
                var sliced = this.sliceArtifactContent(
                    s, e);
                if (sliced) return sliced;
            }
            return this.extractTextForRange(s, e);
        },

        // Returns the captured source text for the form's
        // currently-selected range. Produces the same
        // string Swift would persist as line_content /
        // row_content / block_content if the user hit
        // submit right now. Branches by anchor type:
        //   - line_range diff: use the diff-row prefix
        //     extraction (mirrors createDiffRange)
        //   - line_range / row_range: slice the source
        //     artifactContent
        //   - block_range: textContent of selected blocks
        //     (mirrors submitCreate's blockContent)
        //   - whole: no captured text
        // Whether this reader can name a location at all. A
        // path plus real lines earns the affordance; a reader
        // with neither never renders it.
        canReference() {
            if (this.referencePath) return true;
            // A diff spans many files, so it carries a path per
            // row rather than one for the artifact — its rows
            // are the only place that path exists. Note the diff
            // reader is configured as line_range, so anchorType
            // cannot be used to recognise it.
            return !!document.querySelector(
                '[data-file-path]');
        },

        // path:line, or path:start-end for a range. Plain
        // hyphen, not the en dash used for display, so the
        // result matches what the editor plugins produce.
        joinRef(path, start, end) {
            if (!path) return '';
            if (start == null) return path;
            if (end == null || end === start) {
                return path + ':' + start;
            }
            return path + ':' + start + '-' + end;
        },

        // A diff resolves its own path per row, since one
        // artifact spans many files. Everything else uses the
        // artifact's, which is absolute where the file was read
        // from disk. A diff's is relative — that is all a diff
        // records, and inventing an absolute one from the
        // session's directory would be right until it wasn't.
        // Resolve a diff selection to a reference, given the
        // global row values getLineRange returns — not block
        // indices. Deliberately separate from
        // computeDiffRangeFileRef, which serves the display
        // label and the create payload and must keep answering
        // exactly as it does.
        //
        // Only the new side is used. A removed line's old number
        // names a line the file no longer has, so a reference
        // built from it would send a reader somewhere that does
        // not exist. Where a selection is nothing but removals
        // there is no new number in it, and the nearest one
        // above is the place those lines used to sit — which is
        // where someone following the reference wants to land.
        diffReference(startVal, endVal) {
            var rowAt = function(v) {
                return document.querySelector(
                    '[data-line="' + v + '"]');
            };
            var newLineOf = function(el) {
                if (!el) return null;
                var v = el.getAttribute('data-new-line');
                if (v == null || v === '') return null;
                var n = parseInt(v, 10);
                return isNaN(n) ? null : n;
            };
            var filePath = null;
            var nums = [];
            for (var v = startVal; v <= endVal; v++) {
                var el = rowAt(v);
                if (!el) continue;
                var fp = el.getAttribute('data-file-path');
                if (!filePath && fp) filePath = fp;
                var n = newLineOf(el);
                if (n != null) nums.push(n);
            }
            if (!filePath) return '';

            if (nums.length === 0) {
                // Pure removal. Walk outward for the nearest
                // surviving line, staying inside this file.
                var LIMIT = 400;
                var found = null;
                for (var up = startVal - 1;
                     up >= startVal - LIMIT && found == null;
                     up--) {
                    var eu = rowAt(up);
                    if (!eu) continue;
                    if (eu.getAttribute('data-file-path')
                        !== filePath) break;
                    found = newLineOf(eu);
                }
                for (var dn = endVal + 1;
                     found == null && dn <= endVal + LIMIT;
                     dn++) {
                    var ed = rowAt(dn);
                    if (!ed) continue;
                    if (ed.getAttribute('data-file-path')
                        !== filePath) break;
                    found = newLineOf(ed);
                }
                // Nothing survives anywhere in the file — it was
                // deleted outright. The path alone is the whole
                // truth available.
                if (found == null) return filePath;
                return this.joinRef(filePath, found, found);
            }

            var min = nums[0], max = nums[0];
            for (var j = 1; j < nums.length; j++) {
                if (nums[j] < min) min = nums[j];
                if (nums[j] > max) max = nums[j];
            }
            return this.joinRef(filePath, min, max);
        },

        buildReference(startIdx, endIdx) {
            if (startIdx < 0 || endIdx < 0) return '';
            var range = this.getLineRange(startIdx, endIdx);
            var diffRef = this.diffReference(
                range.startLine, range.endLine);
            if (diffRef) return diffRef;
            if (!this.referencePath) return '';
            var lines = this.referenceLineRange(
                startIdx, endIdx);
            return this.joinRef(this.referencePath,
                lines.startLine, lines.endLine);
        },

        // A reference wants source lines, which is not always
        // what a reader anchors by. The table anchors by row
        // ordinal, and a row stops being a line the moment a
        // quoted field spans one — so rows carry the line they
        // began on, and it wins here when present. Readers that
        // already anchor by line resolve the same either way.
        referenceLineRange(startIdx, endIdx) {
            var a = this.blocks[startIdx];
            var b = this.blocks[endIdx];
            var sv = a && a.getAttribute
                ? a.getAttribute('data-line-start') : null;
            var ev = b && b.getAttribute
                ? b.getAttribute('data-line-start') : null;
            if (sv != null && ev != null) {
                var s = parseInt(sv, 10);
                var e = parseInt(ev, 10);
                if (!isNaN(s) && !isNaN(e)) {
                    return {
                        startLine: Math.min(s, e),
                        endLine: Math.max(s, e)
                    };
                }
            }
            return this.getLineRange(startIdx, endIdx);
        },

        // The source line a stored row ordinal sits on, read
        // back from the rendered row.
        lineForRow(row) {
            if (row == null) return null;
            var el = document.querySelector(
                '[data-row="' + row + '"]');
            if (!el) return null;
            var v = el.getAttribute('data-line-start');
            if (v == null) return null;
            var n = parseInt(v, 10);
            return isNaN(n) ? null : n;
        },

        referenceForForm() {
            return this.buildReference(
                this.highlightStart, this.highlightEnd);
        },

        // A card names the range it was anchored to, read from
        // fields the annotation already carries — never the
        // selection that happens to be live.
        referenceForAnnotation(a) {
            if (!a) return '';
            // Resolve a diff card from its stored row range
            // rather than its stored file lines: those were
            // recorded from whichever side the selection had,
            // and an old-side number names a line the file no
            // longer contains.
            if (a.file_path && a.start_line != null) {
                var diffRef = this.diffReference(
                    a.start_line,
                    a.end_line != null
                        ? a.end_line : a.start_line);
                if (diffRef) return diffRef;
            }
            if (!this.referencePath) return '';
            var s, e;
            if (this.anchorType === 'row_range') {
                // Stored rows are ordinals; resolve them back
                // to the lines those rows began on.
                s = this.lineForRow(a.start_row);
                e = this.lineForRow(a.end_row);
                if (s == null) { s = a.start_row; e = a.end_row; }
            } else {
                s = a.start_line;
                e = a.end_line;
            }
            if (s == null) return '';
            return this.joinRef(this.referencePath, s, e);
        },

        capturedTextForForm() {
            if (this.anchorType === 'whole') return '';
            if (this.highlightStart < 0
                || this.highlightEnd < 0) return '';
            var range = this.getLineRange(
                this.highlightStart,
                this.highlightEnd);
            if (this.anchorType === 'line_range') {
                var diffText = this.extractDiffRangeText(
                    range.startLine, range.endLine);
                if (diffText !== null) return diffText;
                var sliced = this.sliceArtifactContent(
                    range.startLine, range.endLine);
                if (sliced) return sliced;
                // Last-resort DOM fallback for line_range
                // surfaces that didn't ship
                // artifactContent and aren't a diff.
                return this.extractTextForRange(
                    range.startLine, range.endLine);
            }
            if (this.anchorType === 'row_range') {
                var rowSliced = this.sliceArtifactContent(
                    range.startLine, range.endLine);
                if (rowSliced) return rowSliced;
                return this.extractTextForRange(
                    range.startLine, range.endLine);
            }
            // block_range: matches submitCreate's
            // blockContent build.
            var blocks = this.blocks.slice(
                this.highlightStart,
                this.highlightEnd + 1);
            return blocks.map(function(b) {
                return (b.textContent || '').trim();
            }).join('\\n');
        },

        // Slice this.artifactContent (the raw source of
        // the artifact / snapshot) by 1-based line or
        // row number. Returns null when artifactContent
        // wasn't plumbed in via init.
        //
        // Mirrors the Swift slice in:
        //   ArtifactsView.swift `case .create` (line)
        //   ArtifactsView.swift `case .createRowRange`
        //   SnapshotsView.swift create-annotation handler
        //
        // For row_range, Swift uses csvLines[start...end]
        // where start = 1 means "first data row" (csv
        // line index 1, since csvLines[0] is the header).
        // The end-exclusive vs end-inclusive distinction
        // also differs from line_range — see the
        // anchor-type branch below.
        sliceArtifactContent(startVal, endVal) {
            if (typeof this.artifactContent !== 'string'
                || this.artifactContent.length === 0) {
                return null;
            }
            var lines = this.artifactContent.split('\\n');
            var startIdx;
            var endIdxExclusive;
            if (this.anchorType === 'row_range') {
                // Row 1 = csvLines[1] (first data row).
                // Range is end-inclusive in Swift, so
                // produce the same shape here.
                startIdx = startVal;
                endIdxExclusive = Math.min(
                    endVal + 1, lines.length);
            } else {
                // line_range / diff_range: 1-based
                // start, end-inclusive.
                startIdx = Math.max(startVal - 1, 0);
                endIdxExclusive = Math.min(
                    endVal, lines.length);
            }
            if (startIdx >= endIdxExclusive) return '';
            return lines.slice(
                startIdx, endIdxExclusive
            ).join('\\n');
        },

        // For diff views: walk the rendered .code-line
        // rows in [startVal, endVal] (data-line counter
        // values) and produce the prefix-encoded string
        // that matches what Swift persists for diff_range
        // (see ArtifactsView.swift `case .createDiffRange`
        // ~L1895-L1933). Returns null when the selection
        // contains no diff rows (i.e. this isn't a diff
        // view) so the caller can fall through to the
        // generic line-range path.
        // Rebuild the selected diff rows as plain source.
        //
        // Reads the code cell alone, so the line-number
        // gutter and the marker column stay out of it, and
        // keeps the row-kind check as a filter: gap,
        // file-header and binary rows are not source and
        // contribute nothing. Returns null when the range
        // held no diff rows at all, which is how every
        // other reader falls through to its own handling.
        //
        // Unmarked deliberately. The marked form lives on
        // the annotation, where a reviewing agent needs to
        // know which rows were added and which removed;
        // this is the form that belongs on a clipboard or
        // inside a suggestion, and pasting a marker back
        // into a file would be wrong.
        extractDiffRangeText(startVal, endVal) {
            var pieces = [];
            var sawDiffRow = false;
            for (var v = startVal; v <= endVal; v++) {
                var tr = document.querySelector(
                    '[data-line="' + v + '"]');
                if (!tr) continue;
                var kind = tr.getAttribute('data-kind');
                if (!kind) continue;
                sawDiffRow = true;
                if (kind !== 'add' && kind !== 'delete'
                    && kind !== 'context') continue;
                var ce = tr.querySelector(
                    '.line-content');
                var text = ce ? (ce.textContent || '') : '';
                pieces.push(text);
            }
            return sawDiffRow ? pieces.join('\\n') : null;
        },

        // Last-resort DOM scan for line / row / block
        // ranges when neither the persisted field nor
        // artifactContent is available. Used by
        // capturedTextForAnnotation for surfaces (mainly
        // snapshots before artifactContent plumbing) and
        // for line_range views without artifactContent.
        extractTextForRange(startVal, endVal) {
            var attr = (this.anchorType === 'row_range'
                || this.anchorType === 'block_range')
                ? this.lineAttr
                : 'data-line';
            var pieces = [];
            for (var v = startVal; v <= endVal; v++) {
                var el = document.querySelector(
                    '[' + attr + '="' + v + '"]');
                if (el) pieces.push(el.textContent || '');
            }
            return pieces.join('\\n');
        },

        expandAnnotation(number) {
            if (this.expandedNumber === number) {
                this.collapseExpanded();
                this.focusTextarea();
                return;
            }

            this.collapseExpanded();

            if (this.editingNumber !== null
                && this.editingNumber !== number) {
                this.cancelEdit();
            }

            this.expandedNumber = number;
            var card = document.querySelector(
                '.annotation-card[data-number="'
                + number + '"]'
            );
            if (card) {
                card.classList.add('expanded');
                var content = card.querySelector(\
'.annotation-card-content');
                if (content)
                    content.classList.remove('collapsed');
                var hint = card.querySelector(\
'.annotation-expand-hint');
                if (hint) hint.style.display = 'none';
                this.syncAllPositions();
                card.scrollIntoView({
                    behavior: 'smooth',
                    block: 'nearest'
                });
            }

            this.applyExpandedHighlight(number);
        },

        collapseExpanded() {
            if (this.expandedNumber === null) return;

            var card = document.querySelector(
                '.annotation-card[data-number="'
                + this.expandedNumber + '"]'
            );
            if (card) {
                card.classList.remove('expanded');
                var content = card.querySelector(\
'.annotation-card-content');
                if (content)
                    content.classList.add('collapsed');
                var hint = card.querySelector(\
'.annotation-expand-hint');
                if (hint) hint.style.display = '';
            }

            this.clearExpandedHighlight();
            this.expandedNumber = null;
            this.updateHighlights();
            this.syncAllPositions();
        },

        applyExpandedHighlight(number) {
            var startKey = this.anchorStartKey();
            var endKey = this.anchorEndKey();
            var ann = this.annotations.find(
                function(a) {
                    return a.number === number;
                }
            );
            if (!ann) return;
            // With no anchorable blocks the two resolvers below
            // disagree in a way that walks off the array: the start
            // falls back to the last index, which is -1 here, while
            // the end falls back to 0, so the loop reads index -1 and
            // dereferences undefined. A rescan that finds nothing —
            // mid-render, or against a document whose rows have gone
            // — is enough to reach it. Given at least one block both
            // fallbacks are themselves valid indices, so the loop
            // needs no further bounds.
            if (!this.blocks.length) return;

            var startIdx = this.findBlockIndexForStartLine(\
ann[startKey]);
            var endVal = ann[endKey] || ann[startKey];
            var endIdx = this.findBlockIndexForEndLine(\
endVal);

            for (var i = startIdx; i <= endIdx; i++) {
                this.blocks[i].classList.add(\
'annotation-expanded-highlight');
                this.blocks[i].classList.remove(\
'annotation-highlight');
            }
        },

        clearExpandedHighlight() {
            this.blocks.forEach(function(block) {
                block.classList.remove(\
'annotation-expanded-highlight');
            });
        },

        createSpacer(parent, insertBefore, className) {
            var spacer = document.createElement('div');
            spacer.className = 'annotation-spacer '
                + className;
            spacer.style.height = '0px';

            var spacerRow = null;
            var parentTag = parent.tagName;
            if (parentTag === 'TBODY'
                || parentTag === 'THEAD') {
                spacerRow = document.createElement('tr');
                spacerRow.className = \
'annotation-spacer-row';
                var td = document.createElement('td');
                td.setAttribute('colspan', '999');
                td.appendChild(spacer);
                spacerRow.appendChild(td);
                parent.insertBefore(spacerRow,
                    insertBefore);
            } else {
                parent.insertBefore(spacer,
                    insertBefore);
            }

            return {
                spacer: spacer,
                spacerRow: spacerRow
            };
        },

        removeSpacer(spacer, spacerRow) {
            if (spacerRow) spacerRow.remove();
            else if (spacer) spacer.remove();
        },

        syncAllPositions() {
            var scrollY = window.pageYOffset
                || document.documentElement.scrollTop;

            // Two-pass: sync all spacer heights first,
            // then read rects and position cards.
            //
            // A single-pass loop that interleaves writes
            // and reads has an iteration-order bug. When
            // entry A is processed before entry B but
            // A's spacer sits BELOW B's in the document,
            // setting B's spacer height grows the page
            // and pushes A's spacer down — but A's card
            // top was already locked to the old rect,
            // stranding A's card above its spacer and
            // leaving an empty band below. Numerically
            // ordered `cardSpacers` keys don't track
            // document order, so the reversal happens
            // whenever a higher-numbered annotation
            // sits later in the document than a
            // lower-numbered one — exactly the initial
            // render case that showed the bug.
            //
            // Splitting the two writes lets all the
            // spacer-height reflows settle first; the
            // rect reads in the second pass then see
            // stable positions for every spacer.
            if (this.formSpacer && this.formElement) {
                this.formSpacer.style.height
                    = this.formElement.offsetHeight
                    + 'px';
            }
            for (var num in this.cardSpacers) {
                var entry = this.cardSpacers[num];
                if (entry.spacer && entry.card) {
                    entry.spacer.style.height
                        = entry.card.offsetHeight
                        + 'px';
                }
            }

            if (this.formSpacer && this.formElement) {
                var fr = this.formSpacer\
.getBoundingClientRect();
                this.formElement.style.top
                    = (fr.top + scrollY) + 'px';
            }
            for (var num2 in this.cardSpacers) {
                var entry2 = this.cardSpacers[num2];
                if (entry2.spacer && entry2.card) {
                    var rect = entry2.spacer\
.getBoundingClientRect();
                    entry2.card.style.top
                        = (rect.top + scrollY) + 'px';
                }
            }
        },

        startEdit(number) {
            if (this.editingNumber !== null)
                this.cancelEdit();
            if (this.expandedNumber !== number) {
                this.expandAnnotation(number);
            }
            this.editingNumber = number;

            var card = document.querySelector(
                '.annotation-card[data-number="'
                + number + '"]'
            );
            if (!card) return;
            var contentDiv = card.querySelector(\
'.annotation-card-content');
            var ann = this.annotations.find(
                function(a) {
                    return a.number === number;
                }
            );
            if (!ann || !contentDiv) return;

            var ta = window.GalaxyCardText.createComposerTextarea(
                'annotation-edit-textarea', ann.content
            );
            contentDiv.replaceWith(ta);

            autoGrow(ta);
            installAutoGrow(ta);
            window.GalaxyCardText.bindCardComposer(ta, {
                onSubmit: function() {
                    AnnotationManager.submitUpdate(number);
                }
            });

            if (typeof EmojiAutocomplete \
!== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            this.syncAllPositions();
            ta.focus();
        },

        cancelEdit() {
            if (this.editingNumber === null) return;
            var card = document.querySelector(
                '.annotation-card[data-number="'
                + this.editingNumber + '"]'
            );
            if (card) {
                var ta = card.querySelector(\
'.annotation-edit-textarea');
                if (typeof EmojiAutocomplete \
!== 'undefined' && ta) {
                    EmojiAutocomplete.detach(ta);
                }
                // Rebuild the content element from the
                // annotation's stored HTML rather than from
                // a snapshot of the pre-edit DOM. A
                // snapshot also captures whatever transient
                // decoration was present when the edit
                // began — a Cmd+F highlight most visibly —
                // and restoring it resurrects that markup
                // for good, because find cannot unwrap a
                // node that has already left the document.
                // Same reconstruction the success path
                // performs after a save.
                var html = this.annotationHTMLMap[\
this.editingNumber];
                if (ta && typeof html === 'string') {
                    var contentDiv
                        = document.createElement('pre');
                    contentDiv.className
                        = 'annotation-card-content '
                        + 'verbatim-card-content';
                    contentDiv.innerHTML = html;
                    ta.replaceWith(contentDiv);
                }
            }
            this.editingNumber = null;
            this.syncAllPositions();
        },

        submitCreate() {
            if (this.submitting) return;

            var ta = this.formElement.querySelector(\
'textarea');
            var content = ta ? ta.value.trim() : '';
            if (!content) return;

            this.submitting = true;

            if (this.anchorType === 'whole') {
                window.webkit.messageHandlers.annotation\
.postMessage({
                    action: 'create',
                    anchorType: 'whole',
                    content: content
                });
                return;
            }

            var range = this.getLineRange(\
this.highlightStart, this.highlightEnd);
            var msg = {
                action: 'create',
                anchorType: this.anchorType,
                content: content
            };
            switch (this.anchorType) {
                case 'row_range':
                    msg.startRow = range.startLine;
                    msg.endRow = range.endLine;
                    break;
                case 'block_range':
                    msg.startBlock = range.startLine;
                    msg.endBlock = range.endLine;
                    var blockTexts = [];
                    var attr = this.lineAttr;
                    for (var bi = range.startLine;
                         bi <= range.endLine; bi++) {
                        var bl = document.querySelector(
                            '[' + attr + '="'
                            + bi + '"]');
                        if (bl) blockTexts.push(
                            bl.textContent.trim());
                    }
                    msg.blockContent =
                        blockTexts.join('\\n');
                    break;
                default:
                    msg.startLine = range.startLine;
                    msg.endLine = range.endLine;
                    // For diff artifacts: scan the
                    // selected rows and attach a
                    // structured anchor payload. This
                    // lets the Swift side build a
                    // `diff_range` anchor_data with
                    // per-row file/line/kind/content
                    // so a reviewing agent can make
                    // sense of the annotation without
                    // re-parsing the .gdiff. Non-diff
                    // views don't emit `data-kind`, so
                    // `rows` stays empty and we fall
                    // through the existing `.create`
                    // path.
                    var rows = [];
                    for (var li = range.startLine;
                         li <= range.endLine; li++) {
                        var tr = document\
.querySelector('[data-line="' + li + '"]');
                        if (!tr) continue;
                        var kind = tr.getAttribute(
                            'data-kind');
                        if (!kind) continue;
                        var ce = tr.querySelector(
                            '.line-content');
                        var text = ce ?
                            ce.textContent : '';
                        var oa = tr.getAttribute(
                            'data-old-line');
                        var na = tr.getAttribute(
                            'data-new-line');
                        rows.push({
                            data_line: li,
                            file_path: tr.getAttribute(
                                'data-file-path'),
                            file_status: tr\
.getAttribute('data-file-status'),
                            kind: kind,
                            old_line: oa == null
                                ? null
                                : parseInt(oa, 10),
                            new_line: na == null
                                ? null
                                : parseInt(na, 10),
                            content: text
                        });
                    }
                    if (rows.length > 0) {
                        msg.rows = rows;
                        // Also lift the structured file
                        // reference so Swift can store
                        // it at top level of anchor_data
                        // — supplies the line numbers the
                        // card's label shows and drives the
                        // file-collapse hide/show logic.
                        var fileRef = this\
.computeDiffRangeFileRef(
                            range.startLine,
                            range.endLine
                        );
                        if (fileRef.file_path) {
                            msg.filePath =
                                fileRef.file_path;
                        }
                        if (fileRef.file_start_line
                            != null) {
                            msg.fileStartLine =
                                fileRef.file_start_line;
                        }
                        if (fileRef.file_end_line
                            != null) {
                            msg.fileEndLine =
                                fileRef.file_end_line;
                        }
                        if (fileRef.file_line_side) {
                            msg.fileLineSide =
                                fileRef.file_line_side;
                        }
                    }
            }
            window.webkit.messageHandlers.annotation\
.postMessage(msg);
        },

        submitUpdate(number) {
            if (this.submitting) return;

            var card = document.querySelector(
                '.annotation-card[data-number="'
                + number + '"]'
            );
            if (!card) return;
            var ta = card.querySelector(\
'.annotation-edit-textarea');
            if (!ta) return;
            var content = ta.value.trim();
            if (!content) return;

            this.submitting = true;

            window.webkit.messageHandlers.annotation\
.postMessage({
                action: 'update',
                number: number,
                content: content
            });
        },

        // The machine is shared; locating this surface's button and telling
        // this surface's host are not. Built on first use so it does not
        // depend on where initialize() happens to run.
        deleteConfirmation() {
            if (!this._deleteConfirmation) {
                this._deleteConfirmation =
                    window.GalaxyCardText.createDeleteConfirmation({
                        findButton: function(number) {
                            return document.querySelector(
                                '.annotation-card[data-number="'
                                + number
                                + '"] .annotation-btn-delete'
                            );
                        },
                        onConfirmed: function(number) {
                            window.webkit.messageHandlers.annotation\
.postMessage({
                                action: 'delete',
                                number: number
                            });
                        }
                    });
            }
            return this._deleteConfirmation;
        },

        handleDeleteClick(number) {
            this.deleteConfirmation().handleClick(number);
        },

        // Kept as a name of its own because the card teardown calls it while
        // rebuilding, where there is no click involved.
        clearDeleteConfirmation() {
            this.deleteConfirmation().clear();
        },

        annotationCreated(data) {
            this.submitting = false;

            var scrollY = window.pageYOffset
                || document.documentElement.scrollTop;

            // Replace rather than append when this number is
            // already known. Numbers restart from one once every
            // annotation on an artifact is deleted, so a record the
            // page still holds can share a number with a genuinely
            // new one. Appending would leave both in the set, and
            // since bodies are keyed by number they would render as
            // twins. Matches how an update reconciles.
            var existingIdx = this.annotations.findIndex(
                function(a) {
                    return a.number
                        === data.annotation.number;
                }
            );
            if (existingIdx >= 0) {
                this.annotations[existingIdx]
                    = data.annotation;
            } else {
                this.annotations.push(data.annotation);
            }
            this.annotationHTMLMap[\
data.annotation.number]
                = data.renderedHTML;

            if (this.anchorType === 'whole') {
                this.annotations.sort(function(a, b) {
                    return a.number - b.number;
                });
                this.renderWholeAnnotations();
                this.dismissForm();
                return;
            }

            var startKey = this.anchorStartKey();
            var endKey = this.anchorEndKey();
            this.annotations.sort(function(a, b) {
                return (a[startKey] - b[startKey])
                    || ((a[endKey] || a[startKey])
                        - (b[endKey] || b[startKey]))
                    || (a.number - b.number);
            });

            this.renderAllAnnotations();
            this.dismissForm();

            window.scrollTo(0, scrollY);
            this.formElement.scrollIntoView({
                block: 'nearest'
            });
        },

        annotationUpdated(data) {
            this.submitting = false;

            var idx = this.annotations.findIndex(
                function(a) {
                    return a.number
                        === data.annotation.number;
                }
            );
            if (idx >= 0)
                this.annotations[idx] = data.annotation;
            this.annotationHTMLMap[\
data.annotation.number]
                = data.renderedHTML;

            if (this.anchorType === 'whole') {
                this.editingNumber = null;
                this.renderWholeAnnotations();
                return;
            }

            // Surgical in-place update: swap the edited
            // card's textarea for a fresh content div.
            // A full renderAllAnnotations() would rip the
            // focused textarea out of the DOM while
            // collapsing every spacer to height 0 — the
            // combination clamps scroll to the top. Only
            // one card's content actually changed, so a
            // targeted DOM swap plus a position sync is
            // enough and leaves scroll untouched.
            var card = document.querySelector(
                '.annotation-card[data-number="'
                + data.annotation.number + '"]'
            );
            if (card) {
                var ta = card.querySelector(\
'.annotation-edit-textarea');
                if (ta) {
                    if (typeof EmojiAutocomplete \
!== 'undefined') {
                        EmojiAutocomplete.detach(ta);
                    }
                    ta.blur();
                    var contentDiv
                        = document.createElement('pre');
                    contentDiv.className
                        = 'annotation-card-content '
                        + 'verbatim-card-content';
                    contentDiv.innerHTML
                        = data.renderedHTML;
                    ta.replaceWith(contentDiv);
                }
            }
            this.editingNumber = null;

            this.syncAllPositions();
        },

        annotationDeleted(number) {
            this.deleteConfirmation().finish();

            if (this.expandedNumber === number) {
                this.collapseExpanded();
            }
            this.annotations = this.annotations.filter(
                function(a) {
                    return a.number !== number;
                }
            );
            delete this.annotationHTMLMap[number];

            if (this.anchorType === 'whole') {
                this.renderWholeAnnotations();
                return;
            }

            // Surgical removal: drop just the deleted
            // card and its spacer. A full
            // renderAllAnnotations() would momentarily
            // collapse every spacer to height 0 — on
            // shorter documents that makes the body
            // drop below the viewport and the browser
            // clamps scrollY (to the top on HTML view,
            // partway up on source view). Only one
            // card's footprint is actually going away,
            // so remove just that one and let the rest
            // sit tight.
            var entry = this.cardSpacers[number];
            if (entry) {
                if (this.resizeObserver && entry.card) {
                    this.resizeObserver.unobserve(\
entry.card);
                }
                if (entry.card && entry.card.parentNode) {
                    entry.card.remove();
                }
                this.removeSpacer(entry.spacer,
                    entry.spacerRow);
                delete this.cardSpacers[number];
            }

            this.syncAllPositions();
        },

        isFormVisible() {
            return this.formElement
                && this.formElement.style.display
                    !== 'none';
        },

        focusForm() {
            if (!this.isFormVisible()) return;
            var ta = this.formElement
                ? this.formElement.querySelector(\
'textarea')
                : null;
            if (ta) ta.focus();
        },

        // True only when text the user typed would be lost by a
        // full re-render: an open form holding content, or an edit
        // whose textarea no longer matches the stored annotation.
        // Committed annotations are excluded, since a re-render
        // rebuilds those from data.
        //
        // Free of side effects, unlike getEscapeContext below, which
        // cancels an unchanged edit as it reports. That makes this
        // safe to probe from anywhere — the refresh action asks it
        // before rebuilding the card DOM.
        hasOpenUnsavedComment() {
            if (this.isFormVisible()) {
                var formTa = this.formElement\
.querySelector('textarea');
                if (formTa && formTa.value.trim())
                    return true;
            }
            if (this.editingNumber !== null) {
                var card = document.querySelector(
                    '.annotation-card[data-number="'
                    + this.editingNumber + '"]'
                );
                if (card) {
                    var ta = card.querySelector(\
'.annotation-edit-textarea');
                    var editing = this.editingNumber;
                    var ann = this.annotations.find(\
function(a) {
                        return a.number === editing;
                    });
                    if (ta && ann
                        && ta.value !== ann.content)
                        return true;
                }
            }
            return false;
        },

        getEscapeContext() {
            if (typeof EmojiAutocomplete \
!== 'undefined') {
                var formTa = this.formElement
                    ? this.formElement.querySelector(\
'textarea') : null;
                if (formTa && EmojiAutocomplete\
.isActive(formTa))
                    return 'emojiPopup';
                if (this.editingNumber !== null) {
                    var editTa = document.querySelector(
                        '.annotation-card[data-number="'
                        + this.editingNumber
                        + '"] .annotation-edit-textarea'
                    );
                    if (editTa && EmojiAutocomplete\
.isActive(editTa))
                        return 'emojiPopup';
                }
            }
            // The send bar's overall comment, if it is open. Answered here
            // rather than on its own textarea because the host's Escape
            // monitor runs ahead of the web view and asks this first, so a
            // handler on the composer alone would never see the key. It
            // collapses and keeps what was typed, which is all Escape means
            // there, so the host is told the page dealt with it.
            if (window.GalaxySendBar
                && window.GalaxySendBar.expanded) {
                window.GalaxySendBar.collapse();
                return '__consumed__';
            }
            if (this.editingNumber !== null) {
                var card = document.querySelector(
                    '.annotation-card[data-number="'
                    + this.editingNumber + '"]'
                );
                if (card) {
                    var ta = card.querySelector(\
'.annotation-edit-textarea');
                    var ann = this.annotations.find(\
function(a) {
                        return a.number
                            === AnnotationManager\
.editingNumber;
                    });
                    if (ta && ann
                        && ta.value !== ann.content)
                        return 'editing';
                }
                this.cancelEdit();
                return '__consumed__';
            }
            if (this.expandedNumber !== null)
                return 'expanded';
            if (this.isFormVisible()) {
                var ta = this.formElement.querySelector(\
'textarea');
                if (ta && ta.value.trim())
                    return 'formHasText';
                return 'formVisible';
            }
            return 'close';
        },

        dismissForm() {
            if (this.formElement) {
                var ta = this.formElement.querySelector(\
'textarea');
                if (ta) { ta.value = ''; autoGrow(ta); }
                this.formElement.style.display = 'none';
                this.formElement.classList.remove(
                    'selection-only');
            }
            this.selectionOnly = false;
            this.removeSpacer(this.formSpacer,
                this.formSpacerRow);
            this.formSpacer = null;
            this.formSpacerRow = null;
            this.highlightStart = -1;
            this.highlightEnd = -1;
            this.currentBlockIndex = -1;
            this.updateHighlights();
            this.syncAllPositions();
        },

        formatReviewDate(dateStr) {
            var d = new Date(
                dateStr.replace(' ', 'T')
                + (dateStr.indexOf('Z') < 0
                    && dateStr.indexOf('+') < 0
                    ? 'Z' : '')
            );
            if (isNaN(d.getTime())) return 'reviewed';
            var months = ['Jan','Feb','Mar','Apr',\
'May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
            return months[d.getMonth()] + ' '
                + d.getDate() + ', '
                + d.getFullYear();
        },

        getFormState() {
            var ta = this.formElement
                ? this.formElement.querySelector(\
'textarea') : null;
            return {
                currentBlockIndex: \
this.currentBlockIndex,
                highlightStart: this.highlightStart,
                highlightEnd: this.highlightEnd,
                formVisible: this.isFormVisible(),
                selectionOnly: this.selectionOnly,
                textareaValue: ta ? ta.value : '',
                expandedNumber: this.expandedNumber
            };
        }
    };

    function handleFileDrop(paths) {
        // Which textarea receives the drop is this surface's own question —
        // the create form if it is open, otherwise the annotation being
        // edited. Everything after that is the same on both card surfaces.
        var ta = null;
        if (AnnotationManager.formElement
            && AnnotationManager.formElement.style.display !== 'none') {
            ta = AnnotationManager.formElement.querySelector('textarea');
        }
        if (!ta && AnnotationManager.editingNumber !== null) {
            ta = document.querySelector(
                '.annotation-card[data-number="'
                + AnnotationManager.editingNumber
                + '"] .annotation-edit-textarea'
            );
        }

        window.GalaxyCardText.insertPaths(ta, paths);
    }
"""
