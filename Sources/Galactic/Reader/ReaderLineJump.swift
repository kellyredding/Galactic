import Foundation

/// Scrolling a reader to a line the person naming it can see.
///
/// **The line number is absolute** — the one in the gutter, which is also the
/// one a compiler error, a stack trace and a review comment all quote. Those are
/// the three reasons anyone reaches for this, and none of them hands out an
/// offset from where you happen to be sitting.
///
/// Expressed against the markup the renderers already emit rather than against
/// anything new: a source line is a `tr` carrying its own number, and the
/// highlight pass rewrites only the content cell, so the attribute survives
/// syntax highlighting.
public enum ReaderLineJump {

    /// Where a jumped-to line should sit, as a fraction of the viewport.
    ///
    /// Not the top. A line pinned to the very top has no context above it, and
    /// the reason for jumping is almost always to read *around* something.
    ///
    /// This only works because the line is marked on arrival. Offsetting an
    /// unmarked line puts the answer somewhere in the middle of a screenful of
    /// code with nothing saying which row it is — measurably worse than
    /// top-alignment, which at least implies the top row is what was asked for.
    /// The two decisions are one decision.
    static let restPosition = 0.3

    /// Whether a reader whose markup is described this way can be jumped in.
    ///
    /// Anchoring that numbers its elements can; anchoring that does not — an
    /// image, a rendered table addressed by row ordinal — cannot, and a caller
    /// should say so rather than evaluate a script that quietly finds nothing.
    public static func supports(_ anchoring: ReaderAnchoring) -> Bool {
        !anchoring.lineAttr.isEmpty && !anchoring.blockSelector.isEmpty
    }

    /// A script that goes to `line`, marks it, and answers where it landed.
    ///
    /// Answering matters: a number past the end of the file is the ordinary
    /// mistake, and a caller that cannot tell a miss from a hit has no way to
    /// say so. Returns the line actually reached, or `-1` if the markup carries
    /// no numbered elements at all.
    ///
    /// **The line arrives highlighted, with its toolbar open, and nothing
    /// selected.** Resting the target below the top of the viewport gives it
    /// context above, which is the point of jumping — but an unmarked line
    /// partway down a screen of code is not visibly the answer to anything, and
    /// offsetting without marking is worse than not offsetting at all. Marking
    /// is what makes the position read as deliberate.
    ///
    /// The marking is the row highlight the toolbar already brings with it, not
    /// a text selection. A selection was tried and reverted: over a dimmed
    /// comment it renders the line unreadable, which defeats the reason for
    /// going there. Copying is not lost by leaving it out — the toolbar carries
    /// its own copy of both the line and the reference, and the reference is the
    /// more useful of the two anyway, since a line number in this app almost
    /// always came from somewhere else and arriving at one is usually the step
    /// before citing it.
    ///
    /// The document scrolls, not a container — a reader's body is the scrolling
    /// element, unlike the scrollback, whose own container scrolls inside it.
    /// Using `window.scrollTo` against a container-scrolled page silently does
    /// nothing, which is why this is not shared with the scrollback's version.
    public static func javaScript(
        line: Int, anchoring: ReaderAnchoring
    ) -> String {
        let selector = anchoring.blockSelector
        let attribute = anchoring.lineAttr
        return """
            (function () {
              var wanted = \(line);
              var all = document.querySelectorAll('\(selector)[\(attribute)]');
              if (!all.length) { return -1; }
              var target = null;
              for (var i = 0; i < all.length; i++) {
                var n = parseInt(all[i].getAttribute('\(attribute)'), 10);
                if (n === wanted) { target = all[i]; break; }
              }
              // Past the end lands on the last line rather than refusing. The
              // number came from somewhere — a stack trace against a file since
              // edited — and the end of the file is the honest answer to "as far
              // as that".
              if (!target) {
                var last = all[all.length - 1];
                var lastNumber = parseInt(
                  last.getAttribute('\(attribute)'), 10
                );
                if (wanted > lastNumber) { target = last; } else { return -1; }
              }

              // Cleared, not set. A selection over the line is the one marker
              // that competes with reading it: selection grey over a dimmed
              // comment leaves the text the jump exists to show illegible.
              // Anything left selected from before is dropped too, so a copy
              // taken after arriving cannot quietly act on an older range.
              var selection = window.getSelection();
              if (selection) { selection.removeAllRanges(); }

              // Raised before the scroll is measured, because opening it
              // inserts a spacer and moves everything below the line. Measuring
              // first would scroll to where the line used to be.
              if (typeof AnnotationManager !== 'undefined'
                  && AnnotationManager.blocks) {
                var index = AnnotationManager.blocks.indexOf(target);
                if (index >= 0) {
                  AnnotationManager.showSelectionToolbar(index, index);
                }
              }

              // Deferred one frame so the spacer the toolbar just added has
              // been laid out. Synchronous measurement here reads a geometry
              // that is about to change.
              requestAnimationFrame(function () {
                var box = target.getBoundingClientRect();
                var top = box.top + window.pageYOffset
                  - window.innerHeight * \(restPosition);
                window.scrollTo({ top: Math.max(0, top), behavior: 'instant' });
              });

              return parseInt(target.getAttribute('\(attribute)'), 10);
            })()
            """
    }
}
