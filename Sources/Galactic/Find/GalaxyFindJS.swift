import Foundation

/// JavaScript module that powers Galaxy's Cmd+F find bar.
///
/// Installed once per WKWebView via `WKUserScript` (see
/// `WKWebViewConfiguration+GalaxyFind.installGalaxyFindUserScript`)
/// and exposes `window.GalaxyFind` to Swift, which drives it via
/// `evaluateJavaScript`.
///
/// Match wrapping uses `<mark class="galaxy-find-match">` so it
/// composes cleanly with rendered Markdown's own `<mark>` content
/// — the find spans are styled distinctly from any pre-existing
/// highlights, and `clear()` only removes elements with the
/// galaxy-prefixed class.
///
/// Searching is done a block at a time rather than a text node at
/// a time. A node boundary is not something the reader can see:
/// scrollback emits one span per style run, so a colour change
/// mid-sentence splits a phrase into separate nodes, and matching
/// each node alone silently found less than the page contained.
/// A block is flattened, searched, and the hit split back over
/// whichever nodes it covered — so one match can become several
/// `<mark>` elements, which is why navigation counts groups of
/// marks rather than marks.
///
/// Blocks stop at anything not inline, `<br>` included, so no
/// match spans a line break. Terminal lines are padded to the
/// window width, so joining them would mostly manufacture hits
/// inside blank space.
///
/// Reverse mode (used by the scrollback overlay) flips the
/// initial cursor position and the next/prev step direction so
/// the first match presented is the most-recent occurrence
/// walking up — matching Terminal.app and iTerm behavior.
enum GalaxyFindJS {
    // js-validate
    public static let userScriptSource: String = """
    (function() {
      if (window.GalaxyFind) return; // idempotent

      const STYLE_ID = 'galaxy-find-style';
      if (!document.getElementById(STYLE_ID)) {
        const s = document.createElement('style');
        s.id = STYLE_ID;
        s.textContent = `
          mark.galaxy-find-match {
            background: rgba(255, 220, 50, 0.45);
            color: inherit;
            padding: 0;
            border-radius: 1px;
          }
          mark.galaxy-find-current {
            background: rgba(255, 165, 0, 0.85);
            color: #000;
            outline: 1px solid rgba(0,0,0,0.3);
          }
        `;
        (document.head || document.documentElement).appendChild(s);
      }

      // Elements that do not interrupt a phrase. Everything else
      // ends the run of text being searched — including BR, which
      // draws a line break without being a block itself.
      const INLINE_TAGS = new Set([
        'SPAN', 'EM', 'STRONG', 'B', 'I', 'U', 'S', 'CODE', 'A',
        'MARK', 'SMALL', 'SUB', 'SUP', 'ABBR', 'CITE', 'Q', 'KBD',
        'SAMP', 'VAR', 'TIME', 'DFN', 'INS', 'DEL', 'FONT', 'TT',
        'BIG', 'STRIKE', 'NOBR'
      ]);

      // Case-fold for comparison, without ever changing length.
      //
      // Offsets found in the folded text are used to slice the
      // original, so a fold that grew would point every later
      // offset at the wrong character — and 'İ'.toLowerCase() is
      // two code units. The whole-string path is the fast one and
      // handles all ordinary text; the loop only runs when that
      // path would have shifted something, and folds one code
      // unit at a time so the length cannot move.
      //
      // Non-breaking spaces fold to ordinary ones: the renderer
      // spells a blank line with one, and a typed space should
      // find it.
      function fold(s) {
        const flat = s.replace(/\\u00a0/g, ' ');
        const lower = flat.toLowerCase();
        if (lower.length === flat.length) return lower;
        let out = '';
        for (let i = 0; i < flat.length; i++) {
          const one = flat[i].toLowerCase();
          out += one.length === 1 ? one : flat[i];
        }
        return out;
      }

      // Walk the document yielding runs of text nodes that share a
      // block, in document order. Script, style and our own marks
      // are rejected whole.
      function* blocks(root) {
        const walker = document.createTreeWalker(
          root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT,
          {
            acceptNode(n) {
              if (n.nodeType === Node.ELEMENT_NODE) {
                const tag = n.tagName;
                if (tag === 'SCRIPT' || tag === 'STYLE') {
                  return NodeFilter.FILTER_REJECT;
                }
                if (n.classList &&
                    n.classList.contains('galaxy-find-match')) {
                  return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
              return n.nodeValue
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT;
            }
          }
        );
        let run = [];
        let n;
        while ((n = walker.nextNode())) {
          if (n.nodeType === Node.ELEMENT_NODE) {
            if (!INLINE_TAGS.has(n.tagName) && run.length) {
              yield run;
              run = [];
            }
            continue;
          }
          run.push(n);
        }
        if (run.length) yield run;
      }

      // One entry per match, each holding the <mark> elements it
      // was drawn with — several when the match crossed a node.
      let groups = [];
      // Total matches, known from the collect pass, so the bar can
      // say "1 of 200" before the marks finish going in.
      let totalGroups = 0;
      let currentIdx = -1;
      let currentQuery = '';
      let reverseMode = false;
      // Generation counter used to abort an in-flight chunked
      // apply when a new query arrives. Each setQuery / clear
      // increments it; the rAF chunk loop reads its captured
      // generation and exits if it no longer matches.
      let chunkGen = 0;
      // How many text-node mutations to apply per animation
      // frame. 30 keeps each frame well under the 16ms budget
      // on typical markdown renders. Tune higher for short
      // documents (fewer chunks = less overhead) or lower for
      // very dense ones (each chunk does more layout work).
      const CHUNK_SIZE = 30;

      function clear() {
        // Bumping the generation aborts any in-flight chunk
        // loop on its next rAF tick, before it can install
        // more marks against a stale query.
        chunkGen++;
        const marks = document.querySelectorAll(
          'mark.galaxy-find-match'
        );
        marks.forEach(m => {
          const t = document.createTextNode(m.textContent);
          m.parentNode.replaceChild(t, m);
          if (t.parentNode) t.parentNode.normalize();
        });
        groups = [];
        totalGroups = 0;
        currentIdx = -1;
      }

      // Phase 1 of the find: synchronous walk that collects what
      // to mutate without mutating anything. Cheap (~tens of ms
      // even on long docs) and tells us the total match count up
      // front.
      //
      // Flattening is per block, so the largest string built is
      // one block long — a terminal line. Flattening the whole
      // document instead would allocate the entire scrollback
      // buffer twice over on every keystroke, which at the
      // 100,000-line ceiling is tens of megabytes of garbage per
      // search.
      function collectWork(query) {
        const work = [];
        if (!query || !document.body) return work;
        const needle = fold(query);
        const len = needle.length;
        if (!len) return work;

        // Ranges are collected per node so each node is still
        // replaced exactly once, however many matches touch it.
        const byNode = new Map();
        function addRange(node, a, b, g) {
          let item = byNode.get(node);
          if (!item) {
            item = { node: node, text: node.nodeValue, ranges: [] };
            byNode.set(node, item);
            work.push(item);
          }
          item.ranges.push([a, b, g]);
        }

        let found = 0;
        for (const nodes of blocks(document.body)) {
          let flat = '';
          const starts = [];
          for (const node of nodes) {
            starts.push(flat.length);
            flat += fold(node.nodeValue);
          }

          let at = 0;
          let i;
          while ((i = flat.indexOf(needle, at)) !== -1) {
            const end = i + len;
            const g = found++;
            for (let k = 0; k < nodes.length; k++) {
              const nodeStart = starts[k];
              const nodeEnd =
                nodeStart + nodes[k].nodeValue.length;
              if (nodeEnd <= i || nodeStart >= end) continue;
              addRange(
                nodes[k],
                Math.max(i, nodeStart) - nodeStart,
                Math.min(end, nodeEnd) - nodeStart,
                g
              );
            }
            at = end;
          }
        }
        totalGroups = found;
        return work;
      }

      // Phase 2 step: take one work item and wrap its matches
      // in <mark> elements, splitting the original text node.
      // Each mark joins the group of the match it belongs to.
      function applyOne(item) {
        const node = item.node;
        const ranges = item.ranges;
        const text = item.text;
        if (!node.parentNode) return;
        const frag = document.createDocumentFragment();
        let cursor = 0;
        for (const r of ranges) {
          const a = r[0], b = r[1], g = r[2];
          if (a > cursor) {
            frag.appendChild(
              document.createTextNode(text.slice(cursor, a))
            );
          }
          const m = document.createElement('mark');
          m.className = 'galaxy-find-match';
          m.textContent = text.slice(a, b);
          frag.appendChild(m);
          if (!groups[g]) groups[g] = [];
          groups[g].push(m);
          cursor = b;
        }
        if (cursor < text.length) {
          frag.appendChild(
            document.createTextNode(text.slice(cursor))
          );
        }
        node.parentNode.replaceChild(frag, node);
      }

      // Phase 2 driver: chunk the mutation work across
      // animation frames so a multi-hundred-match query
      // doesn't lock the WebView for seconds. Forward mode
      // promotes the first match to "current" after the very
      // first chunk, so the bar feels responsive immediately.
      // Reverse mode (scrollback) waits until completion to
      // promote the last match — the visual cost is one frame
      // of "all yellow, no orange" while later chunks finish.
      function chunkApply(work) {
        const myGen = chunkGen;
        let i = 0;

        function pump() {
          if (myGen !== chunkGen) return;
          const end = Math.min(i + CHUNK_SIZE, work.length);
          for (; i < end; i++) {
            applyOne(work[i]);
          }
          if (!reverseMode
              && currentIdx === -1
              && groups.length > 0) {
            currentIdx = 0;
          }
          // Re-applied every chunk, not just on promotion: the
          // current match may span nodes this chunk has only
          // now reached, and its later marks would otherwise
          // never be told they are current.
          if (currentIdx >= 0) applyCurrent();
          emit();
          if (i < work.length) {
            window.requestAnimationFrame(pump);
          } else {
            if (reverseMode && groups.length > 0) {
              currentIdx = groups.length - 1;
              applyCurrent();
            }
            emit();
          }
        }

        // First chunk runs synchronously inside this turn so
        // the user sees marks light up the same paint cycle
        // they pressed Enter / stopped typing in. Subsequent
        // chunks yield via rAF.
        pump();
      }

      function highlight(query) {
        clear();
        currentQuery = query || '';
        if (!currentQuery) return;
        const work = collectWork(currentQuery);
        chunkApply(work);
      }

      function applyCurrent() {
        // Cleared by selector rather than by walking the groups:
        // correct even while a group is still being built.
        document.querySelectorAll('mark.galaxy-find-current')
          .forEach(m => m.classList.remove('galaxy-find-current'));
        const group = groups[currentIdx];
        if (!group || group.length === 0) return;
        group.forEach(m => m.classList.add('galaxy-find-current'));
        group[0].scrollIntoView({
          behavior: 'instant', block: 'center'
        });
      }

      function step(delta) {
        const n = groups.length;
        if (n === 0) return;
        currentIdx = (currentIdx + delta + n) % n;
        applyCurrent();
      }

      function emit() {
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.galaxyFind) {
          window.webkit.messageHandlers.galaxyFind.postMessage({
            event: 'matches',
            count: totalGroups,
            index: currentIdx
          });
        }
      }

      // Pre-warm: WebKit lazily compiles JS, primes layout
      // caches, and resolves CSS selector classes the first
      // time they're seen. Without this, the first user query
      // triggers a 2–3s pause for setup work plus the full
      // search. Run a short cycle on idle to amortize that
      // cost into page-load time, when the user can't tell.
      // The dummy mark mutation primes the layout/style
      // pipeline for our specific class.
      function prewarm() {
        try {
          if (!document.body) return;
          for (const nodes of blocks(document.body)) {
            for (const n of nodes) {
              void fold(n.nodeValue)
                .indexOf('__galaxy_find_warmup__');
            }
          }
          const dummy = document.createElement('mark');
          dummy.className = 'galaxy-find-match';
          dummy.textContent = ' ';
          document.body.appendChild(dummy);
          void dummy.offsetWidth;  // force layout
          dummy.remove();
        } catch (e) {}
      }

      if (typeof window.requestIdleCallback === 'function') {
        window.requestIdleCallback(prewarm, { timeout: 3000 });
      } else {
        setTimeout(prewarm, 100);
      }

      window.GalaxyFind = {
        setQuery(q, opts) {
          opts = opts || {};
          const newReverse = !!opts.reverse;
          const newQuery = q || '';
          // Skip the full DOM walk when nothing actionable
          // changed. Swift debounces typing already; this
          // catches the no-op case where the debounced value
          // dedupes back to itself (re-open with same query,
          // programmatic re-applies after rebind, etc.).
          if (newQuery === currentQuery
              && newReverse === reverseMode) {
            return;
          }
          reverseMode = newReverse;
          highlight(newQuery);
          emit();
        },
        next() {
          step(reverseMode ? -1 : 1);
          emit();
        },
        prev() {
          step(reverseMode ? 1 : -1);
          emit();
        },
        close() {
          clear();
          currentQuery = '';
          emit();
        }
      };
    })();
    """
}
