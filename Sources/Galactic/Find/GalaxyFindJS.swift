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

      // Walk all text nodes under root, skipping script/style and
      // our own <mark> wrappers. Re-applied on every setQuery so
      // existing wrappers are removed by clear() before walking.
      function* textNodes(root) {
        const walker = document.createTreeWalker(
          root, NodeFilter.SHOW_TEXT,
          {
            acceptNode(n) {
              const p = n.parentElement;
              if (!p) return NodeFilter.FILTER_REJECT;
              const tag = p.tagName;
              if (tag === 'SCRIPT' || tag === 'STYLE') {
                return NodeFilter.FILTER_REJECT;
              }
              if (p.classList &&
                  p.classList.contains('galaxy-find-match')) {
                return NodeFilter.FILTER_REJECT;
              }
              return n.nodeValue
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT;
            }
          }
        );
        let n;
        while ((n = walker.nextNode())) yield n;
      }

      let matches = []; // array of <mark> elements
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
        matches = [];
        currentIdx = -1;
      }

      // Phase 1 of the find: synchronous DOM walk that
      // collects what to mutate without actually mutating
      // anything. Cheap (~tens of ms even on long docs) and
      // tells us the total match count up front so the bar
      // can show "1 of 200" before chunking finishes.
      function collectWork(query) {
        const work = [];
        if (!query || !document.body) return work;
        const lower = query.toLowerCase();
        const len = query.length;
        for (const node of textNodes(document.body)) {
          const text = node.nodeValue;
          const lc = text.toLowerCase();
          const ranges = [];
          let i = 0;
          while ((i = lc.indexOf(lower, i)) !== -1) {
            ranges.push([i, i + len]);
            i += len;
          }
          if (ranges.length > 0) {
            work.push({ node, ranges, text });
          }
        }
        return work;
      }

      // Phase 2 step: take one work item and wrap its matches
      // in <mark> elements, splitting the original text node.
      // Pushes the new marks onto `matches` in document order.
      function applyOne(item) {
        const node = item.node;
        const ranges = item.ranges;
        const text = item.text;
        if (!node.parentNode) return;
        const frag = document.createDocumentFragment();
        let cursor = 0;
        for (const [a, b] of ranges) {
          if (a > cursor) {
            frag.appendChild(
              document.createTextNode(text.slice(cursor, a))
            );
          }
          const m = document.createElement('mark');
          m.className = 'galaxy-find-match';
          m.textContent = text.slice(a, b);
          frag.appendChild(m);
          matches.push(m);
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

        function step() {
          if (myGen !== chunkGen) return;
          const end = Math.min(i + CHUNK_SIZE, work.length);
          for (; i < end; i++) {
            applyOne(work[i]);
          }
          if (!reverseMode
              && currentIdx === -1
              && matches.length > 0) {
            currentIdx = 0;
            applyCurrent();
          }
          emit();
          if (i < work.length) {
            window.requestAnimationFrame(step);
          } else {
            if (reverseMode && matches.length > 0) {
              currentIdx = matches.length - 1;
              applyCurrent();
            }
            emit();
          }
        }

        // First chunk runs synchronously inside this turn so
        // the user sees marks light up the same paint cycle
        // they pressed Enter / stopped typing in. Subsequent
        // chunks yield via rAF.
        step();
      }

      function highlight(query) {
        clear();
        currentQuery = query || '';
        if (!currentQuery) return;
        const work = collectWork(currentQuery);
        chunkApply(work);
      }

      function applyCurrent() {
        matches.forEach(m =>
          m.classList.remove('galaxy-find-current')
        );
        if (currentIdx < 0 || currentIdx >= matches.length) return;
        const cur = matches[currentIdx];
        cur.classList.add('galaxy-find-current');
        cur.scrollIntoView({
          behavior: 'instant', block: 'center'
        });
      }

      function step(delta) {
        if (matches.length === 0) return;
        currentIdx =
          (currentIdx + delta + matches.length) % matches.length;
        applyCurrent();
      }

      function emit() {
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.galaxyFind) {
          window.webkit.messageHandlers.galaxyFind.postMessage({
            event: 'matches',
            count: matches.length,
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
          for (const n of textNodes(document.body)) {
            void n.nodeValue.toLowerCase()
              .indexOf('__galaxy_find_warmup__');
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
