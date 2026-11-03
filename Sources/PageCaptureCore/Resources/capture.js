// PageCapture picker and auto-scroll collector.
// Injected at document start into every frame (cross-origin iframes included) in the PageCapture
// content world, after merge.js. Talks to the app through the `pageCapture` message handler:
//   { type: 'frameReady' }                                  when this frame's document starts
//   { type: 'picked', kind: 'element'|'document'|'wholePage' }  when the user clicks in picker mode
//   { type: 'frameToken', token }                           when the parent frame names this frame
// and asks it through the `pageCaptureAsk` handler, which replies:
//   { type: 'frameVideos', tokens, options } → { token: JSON of frameVideos() in that child frame }
(function () {
  'use strict';
  if (globalThis.__pageCapture) return;

  const Merge = globalThis.PageCaptureMerge;
  const HANDLER = 'pageCapture';
  const UI_ATTR = 'data-pagecapture-ui';
  const isTop = window === window.top;

  function post(message) {
    const handlers = window.webkit && window.webkit.messageHandlers;
    if (handlers && handlers[HANDLER]) handlers[HANDLER].postMessage(message);
  }

  // ---------------------------------------------------------------- picker

  // `captured`: the hovered target and the nodes its highlight outlines (see capturedRect()).
  const picker = { active: false, hovered: null, picked: null, overlay: null, captured: null };

  function isScrollable(el) {
    if (el === document.scrollingElement) return false; // that is the frame document itself
    const overflow = getComputedStyle(el).overflowY;
    return (overflow === 'auto' || overflow === 'scroll' || overflow === 'overlay') &&
      el.scrollHeight > el.clientHeight + 1;
  }

  // The page's main content as it marks it. It scrolls with the page, so capture() scrolls the page
  // (see scrollerOf()) and collects only the element. Small ones (article cards in a feed) do not count.
  const MAIN_CONTENT = 'main, article, [role="main"], [role="article"]';
  const MIN_CONTENT_WIDTH = 200;
  const MIN_CONTENT_HEIGHT = 100;

  function isMainContent(el) {
    if (!el.matches(MAIN_CONTENT)) return false;
    const r = el.getBoundingClientRect();
    return r.width >= MIN_CONTENT_WIDTH && r.height >= MIN_CONTENT_HEIGHT &&
      getComputedStyle(el).visibility !== 'hidden';
  }

  // What scrolls `el` with it: its nearest scrollable ancestor, else the document.
  function scrollerOf(el) {
    for (let p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
      if (isScrollable(p)) return p;
    }
    return document.scrollingElement || document.documentElement;
  }

  // The capture target for a node in this frame: the nearest scrollable or main-content ancestor,
  // else this frame's document when this is an iframe, else null (the top document: whole page).
  function targetAt(node) {
    let el = node && node.nodeType === 1 ? node : node && node.parentElement;
    for (; el && el !== document.documentElement; el = el.parentElement) {
      if (el.hasAttribute(UI_ATTR)) continue;
      if (isScrollable(el) || isMainContent(el)) return el;
    }
    return isTop ? null : document;
  }

  // ------------------------------------------------------- page furniture
  //
  // A main-content target often also holds the page's own controls: tool bars, navigation, a search
  // box, a column of settings beside the text (Wikipedia's <main> holds its "Appearance" column).
  // Those are left out of its capture (see snapshot()) and of its highlight (see capturedRect()).

  // Furniture wherever it is in the target, and a <form> that holds nothing but controls.
  const LANDMARKS = 'nav, [role="navigation"], [role="search"], [role="toolbar"], [role="menubar"]';
  const FURNITURE = LANDMARKS + ', form';
  // Furniture only outside the text column: inside it, an <aside> is usually a note in the text.
  const ASIDE = 'aside, [role="complementary"]';
  // Never left out: the title, panels and tabs the collector expanded (marked during a capture).
  const KEEP = 'h1, [data-pc-expanded], [data-pc-tab-title]';
  // Never left out inside the text column: what belongs to the text.
  const KEEP_IN_TEXT = 'figure, table, img, picture';
  const FURNITURE_NOT_TEXT = new Set(['script', 'style', 'noscript', 'template', 'svg', 'button', 'select',
    'option', 'textarea']);
  const CONTROL_TEXT = 'label, button, select, option, textarea, legend';
  // Blocks of text (a title is often beside the column's wrapper, so not <h1>).
  const TEXT_BLOCK = 'p, h2, h3, h4, h5, h6, section, blockquote, pre, ul, ol, dl, table, figure';

  // The visible characters of text in `root` and each element under it.
  function textLengths(root) {
    const lengths = new Map();
    const count = (node) => {
      if (node.nodeType === 3) return node.data.replace(/\s+/g, '').length;
      if (node.nodeType !== 1 || FURNITURE_NOT_TEXT.has(node.localName)) return 0;
      let n = 0;
      for (let c = node.firstChild; c; c = c.nextSibling) n += count(c);
      lengths.set(node, n);
      return n;
    };
    count(root);
    return lengths;
  }

  // A form of controls only: all its text is in labels, buttons and the like.
  function isControlsForm(form) {
    const walker = document.createTreeWalker(form, NodeFilter.SHOW_TEXT);
    for (let t = walker.nextNode(); t; t = walker.nextNode()) {
      if (t.data.trim() && !t.parentElement.closest(CONTROL_TEXT)) return false;
    }
    return form.querySelector('input, select, textarea, button') !== null;
  }

  // Whether `el` holds text blocks itself (not only wrappers around them): the text column, not one
  // of its long sections.
  function holdsText(el) {
    for (let c = el.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 3 ? c.data.trim() !== '' : c.nodeType === 1 && c.matches(TEXT_BLOCK)) return true;
    }
    return false;
  }

  function overlapsHorizontally(a, b) {
    return a.left < b.right - 1 && b.left < a.right - 1;
  }

  // The furniture to leave out of a main-content target, outermost elements only:
  // - FURNITURE anywhere and ASIDE outside the text column (from the target, the child holding more
  //   than half of the text, and so on until one holds text blocks itself), unless it holds KEEP, or
  //   KEEP_IN_TEXT inside the text column;
  // - a side column: an element outside the text column that holds only furniture (and whitespace)
  //   and is laid out beside the text column (their boxes do not overlap horizontally).
  // Nothing when that would take more than half of the target's text.
  function furnitureOf(root) {
    const lengths = textLengths(root);
    const length = (el) => lengths.get(el) || 0;
    const total = length(root);
    let column = root;
    while (!holdsText(column)) {
      const next = Array.from(column.children).find((c) => length(c) > total / 2);
      if (!next) break;
      column = next;
    }
    const inText = (el) => el !== column && column.contains(el);
    const marked = new Set();
    for (const el of root.querySelectorAll(FURNITURE + ', ' + ASIDE)) {
      if (el.contains(column) || el.matches(KEEP) || el.querySelector(KEEP)) continue;
      if (inText(el) && (el.matches(KEEP_IN_TEXT) || el.querySelector(KEEP_IN_TEXT))) continue;
      if (!el.matches(FURNITURE) && inText(el)) continue; // an aside in the text
      if (el.localName === 'form' && !el.matches(LANDMARKS) && !isControlsForm(el)) continue;
      marked.add(el);
    }
    // Side columns, innermost first: a wrapper of a side column may be one too.
    const columnBox = column.getBoundingClientRect();
    const sideColumns = (el) => {
      for (const c of el.children) {
        if (!marked.has(c) && !c.contains(column) && !inText(c)) sideColumns(c);
      }
      if (el === root || marked.has(el) || el.contains(column) || !el.children.length) return;
      if (!Array.from(el.children).every((c) => marked.has(c))) return;
      for (let c = el.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3 && c.data.trim()) return;
      }
      const box = el.getBoundingClientRect();
      if (box.width > 0 && !overlapsHorizontally(box, columnBox)) marked.add(el);
    };
    sideColumns(root);
    const outer = Array.from(marked).filter((el) => {
      for (let p = el.parentElement; p && p !== root; p = p.parentElement) if (marked.has(p)) return false;
      return true;
    });
    const removed = outer.reduce((n, el) => n + length(el), 0);
    return new Set(removed > total / 2 ? [] : outer);
  }

  // Whether `target` is captured as main content (see capture()): it scrolls with the page.
  function isContentTarget(target) {
    return target !== null && target !== document && !isScrollable(target) && target.matches(MAIN_CONTENT);
  }

  // What the highlight outlines for `target`: the element, or for main content the nodes captured
  // once its furniture is left out (computed once per target, see highlight()).
  function capturedNodes(target) {
    const furniture = isContentTarget(target) ? furnitureOf(target) : new Set();
    if (!furniture.size) return [target];
    const around = new Set();
    for (const f of furniture) {
      for (let p = f.parentElement; p && p !== target; p = p.parentElement) around.add(p);
    }
    const out = [];
    const walk = (el) => {
      for (let c = el.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) {
          if (c.data.trim()) out.push(c);
        } else if (c.nodeType === 1 && !furniture.has(c) && !SKIP.has(c.localName) && !c.hasAttribute(UI_ATTR)) {
          if (around.has(c)) walk(c); else out.push(c);
        }
      }
    };
    walk(target);
    return out;
  }

  // The viewport rectangle around `nodes`, or null when none of them shows.
  function boundsOf(nodes) {
    let box = null;
    for (const n of nodes) {
      let r;
      if (n.nodeType === 3) {
        const range = document.createRange();
        range.selectNodeContents(n);
        r = range.getBoundingClientRect();
      } else {
        r = n.getBoundingClientRect();
      }
      if (r.width <= 0 && r.height <= 0) continue;
      box = box
        ? { left: Math.min(box.left, r.left), top: Math.min(box.top, r.top),
            right: Math.max(box.right, r.right), bottom: Math.max(box.bottom, r.bottom) }
        : { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    }
    return box && { left: box.left, top: box.top, width: box.right - box.left, height: box.bottom - box.top };
  }

  function capturedRect(target) {
    if (target === document) return { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
    if (!picker.captured || picker.captured.target !== target) {
      picker.captured = { target, nodes: capturedNodes(target) };
    }
    const nodes = picker.captured.nodes;
    return (nodes.length === 1 && nodes[0] === target ? null : boundsOf(nodes)) || target.getBoundingClientRect();
  }

  function highlight(target) {
    picker.hovered = target;
    if (!target) {
      if (picker.overlay) picker.overlay.style.display = 'none';
      return;
    }
    if (!picker.overlay) {
      const o = document.createElement('div');
      o.setAttribute(UI_ATTR, '');
      o.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;' +
        'border:3px solid #e2796c;background:rgba(242,175,164,0.18);border-radius:3px;margin:0;padding:0;';
      picker.overlay = o;
    }
    if (!picker.overlay.isConnected) document.documentElement.appendChild(picker.overlay);
    const r = capturedRect(target);
    Object.assign(picker.overlay.style, {
      display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px',
    });
  }

  function setPicking(on) {
    picker.active = !!on;
    picker.captured = null;
    if (!picker.active) {
      highlight(null);
      if (picker.overlay) picker.overlay.remove();
    }
  }

  function swallow(e) {
    if (!picker.active) return;
    e.preventDefault();
    e.stopImmediatePropagation();
  }

  window.addEventListener('mousemove', (e) => {
    if (picker.active) highlight(targetAt(e.target));
  }, true);
  window.addEventListener('mouseout', (e) => {
    const to = e.relatedTarget;
    if (picker.active && (!to || to.localName === 'iframe' || to.localName === 'frame')) highlight(null);
  }, true);
  window.addEventListener('scroll', () => {
    if (picker.active && picker.hovered) highlight(picker.hovered);
  }, true);
  // A new layout may put the furniture elsewhere.
  window.addEventListener('resize', () => {
    picker.captured = null;
    if (picker.active && picker.hovered) highlight(picker.hovered);
  });
  for (const type of ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'auxclick', 'contextmenu']) {
    window.addEventListener(type, swallow, true);
  }
  window.addEventListener('click', (e) => {
    if (!picker.active) return;
    swallow(e);
    const target = targetAt(e.target);
    picker.picked = target;
    setPicking(false);
    post({ type: 'picked', kind: target === null ? 'wholePage' : target === document ? 'document' : 'element' });
  }, true);

  // ------------------------------------------------------------- collector

  // `videos`: the video state of the running capture (see newVideoState()); `headings`: its visual
  // headings (see newHeadingState()); `furniture`: what the snapshot leaves out of a main-content
  // target (see furnitureOf()).
  const collector = { stopRequested: false, wake: null, videos: null, headings: null, furniture: null };

  function stop() {
    collector.stopRequested = true;
    if (collector.wake) collector.wake();
  }

  // Sleeps for `ms`, returning early when a stop is requested.
  function pause(ms) {
    return new Promise((resolve) => {
      if (collector.stopRequested) return resolve();
      const done = () => { clearTimeout(timer); collector.wake = null; resolve(); };
      const timer = setTimeout(done, ms);
      collector.wake = done;
    });
  }

  function absolute(value) {
    const v = value.trim();
    if (!v || /^(javascript|data|blob|about|mailto|tel):/i.test(v)) return value;
    try { return new URL(v, document.baseURI).href; } catch (e) { return value; }
  }

  function absoluteSrcset(value) {
    return value.split(',').map((candidate) => {
      const parts = candidate.trim().split(/\s+/);
      if (!parts[0]) return '';
      parts[0] = absolute(parts[0]);
      return parts.join(' ');
    }).filter(Boolean).join(', ');
  }

  const URL_ATTRS = new Set(['href', 'src', 'poster', 'action', 'cite', 'background', 'xlink:href']);
  const SKIP = new Set(['script', 'noscript', 'template']);
  const SCRIPT_URL_ATTRS = new Set([...URL_ATTRS, 'formaction']);

  // URL parsing strips tabs and newlines anywhere and leading controls and spaces before the scheme.
  function isJavaScriptURL(value) {
    return /^javascript:/i.test(value.replace(/[\t\n\r]/g, '').replace(/^[\u0000-\u0020]+/, ''));
  }

  // Inline declarations that hide or collapse an element.
  function unhideStyle(style) {
    return style.split(';').filter((part) => {
      const i = part.indexOf(':');
      if (i < 0) return part.trim() !== '';
      const name = part.slice(0, i).trim().toLowerCase();
      const value = part.slice(i + 1).trim().toLowerCase();
      if (name === 'display') return !/^none\b/.test(value);
      if (name === 'visibility') return !/^(hidden|collapse)\b/.test(value);
      if (name === 'height' || name === 'max-height') return parseFloat(value) !== 0;
      if (name === 'overflow' || name === 'overflow-y') return !/^(hidden|clip)\b/.test(value);
      if (name === 'opacity') return parseFloat(value) !== 0;
      return true;
    }).join(';');
  }

  // Elements without a box of their own that the exports still need: style rules, media sources,
  // image-map areas. SVG content is kept too (a hidden sprite sheet holds the icons <use> shows).
  const BOXLESS_KEPT = new Set(['style', 'link', 'meta', 'source', 'track', 'area', 'param']);
  // Media whose children (sources, tracks, fallback) are kept whatever their display.
  const MEDIA_TAGS = new Set(['picture', 'video', 'audio']);
  const SVG_NS = 'http://www.w3.org/2000/svg';

  // An element the page hides with display:none (a closed dropdown, a menu) is left out: the
  // Markdown is written without the page's styles and could not tell it was hidden. Not inside
  // `keepHidden` (a panel seen expanded, a tab panel or media: the collector shows those itself).
  // Left out of a later snapshot only, an element keeps what was collected (see Merge.merge()).
  function isHidden(el, tag, keepHidden) {
    if (keepHidden || BOXLESS_KEPT.has(tag) || el.namespaceURI === SVG_NS) return false;
    return getComputedStyle(el).display === 'none';
  }

  function snapshot(node, idOf, keepHidden) {
    if (node.nodeType === 3) return { id: idOf(node), text: node.data };
    if (node.nodeType !== 1) return null;
    const tag = node.localName;
    if (SKIP.has(tag) || node.hasAttribute(UI_ATTR)) return null;
    if (collector.furniture && collector.furniture.has(node)) return null;
    // A video (or its player) found during this capture: placeVideos() turns this into its figure.
    const videoKey = collector.videos && collector.videos.keys.get(node);
    if (videoKey) return { id: idOf(node), tag: VIDEO_TAG, attrs: [['key', videoKey]], children: [] };
    // A panel seen expanded during this capture is written out expanded, with EXPANDED saying whether
    // the page shows it now ("shown") or has collapsed it again ("hidden", the PDF forces it visible).
    const expanded = node.hasAttribute(EXPANDED);
    keepHidden = keepHidden || expanded || node.hasAttribute(TAB_TITLE);
    if (isHidden(node, tag, keepHidden)) return null;
    const keepChildrenHidden = keepHidden || MEDIA_TAGS.has(tag);
    const collapsed = expanded && (tag === 'details' ? !node.open : !isShown(node));
    const attrs = [];
    for (const a of node.attributes) {
      // The snapshot is rendered again off-screen: drop anything that would run script there.
      if (/^on/i.test(a.name)) continue;
      let v = a.value;
      if (SCRIPT_URL_ATTRS.has(a.name) && isJavaScriptURL(v)) continue;
      if (expanded) {
        if (a.name === 'hidden') continue;
        // An exclusive group would close all but one of the open <details> where it is rendered again.
        if (tag === 'details' && a.name === 'name') continue;
        if (a.name === 'style') v = unhideStyle(v);
        else if (a.name === EXPANDED) v = collapsed ? 'hidden' : 'shown';
      }
      if (a.name === 'srcset') v = absoluteSrcset(v);
      else if (URL_ATTRS.has(a.name)) v = absolute(v);
      attrs.push([a.name, v]);
    }
    if (expanded && tag === 'details' && !node.open) attrs.push(['open', '']);
    // Only the snapshot says an element looks like a heading; the page is left as it is.
    const level = collector.headings ? visualHeadingLevel(node, collector.headings) : 0;
    if (level) attrs.push([HEADING_MARK, String(level)]);
    // A child frame may hold videos of its own: name it, so it can report them (see frameVideos()).
    if ((tag === 'iframe' || tag === 'frame') && collector.videos && !embedKind(node)) {
      attrs.push([FRAME_ATTR, frameToken(node, collector.videos)]);
    }
    if (tag === 'img' && node.currentSrc) {
      const src = attrs.find(([k]) => k === 'src');
      if (src) src[1] = node.currentSrc; else attrs.push(['src', node.currentSrc]);
    }
    const children = [];
    for (let c = node.firstChild; c; c = c.nextSibling) {
      const s = snapshot(c, idOf, keepChildrenHidden);
      if (s) children.push(s);
    }
    const snap = { id: idOf(node), tag, attrs, children };
    // A collapsed panel may have dropped its content: the merge keeps what was seen while it was open.
    if (collapsed && tag !== 'details') snap.keepChildren = true;
    return snap;
  }

  // ------------------------------------------------- expanding collapsed content

  // Marks a panel seen expanded; see snapshot().
  const EXPANDED = 'data-pc-expanded';
  const MAX_EXPAND_ROUNDS = 3;
  const NOT_TRIGGER_TAGS = new Set(['input', 'select', 'textarea', 'option']);
  const NOT_TRIGGER_ROLES = new Set(['combobox', 'menuitem', 'menuitemcheckbox', 'menuitemradio']);

  function isShown(el) {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
  }

  // Disclosure triggers that are safe to click: not links that navigate, popups (menus, dialogs,
  // listboxes), form submits or form fields. Without aria-controls only accordion-style controls.
  function isTrigger(el) {
    const tag = el.localName;
    if (NOT_TRIGGER_TAGS.has(tag) || NOT_TRIGGER_ROLES.has(el.getAttribute('role'))) return false;
    if (el.closest('[' + UI_ATTR + ']')) return false;
    const popup = el.getAttribute('aria-haspopup');
    if (popup !== null && popup !== 'false') return false;
    if (tag === 'a' && el.hasAttribute('href') && !el.getAttribute('href').trim().startsWith('#')) return false;
    if (tag === 'button' && el.form && el.type === 'submit') return false;
    if (tag === 'summary') return false; // its <details> is opened directly
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return false;
    return el.hasAttribute('aria-controls') || tag === 'button' || el.getAttribute('role') === 'button';
  }

  // The panels a trigger opens: those named by aria-controls, else the element after the trigger or
  // after its heading/wrapper (a guess, confirmed in observe()).
  function panelsOf(trigger, root) {
    const ids = (trigger.getAttribute('aria-controls') || '').split(/\s+/).filter(Boolean);
    if (ids.length) {
      const panels = ids.map((id) => document.getElementById(id)).filter((p) => p && root.contains(p));
      return { trigger, controlled: true, panels };
    }
    let el = trigger;
    for (let depth = 0; depth < 3 && el && el !== root; depth++, el = el.parentElement) {
      if (el.nextElementSibling) return { trigger, controlled: false, panels: [el.nextElementSibling] };
    }
    return { trigger, controlled: false, panels: [] };
  }

  // Marks panels seen expanded, so they stay in the capture when an exclusive accordion closes them.
  // A panel named by aria-controls counts once its trigger says expanded while it shows; a guessed
  // panel only once it has been seen to show and hide along with its trigger.
  function observe(root, entries, state) {
    for (const e of entries) {
      const open = e.trigger.getAttribute('aria-expanded') === 'true';
      // Already open: clicking it later (after an exclusive accordion closed it) would only toggle.
      if (open) state.clicked.add(e.trigger);
      for (const p of e.panels) {
        if (p.hasAttribute(EXPANDED)) continue;
        const shown = isShown(p);
        if (e.controlled) {
          if (open && shown) p.setAttribute(EXPANDED, '');
          continue;
        }
        if (open !== shown) continue;
        const seen = state.seen.get(p) || { open: false, closed: false };
        seen[open ? 'open' : 'closed'] = true;
        state.seen.set(p, seen);
        if (seen.open && seen.closed) p.setAttribute(EXPANDED, '');
      }
    }
    for (const d of root.querySelectorAll('details[open]')) d.setAttribute(EXPANDED, '');
  }

  // Opens collapsed content in the target: closed <details>, and triggers with aria-expanded="false"
  // (each clicked at most once per capture and never once seen open, at most `maxExpandClicks` per pass). Snapshots after each
  // click, as opening one panel of an exclusive accordion may remove another's content. Then shows
  // each tab panel in turn (see activateTabs()). Keeps the scroll position. Returns the number of clicks.
  async function expand(root, scroller, take, state, o) {
    const top = scroller.scrollTop;
    let clicks = 0;
    for (let round = 0; round < MAX_EXPAND_ROUNDS; round++) {
      if (collector.stopRequested || clicks >= o.maxExpandClicks) break;
      const closed = Array.from(root.querySelectorAll('details:not([open])'))
        .filter((d) => !d.closest('[' + UI_ATTR + ']'));
      const entries = Array.from(root.querySelectorAll('[aria-expanded]')).filter(isTrigger)
        .map((t) => panelsOf(t, root));
      observe(root, entries, state);
      const todo = entries.filter((e) => e.trigger.getAttribute('aria-expanded') === 'false' &&
        !state.clicked.has(e.trigger));
      if (!closed.length && !todo.length) break;
      take();
      for (const d of closed) {
        d.open = true;
        d.setAttribute(EXPANDED, '');
      }
      for (const e of todo) {
        if (collector.stopRequested || clicks >= o.maxExpandClicks) break;
        if (!e.trigger.isConnected || e.trigger.getAttribute('aria-expanded') !== 'false') continue;
        state.clicked.add(e.trigger);
        e.trigger.click();
        clicks++;
        await pause(o.expandDelay);
        observe(root, entries, state);
        take();
      }
      await pause(o.settleDelay);
      observe(root, entries, state);
    }
    if (!collector.stopRequested) clicks += await activateTabs(root, take, state, o, o.maxExpandClicks - clicks);
    scrollTo(scroller, top);
    return clicks;
  }

  // --------------------------------------------------------- visual headings
  //
  // A sub-heading the page styles itself (a bold, larger <p>, <div> or <span>) rather than marking up
  // as h1-h6 is marked HEADING_MARK in the snapshot, with the level it reads as, so the Markdown
  // writes it as a heading.

  const HEADING_MARK = 'data-pc-heading';
  // At most this many characters, on at most MAX_HEADING_LINES lines, make a heading.
  const MAX_HEADING_TEXT = 120;
  const MAX_HEADING_LINES = 2;
  // A heading's text is this much larger than the body text, or bold and HEADING_BOLD_SIZE larger.
  const HEADING_SIZE = 1.15;
  const HEADING_BOLD_SIZE = 1.05;
  const HEADING_BOLD_WEIGHT = 600;
  // Two sizes this close (relative) are the same heading style.
  const SAME_SIZE = 0.05;
  const BLOCK_DISPLAY = /^(block|flex|grid|flow-root|table-cell|table-caption)\b/;
  // Never headings: real headings, list items, buttons, tab and accordion headers, tab bars, the
  // page's navigation and the app's own UI, nor what is inside or around them.
  const NOT_HEADING = 'h1, h2, h3, h4, h5, h6, li, button, summary, nav, [role="button"], [role="tab"], ' +
    '[role="tablist"], [aria-expanded], [data-pc-tabs], [' + UI_ATTR + ']';
  const NOT_TEXT = new Set(['script', 'style', 'noscript', 'template']);

  // Per capture: the target, the size of its body text and of each real heading level (measured on
  // first use), and each element's level (0: not a heading).
  function newHeadingState(root) {
    return { root, bodySize: null, levelSizes: null, levels: new WeakMap() };
  }

  function fontSizeOf(el) {
    return parseFloat(getComputedStyle(el).fontSize) || 0;
  }

  // The text nodes in `el` with visible characters, or null once they hold more than `limit`.
  function textNodesOf(el, limit) {
    const out = [];
    let length = 0;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!n.parentElement || NOT_TEXT.has(n.parentElement.localName)) continue;
      const chars = n.data.replace(/\s+/g, '').length;
      if (!chars) continue;
      length += chars;
      if (length > limit) return null;
      out.push(n);
    }
    return out;
  }

  // The font size most of the target's text (outside headings) is set in.
  function bodyFontSize(root) {
    const chars = new Map();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let counted = 0;
    for (let n = walker.nextNode(); n && counted < 5000; n = walker.nextNode()) {
      const parent = n.parentElement;
      const length = n.data.replace(/\s+/g, '').length;
      if (!length || !parent || NOT_TEXT.has(parent.localName) || parent.closest(HEADINGS)) continue;
      counted++;
      const size = fontSizeOf(parent);
      chars.set(size, (chars.get(size) || 0) + length);
    }
    let best = 0, most = 0;
    for (const [size, n] of chars) if (n > most) { best = size; most = n; }
    return best || fontSizeOf(root);
  }

  // [[level, size]] of the real heading levels shown on the page.
  function headingLevelSizes() {
    const sizes = [];
    for (let level = 1; level <= 6; level++) {
      const h = Array.from(document.querySelectorAll('h' + level)).find(isShown);
      if (h) sizes.push([level, fontSizeOf(h)]);
    }
    return sizes;
  }

  // The number of lines the text nodes take on the page (0 when they are not laid out).
  function lineCount(texts, size) {
    const tops = [];
    const range = document.createRange();
    for (const t of texts) {
      range.selectNodeContents(t);
      for (const r of range.getClientRects()) if (r.width > 0) tops.push(r.top);
    }
    tops.sort((a, b) => a - b);
    let lines = 0;
    for (let i = 0; i < tops.length; i++) if (i === 0 || tops[i] - tops[i - 1] > size / 2) lines++;
    return lines;
  }

  // A cell of a table with header cells (a data table) that shares its row with other cells.
  function inDataCell(el) {
    const cell = el.closest('td, th');
    if (!cell) return false;
    const row = cell.parentElement;
    const cells = row ? Array.from(row.children).filter((c) => c.localName === 'td' || c.localName === 'th') : [];
    const table = cell.closest('table');
    return cells.length > 1 && table !== null && table.querySelector('th') !== null;
  }

  // The level a heading of font size `size` reads as: that of a real heading level of the same size,
  // else one below the smallest real heading larger than it, else the top real level shown. Without
  // real headings shown, one below the heading before it.
  function levelForSize(el, size, state) {
    if (!state.levelSizes) state.levelSizes = headingLevelSizes();
    const sizes = state.levelSizes;
    if (sizes.length) {
      const nearest = sizes.slice().sort((a, b) => Math.abs(a[1] - size) - Math.abs(b[1] - size))[0];
      if (Math.abs(nearest[1] - size) <= nearest[1] * SAME_SIZE) return nearest[0];
      const larger = sizes.filter(([, s]) => s > size);
      return larger.length ? larger[larger.length - 1][0] + 1 : sizes[0][0];
    }
    let before = 1;
    for (const h of document.querySelectorAll(HEADINGS)) {
      if (!(h.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
      before = +h.localName[1];
    }
    return before + 1;
  }

  // The heading level `el` reads as on the page, or 0: a short block (one or two lines) that is not a
  // real heading, holds no other block with text, and whose text is all larger than the body text,
  // or bold and slightly larger.
  // Judged once per element, once it has text (lazy content may fill it later).
  function visualHeadingLevel(el, state) {
    let level = state.levels.get(el);
    if (level !== undefined) return level;
    if (el === state.root || el.closest('a, ' + NOT_HEADING)) level = 0;
    else {
      const texts = textNodesOf(el, MAX_HEADING_TEXT);
      if (texts && !texts.length) return 0;
      level = texts ? judgeHeading(el, texts, state) : 0;
    }
    state.levels.set(el, level);
    return level;
  }

  function judgeHeading(el, texts, state) {
    if (el.querySelector('img, svg, picture, video, iframe, input, select, textarea, ' + NOT_HEADING)) return 0;
    // A block of links only (a menu entry, a "read more").
    if (texts.every((t) => t.parentElement.closest('a'))) return 0;
    const style = getComputedStyle(el);
    if (!BLOCK_DISPLAY.test(style.display) || inDataCell(el)) return 0;
    for (const t of texts) {
      for (let p = t.parentElement; p && p !== el; p = p.parentElement) {
        if (!getComputedStyle(p).display.startsWith('inline')) return 0;
      }
    }
    if (state.bodySize === null) state.bodySize = bodyFontSize(state.root);
    const body = state.bodySize;
    if (!(body > 0)) return 0;
    for (const t of texts) {
      const s = getComputedStyle(t.parentElement);
      const size = parseFloat(s.fontSize) || 0;
      const bold = (parseInt(s.fontWeight, 10) || 400) >= HEADING_BOLD_WEIGHT;
      if (!(size >= body * HEADING_SIZE || (bold && size >= body * HEADING_BOLD_SIZE))) return 0;
    }
    const size = Math.max(...texts.map((t) => fontSizeOf(t.parentElement)));
    if (lineCount(texts, size) > MAX_HEADING_LINES) return 0;
    return levelForSize(el, size, state);
  }

  // ------------------------------------------------------------------- tabs
  //
  // Each tab panel is marked with its tab's title (TAB_TITLE) and each tab bar with TAB_BAR, so the
  // exports can show every panel under its title without the bar. markdown.js pairs tabs and panels
  // the same way for HTML that does not carry these marks.

  const TAB_TITLE = 'data-pc-tab-title';
  const TAB_BAR = 'data-pc-tabs';
  const TABS = '[role="tab"], a[href^="#"], [data-toggle="tab"], [data-toggle="pill"], ' +
    '[data-bs-toggle="tab"], [data-bs-toggle="pill"]';
  const SELECTED_CLASS = /^(active|is-active|selected|is-selected|current)$/i;

  // A class naming a tab list ("nav-tabs", "tabs", "tab-list", "c-tabs__nav"), not its panels or items.
  function hasTabListClass(el) {
    return (el.getAttribute('class') || '').split(/\s+/).some((t) =>
      /^([\w-]*[-_])?(tabs|tab-?list|tab-?bar|tab-?nav)([-_][\w-]*)?$/i.test(t) &&
      !/content|pane|panel|title|item|link/i.test(t));
  }

  // The tab list holding `tab`: a role=tablist or tab-list-class ancestor close by, else null.
  function tabListOf(tab, root) {
    let el = tab.parentElement;
    for (let depth = 0; el && el !== root && depth < 4; depth++, el = el.parentElement) {
      if (el.getAttribute('role') === 'tablist' || hasTabListClass(el)) return el;
    }
    return null;
  }

  // The panel a tab shows: named by aria-controls, by an `#id` href or data-(bs-)target, or labelled by it.
  function panelOfTab(tab, root) {
    const byId = (id) => {
      const p = id ? document.getElementById(id) : null;
      return p && root.contains(p) && !p.contains(tab) ? p : null;
    };
    let panel = byId((tab.getAttribute('aria-controls') || '').trim().split(/\s+/)[0]);
    for (const name of ['href', 'data-target', 'data-bs-target']) {
      const v = (tab.getAttribute(name) || '').trim();
      if (!panel && v.length > 1 && v[0] === '#') panel = byId(v.slice(1));
    }
    if (!panel && tab.id) {
      panel = Array.from(root.querySelectorAll('[aria-labelledby]')).find((p) => !p.contains(tab) &&
        p.getAttribute('aria-labelledby').split(/\s+/).includes(tab.id)) || null;
    }
    return panel;
  }

  // The tab widgets in `root`: [{ list, tabs: [{ tab, panel, title, strong }] }]. A role=tab or a
  // data-toggle="tab" control is a tab wherever it is; a plain `#id` link only in a tab list, and
  // its list only counts with two links paired to panels. Tabs with aria-expanded are accordion
  // headers (see expand()).
  function tabGroups(root) {
    const groups = new Map();
    for (const tab of root.querySelectorAll(TABS)) {
      if (tab.hasAttribute('aria-expanded') || tab.closest('[' + UI_ATTR + ']')) continue;
      const toggle = tab.getAttribute('data-toggle') || tab.getAttribute('data-bs-toggle') || '';
      const strong = tab.getAttribute('role') === 'tab' || /^(tab|pill)$/.test(toggle);
      let list = tabListOf(tab, root);
      if (!list && !strong) continue;
      if (!list) list = tab.parentElement.localName === 'li' ? tab.parentElement.parentElement : tab.parentElement;
      if (!groups.has(list)) groups.set(list, { list, tabs: [] });
      const title = textOf(tab) || (tab.getAttribute('aria-label') || '').trim();
      groups.get(list).tabs.push({ tab, panel: panelOfTab(tab, root), title, strong });
    }
    return Array.from(groups.values()).filter((g) => {
      const paired = g.tabs.filter((t) => t.panel).length;
      return paired >= (g.tabs.some((t) => t.strong) ? 1 : 2);
    });
  }

  function isSelectedTab(tab) {
    const selected = tab.getAttribute('aria-selected');
    if (selected !== null) return selected === 'true';
    const li = tab.parentElement && tab.parentElement.localName === 'li' ? tab.parentElement : null;
    return [tab, li].some((el) => el && Array.from(el.classList).some((c) => SELECTED_CLASS.test(c)));
  }

  // Tabs that are safe to click: not links that navigate, popups, form submits or disabled controls.
  function isSafeTab(tab) {
    const link = tab.closest('a[href]');
    if (link && !link.getAttribute('href').trim().startsWith('#')) return false;
    const popup = tab.getAttribute('aria-haspopup');
    if (popup !== null && popup !== 'false') return false;
    if (tab.localName === 'button' && tab.form && tab.type === 'submit') return false;
    return !(tab.disabled || tab.getAttribute('aria-disabled') === 'true');
  }

  // Marks every tab panel with its title and each tab bar (the list, or its tabs when the list also
  // holds panels), and marks the panels showing now as seen expanded. Returns the tab widgets.
  function markTabs(root) {
    const groups = tabGroups(root);
    for (const g of groups) {
      const paired = g.tabs.filter((t) => t.panel);
      const bars = paired.some((t) => g.list.contains(t.panel)) ? g.tabs.map((t) => t.tab) : [g.list];
      for (const bar of bars) bar.setAttribute(TAB_BAR, '');
      for (const t of paired) {
        if (t.title) t.panel.setAttribute(TAB_TITLE, t.title);
        if (!t.panel.hasAttribute(EXPANDED) && isShown(t.panel)) t.panel.setAttribute(EXPANDED, '');
      }
    }
    return groups;
  }

  // Selects each unselected tab in the target once per capture (at most `budget` clicks), snapshotting
  // after each, as a panel may only get its content when shown; then selects the tab that was
  // selected before again. Returns the number of clicks.
  async function activateTabs(root, take, state, o, budget) {
    let clicks = 0;
    for (const g of markTabs(root)) {
      const original = g.tabs.find((t) => isSelectedTab(t.tab)) || g.tabs.find((t) => t.panel && isShown(t.panel));
      const todo = g.tabs.filter((t) => t !== original && !isSelectedTab(t.tab) && !state.clickedTabs.has(t.tab) &&
        (t.panel || t.strong) && isSafeTab(t.tab));
      if (!todo.length) continue;
      take();
      let clicked = false;
      for (const t of todo) {
        if (collector.stopRequested || clicks >= budget) break;
        if (!t.tab.isConnected) continue;
        state.clickedTabs.add(t.tab);
        t.tab.click();
        clicks++;
        clicked = true;
        await pause(o.expandDelay);
        markTabs(root);
        take();
      }
      if (clicked && original && original.tab.isConnected) {
        original.tab.click();
        await pause(o.expandDelay);
        markTabs(root);
        take();
      }
    }
    return clicks;
  }

  // ------------------------------------------------------------------ videos
  //
  // Each video in the target is recorded, and the element standing for it (the <video>, the player
  // container whose play button was clicked, or the YouTube/Vimeo <iframe>) is snapshotted as a
  // placeholder that placeVideos() turns into a figure. A video inside a child frame (often a
  // cross-origin player) is found by that frame's own copy of this script: the parent names each
  // child frame with a token sent by postMessage, the child reports the token to the app, and at the
  // end of the capture the app runs frameVideos() in the child frames the capture holds.

  const ASK_HANDLER = 'pageCaptureAsk';
  const VIDEO_TAG = 'pc-video';
  const FRAME_ATTR = 'data-pc-frame';
  const TOKEN_PREFIX = 'pageCapture:frameToken:';
  const MANIFEST = /\.(m3u8|mpd)$/i;
  const MEDIA_FILE = /\.(mp4|webm|mov|m4v)$/i;
  const HLS_TYPE = /^\s*application\/(vnd\.apple\.mpegurl|x-mpegurl)/i;
  const DASH_TYPE = /^\s*application\/dash\+xml/i;
  const FILE_TYPE = /^\s*video\/(mp4|webm|quicktime|x-m4v)/i;
  // Explicit big-play classes, plus buttons whose accessible name starts with the word "Play"
  // (see isPlayButton()): not "Display settings", "Playback speed", "Autoplay" or "Add to playlist".
  const PLAY_CLASS = '.vjs-big-play-button, [class*="big-play"], [class*="play-button"]';
  const PLAY_BUTTON = PLAY_CLASS + ', button, [role="button"]';
  const PLAY_NAME = /^\s*play\b/i;
  const PLAYER = '.video-js, [class*="player" i], [id*="player" i], [data-player]';
  const HEADINGS = 'h1, h2, h3, h4, h5, h6';

  // keys: element standing for a video → key; records: key → video; seen: elements looked at;
  // clicked: players whose play button was clicked; clickedPosters: those that then showed a video,
  // with their poster from before the click; claimed: URLs taken by a video; frames: token → frame.
  function newVideoState() {
    return { keys: new WeakMap(), records: new Map(), seen: new WeakSet(), clicked: new WeakSet(),
      clickedPosters: new WeakMap(), claimed: new Set(), frames: new Map(), next: 0,
      mediaSeen: new WeakSet(), wasPlaying: new WeakSet() };
  }

  function mediaIn(root) {
    return Array.from(root.querySelectorAll('video, audio'));
  }

  // Remembers which media in `root` are already playing, once per element, before the capture touches any.
  function noteMedia(root, state) {
    for (const m of mediaIn(root)) {
      if (state.mediaSeen.has(m)) continue;
      state.mediaSeen.add(m);
      if (!m.paused) state.wasPlaying.add(m);
    }
  }

  // Mutes every medium in `container`, remembering its muted state in `saved` the first time.
  function silence(container, saved) {
    for (const m of mediaIn(container)) {
      if (!saved.has(m)) saved.set(m, m.muted);
      m.muted = true;
    }
  }

  // Pauses, rewinds and unmutes (to the saved state) the media in `container` the capture started.
  function quieten(container, saved, state) {
    for (const m of mediaIn(container)) {
      const was = saved.has(m) ? saved.get(m) : m.muted;
      if (!state.wasPlaying.has(m)) {
        try { m.pause(); } catch (e) { /* ignore */ }
        try { m.currentTime = 0; } catch (e) { /* ignore */ }
      }
      m.muted = was;
    }
  }

  // 'youtube' or 'vimeo' for an embedded player iframe, else null.
  function embedKind(iframe) {
    let u;
    try { u = new URL(iframe.src); } catch (e) { return null; }
    const host = u.hostname.toLowerCase();
    if (/(^|\.)youtube-nocookie\.com$/.test(host)) return 'youtube';
    if (/(^|\.)youtube\.com$/.test(host) && u.pathname.startsWith('/embed/')) return 'youtube';
    if (host === 'player.vimeo.com' && u.pathname.startsWith('/video/')) return 'vimeo';
    return null;
  }

  function pathOf(url) {
    try { return new URL(url).pathname; } catch (e) { return ''; }
  }

  function isMediaResource(url) {
    const path = pathOf(url);
    return MANIFEST.test(path) || MEDIA_FILE.test(path);
  }

  // Manifests and media files this document has loaded (resource timing), as { url, start }. The
  // observer keeps entries that a full resource timing buffer would drop.
  const observedMedia = [];
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        if (isMediaResource(e.name)) observedMedia.push({ url: e.name, start: e.startTime });
      }
    }).observe({ type: 'resource', buffered: true });
  } catch (e) { /* no resource timing */ }

  function mediaResources() {
    const out = observedMedia.slice();
    const known = new Set(out.map((r) => r.url + ' ' + r.start));
    for (const e of performance.getEntriesByType('resource')) {
      if (isMediaResource(e.name) && !known.has(e.name + ' ' + e.startTime)) out.push({ url: e.name, start: e.startTime });
    }
    return out.sort((a, b) => a.start - b.start);
  }

  // A manifest (else a media file) loaded since `since` that no other video has claimed.
  function loadedSince(since, state) {
    const recent = mediaResources().filter((r) => r.start >= since && !state.claimed.has(r.url));
    const hit = recent.find((r) => MANIFEST.test(pathOf(r.url))) || recent.find((r) => MEDIA_FILE.test(pathOf(r.url)));
    return hit ? { url: hit.url, type: '' } : null;
  }

  // The one manifest this document loaded that no video has claimed, if there is exactly one.
  function soleManifest(state) {
    const urls = new Set(mediaResources().map((r) => r.url)
      .filter((u) => MANIFEST.test(pathOf(u)) && !state.claimed.has(u)));
    return urls.size === 1 ? { url: urls.values().next().value, type: '' } : null;
  }

  // Videos with media keys, or that fired an encrypted event, are DRM-protected.
  const encrypted = new WeakSet();
  for (const type of ['encrypted', 'webkitneedkey']) {
    window.addEventListener(type, (e) => { if (e.target && e.target.nodeType === 1) encrypted.add(e.target); }, true);
  }
  function isProtected(video) {
    try { if (video.mediaKeys) return true; } catch (e) { /* not supported */ }
    try { if (video.webkitKeys) return true; } catch (e) { /* not supported */ }
    return encrypted.has(video);
  }

  function usable(url) {
    return !!url && !/^(blob|data|about|javascript):/i.test(url.trim());
  }

  // The video's own source as { url, type }: currentSrc, else its src attribute, else a <source>.
  // A blob: (MSE) source does not count.
  function ownSource(video) {
    const sources = Array.from(video.querySelectorAll('source')).filter((s) => s.getAttribute('src'))
      .map((s) => ({ url: absolute(s.getAttribute('src')), type: s.type || '' }));
    if (usable(video.currentSrc)) {
      const match = sources.find((s) => s.url === video.currentSrc);
      return { url: video.currentSrc, type: match ? match.type : '' };
    }
    const src = video.getAttribute('src');
    if (src && usable(absolute(src))) return { url: absolute(src), type: '' };
    return sources.find((s) => usable(s.url)) || null;
  }

  function classify(source) {
    const path = pathOf(source.url).toLowerCase();
    if (/\.m3u8$/.test(path) || HLS_TYPE.test(source.type)) return 'hls';
    if (/\.mpd$/.test(path) || DASH_TYPE.test(source.type)) return 'dash';
    if (MEDIA_FILE.test(path) || FILE_TYPE.test(source.type)) return 'file';
    return 'unknown';
  }

  // Plays the muted video until it shows a source or this document loads a manifest or media file,
  // at most `timeout` ms; then pauses it, rewinds it and restores its muted state.
  async function reveal(video, timeout, state) {
    const since = performance.now();
    const wasMuted = video.muted;
    video.muted = true;
    let found = null;
    try {
      try {
        const played = video.play();
        if (played && played.catch) played.catch(() => {});
      } catch (e) { /* cannot play */ }
      const deadline = since + timeout;
      for (;;) {
        found = ownSource(video) || loadedSince(since, state);
        if (found || collector.stopRequested || performance.now() >= deadline) break;
        await pause(100);
      }
    } finally {
      try { video.pause(); } catch (e) { /* ignore */ }
      try { video.currentTime = 0; } catch (e) { /* ignore */ }
      video.muted = wasMuted;
    }
    return found;
  }

  function textOf(el) {
    const t = el ? el.textContent.replace(/\s+/g, ' ').trim() : '';
    return t || null;
  }

  // The heading nearest before `el` in the document.
  function headingBefore(el) {
    for (let n = el; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
      for (let s = n.previousElementSibling; s; s = s.previousElementSibling) {
        if (/^h[1-6]$/.test(s.localName)) return textOf(s);
        const inner = s.querySelectorAll(HEADINGS);
        if (inner.length) return textOf(inner[inner.length - 1]);
      }
    }
    return null;
  }

  // The video's title or aria-label, else its figure's caption, else the nearest heading before it.
  // A player container's aria-label names the player ("Video Player"), so only its title counts.
  function titleOf(el, video) {
    const own = (n, aria) => {
      if (!n) return null;
      return (n.getAttribute('title') || '').trim() || (aria && (n.getAttribute('aria-label') || '').trim()) || null;
    };
    const t = own(video, true) || own(el, el === video || el.localName === 'iframe');
    if (t) return t;
    const figure = el.closest('figure');
    return (figure && textOf(figure.querySelector('figcaption'))) || headingBefore(el);
  }

  function backgroundURL(el) {
    const m = /url\(\s*(['"]?)(.*?)\1\s*\)/.exec(getComputedStyle(el).backgroundImage || '');
    return m ? absolute(m[2]) : null;
  }

  // The video's poster attribute, else the player's poster image.
  function posterOf(player, video) {
    const attr = video && video.getAttribute('poster');
    if (attr && attr.trim()) return absolute(attr);
    if (!player || player === video) return null;
    const img = player.querySelector('[class*="poster" i] img, img[class*="poster" i]') || player.querySelector('img');
    if (img && (img.currentSrc || img.getAttribute('src'))) return img.currentSrc || absolute(img.getAttribute('src'));
    const poster = player.querySelector('[class*="poster" i]');
    return poster ? backgroundURL(poster) : null;
  }

  function holdsVideo(el) {
    return !!el.querySelector('video') || Array.from(el.querySelectorAll('iframe')).some(embedKind);
  }

  function isPlayButton(el) {
    if (el.hasAttribute('aria-pressed')) return false;
    if (el.matches(PLAY_CLASS)) return true;
    const name = el.getAttribute('aria-label') || el.getAttribute('title') || el.textContent || '';
    return PLAY_NAME.test(name.replace(/\s+/g, ' '));
  }

  // Play buttons that are safe to click: not links that navigate, form submits or popups.
  function safeToClick(el) {
    if (el.closest('[' + UI_ATTR + ']')) return false;
    const link = el.closest('a[href]');
    if (link && !link.getAttribute('href').trim().startsWith('#')) return false;
    const button = el.closest('button');
    if (button && button.form && button.type === 'submit') return false;
    const popup = el.getAttribute('aria-haspopup');
    if (popup !== null && popup !== 'false') return false;
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return false;
    return isShown(el);
  }

  // Clicks the big play button of each player in `root` that holds no video yet (once per player)
  // and waits for its video to appear, at most `timeout` ms. The player then stands for its video.
  async function clickToLoad(root, state, timeout) {
    for (const button of root.querySelectorAll(PLAY_BUTTON)) {
      if (collector.stopRequested) return;
      if (!isPlayButton(button)) continue;
      const player = button.parentElement && button.parentElement.closest(PLAYER);
      if (!player || player === root || !root.contains(player) || state.clicked.has(player)) continue;
      if (holdsVideo(player) || !safeToClick(button)) continue;
      state.clicked.add(player);
      const poster = posterOf(player, null);
      const saved = new Map();
      silence(player, saved);
      try {
        button.click();
        silence(player, saved);
        const deadline = performance.now() + timeout;
        while (player.isConnected && !holdsVideo(player) && !collector.stopRequested && performance.now() < deadline) {
          await pause(100);
          silence(player, saved);
        }
      } finally {
        quieten(player, saved, state);
      }
      if (player.isConnected && holdsVideo(player)) state.clickedPosters.set(player, poster);
    }
  }

  function clickedPlayerOf(el, state, root) {
    for (let n = el.parentElement; n && n !== root; n = n.parentElement) {
      if (state.clickedPosters.has(n)) return n;
    }
    return null;
  }

  // Whether `el` is inside an element already standing for a video.
  function isInside(el, state, root) {
    for (let n = el.parentElement; n && n !== root; n = n.parentElement) {
      if (state.keys.has(n)) return true;
    }
    return false;
  }

  function record(state, el, video) {
    const key = String(++state.next);
    state.keys.set(el, key);
    state.records.set(key, Object.assign({ element: el, pageURL: location.href, frameOrigin: location.origin }, video));
    if (video.found) state.claimed.add(video.url);
  }

  // Records each video in `root` not seen before: <video> elements, YouTube/Vimeo iframes, and the
  // videos of click-to-load players. With `reveal`, clicks play buttons and plays videos without a
  // source (see clickToLoad() and reveal()). A video without any source found gets the page's URL.
  async function detectVideos(root, state, o) {
    noteMedia(root, state);
    try {
      await detectIn(root, state, o);
    } finally {
      for (const m of mediaIn(root)) {
        if (!m.paused && !state.wasPlaying.has(m)) {
          try { m.pause(); } catch (e) { /* ignore */ }
        }
      }
    }
  }

  async function detectIn(root, state, o) {
    if (o.reveal) await clickToLoad(root, state, o.revealTimeout);
    for (const el of root.querySelectorAll('video, iframe')) {
      if (state.seen.has(el) || el.closest('[' + UI_ATTR + ']')) continue;
      const isVideo = el.localName === 'video';
      const embed = isVideo ? null : embedKind(el);
      if (!isVideo && !embed) continue;
      state.seen.add(el);
      const player = clickedPlayerOf(el, state, root);
      const target = player || el;
      if (state.keys.has(target) || isInside(target, state, root)) continue;
      const video = isVideo ? el : null;
      const poster = posterOf(el, video) || (player ? state.clickedPosters.get(player) : null);
      const title = titleOf(target, video);
      if (embed) {
        record(state, target, { kind: embed, url: el.src, found: true, posterURL: poster, title });
        continue;
      }
      let source = ownSource(el);
      if (!source && !isProtected(el)) {
        if (o.reveal && !collector.stopRequested) source = await reveal(el, o.revealTimeout, state);
        if (!source && /^blob:/i.test(el.currentSrc || '')) source = soleManifest(state);
      }
      const kind = isProtected(el) ? 'drm' : source ? classify(source) : 'unknown';
      record(state, target, { kind, url: source ? source.url : location.href, found: !!source, posterURL: poster, title });
    }
  }

  const frameTokens = new WeakMap();

  function frameToken(frame, state) {
    let token = frameTokens.get(frame);
    if (!token) {
      const bytes = crypto.getRandomValues(new Uint8Array(12));
      token = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      frameTokens.set(frame, token);
      sendToken(frame, token);
    }
    state.frames.set(token, frame);
    return token;
  }

  function sendToken(frame, token) {
    try {
      if (frame.contentWindow) frame.contentWindow.postMessage(TOKEN_PREFIX + token, '*');
    } catch (e) { /* frame gone */ }
  }

  // A child frame reports the token its parent named it with, so the app can find it again.
  window.addEventListener('message', (e) => {
    if (isTop || e.source !== window.parent || typeof e.data !== 'string' || !e.data.startsWith(TOKEN_PREFIX)) return;
    e.stopImmediatePropagation();
    post({ type: 'frameToken', token: e.data.slice(TOKEN_PREFIX.length) });
  }, true);

  // Asks the app for the videos in the child frames named `tokens`. Returns { token: [video] }.
  async function childFrameVideos(tokens, state, o) {
    const handlers = window.webkit && window.webkit.messageHandlers;
    if (!tokens.length || !handlers || !handlers[ASK_HANDLER]) return {};
    for (const token of tokens) {
      const frame = state.frames.get(token);
      if (frame && frame.isConnected) sendToken(frame, token); // its document may have changed
    }
    const out = {};
    try {
      const reply = await handlers[ASK_HANDLER].postMessage({
        type: 'frameVideos', tokens, options: { revealTimeout: o.revealTimeout, reveal: o.reveal },
      });
      for (const token of tokens) {
        if (reply && typeof reply[token] === 'string') out[token] = JSON.parse(reply[token]);
      }
    } catch (e) { /* no answer: those frames keep their iframes */ }
    return out;
  }

  function wireVideo(v) {
    return { kind: v.kind, url: v.url, found: v.found, pageURL: v.pageURL, frameOrigin: v.frameOrigin,
      posterURL: v.posterURL || null, title: v.title || null };
  }

  // Run by the app in a child frame of the capture target: the videos in this frame and in its own
  // child frames, in document order, as a JSON array.
  async function frameVideos(options) {
    const o = Object.assign({ revealTimeout: 3000, reveal: true }, options || {});
    collector.stopRequested = false;
    const root = document.body || document.documentElement;
    const state = newVideoState();
    await detectVideos(root, state, o);
    const items = Array.from(state.records.values(), (v) => ({ element: v.element, videos: [wireVideo(v)] }));
    const frames = Array.from(root.querySelectorAll('iframe, frame'))
      .filter((f) => !embedKind(f) && !state.keys.has(f) && !isInside(f, state, root));
    const tokens = frames.map((f) => frameToken(f, state));
    const nested = await childFrameVideos(tokens, state, o);
    frames.forEach((f, i) => {
      const videos = nested[tokens[i]];
      if (videos && videos.length) items.push({ element: f, videos });
    });
    items.sort((a, b) => (a.element.compareDocumentPosition(b.element) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
    return JSON.stringify([].concat(...items.map((item) => item.videos)));
  }

  function attrOf(node, name) {
    const a = node.attrs && node.attrs.find(([k]) => k === name);
    return a ? a[1] : null;
  }

  function frameTokensIn(node, out) {
    if (!node || !node.children) return out;
    if (node.tag === 'iframe' || node.tag === 'frame') {
      const token = attrOf(node, FRAME_ATTR);
      if (token) out.push(token);
    }
    for (const c of node.children) frameTokensIn(c, out);
    return out;
  }

  // Replaces each placeholder in `tree`, and each child frame that reported videos, with a figure per
  // video: <figure data-pc-video="N"><img src="poster" alt="title"><figcaption>Video: title</figcaption>
  // </figure>, N indexing the returned videos. Videos are numbered in document order; one URL is one
  // video, every element showing it pointing at the same index.
  function placeVideos(tree, state, childVideos) {
    const videos = [];
    const byURL = new Map();
    const indexOf = (v) => {
      if (v.found && byURL.has(v.url)) return byURL.get(v.url);
      const index = videos.length;
      videos.push({ index, kind: v.kind, url: v.url, pageURL: v.pageURL, frameOrigin: v.frameOrigin,
        posterURL: v.posterURL || null, title: v.title || null });
      if (v.found) byURL.set(v.url, index);
      return index;
    };
    const figure = (index) => {
      const v = videos[index];
      const children = [];
      if (v.posterURL) children.push({ tag: 'img', attrs: [['src', v.posterURL], ['alt', v.title || '']], children: [] });
      children.push({ tag: 'figcaption', attrs: [], children: [{ text: v.title ? 'Video: ' + v.title : 'Video' }] });
      return { tag: 'figure', attrs: [['data-pc-video', String(index)]], children };
    };
    const walk = (node) => {
      if (!node.children) return;
      const out = [];
      for (const c of node.children) {
        if (c.tag === VIDEO_TAG) {
          const v = state.records.get(attrOf(c, 'key'));
          if (v) out.push(figure(indexOf(v)));
          continue;
        }
        if (c.tag === 'iframe' || c.tag === 'frame') {
          const token = attrOf(c, FRAME_ATTR);
          c.attrs = c.attrs.filter(([k]) => k !== FRAME_ATTR);
          const inner = token && childVideos[token];
          if (inner && inner.length) {
            const frameTitle = attrOf(c, 'title');
            for (const v of inner) out.push(figure(indexOf(Object.assign({}, v, { title: v.title || frameTitle }))));
            continue;
          }
        }
        walk(c);
        out.push(c);
      }
      node.children = out;
    };
    if (tree) walk(tree);
    return videos;
  }

  // Attributes a shell does not keep: shells hold no content.
  const SHELL_DROP = new Set(['src', 'srcset', 'href', 'poster']);

  // The target element and its ancestors up to <html>, outermost first, as empty shells (tag and
  // attributes): the HTML file rebuilds them around the content so that the site's layout rules
  // (classes on <html> and <body>, rules on the column's parents) match as on the page. For a frame
  // document or the whole page (`root` its body) that is <html> and <body>.
  function shellsOf(root) {
    const out = [];
    for (let el = root; el; el = el.parentElement) {
      const attributes = {};
      for (const a of el.attributes) {
        // Also not this script's own marks (data-pagecapture-ui, data-pc-*).
        if (/^on/i.test(a.name) || SHELL_DROP.has(a.name) || /^data-(pagecapture-ui$|pc-)/.test(a.name) ||
            isJavaScriptURL(a.value)) continue;
        attributes[a.name] = a.value;
      }
      out.unshift({ tag: el.localName, attributes });
    }
    return out;
  }

  function stylesheets() {
    const out = [];
    for (const el of document.querySelectorAll('link[rel~="stylesheet" i], style')) {
      if (el.localName === 'link') {
        if (el.href) out.push({ href: el.href });
      } else {
        out.push({ css: el.textContent });
      }
    }
    return out;
  }

  function viewportRect(scroller, isDocument) {
    const view = { top: 0, left: 0, bottom: window.innerHeight, right: window.innerWidth };
    if (isDocument) return view;
    const r = scroller.getBoundingClientRect();
    return {
      top: Math.max(view.top, r.top), left: Math.max(view.left, r.left),
      bottom: Math.min(view.bottom, r.bottom), right: Math.min(view.right, r.right),
    };
  }

  // Waits `delay`, then for images in view to finish loading, at most `imageTimeout`.
  async function settle(root, scroller, isDocument, delay, imageTimeout) {
    await pause(delay);
    if (collector.stopRequested) return;
    const view = viewportRect(scroller, isDocument);
    const loading = [];
    for (const img of root.querySelectorAll('img')) {
      if (img.complete) continue;
      const r = img.getBoundingClientRect();
      if (r.bottom >= view.top && r.top <= view.bottom && r.right >= view.left && r.left <= view.right) {
        loading.push(new Promise((resolve) => {
          img.addEventListener('load', resolve, { once: true });
          img.addEventListener('error', resolve, { once: true });
        }));
      }
    }
    if (loading.length) await Promise.race([Promise.all(loading), pause(imageTimeout)]);
  }

  function scrollTo(scroller, top) {
    scroller.scrollTo({ top, behavior: 'instant' });
  }

  // Scrolls the target from the top in steps, merging snapshots of its children, until neither the
  // scroll position nor the scroll height changes and no new element appears for `stallLimit`
  // attempts, or stop() is called. Text changes (a ticking clock) do not count as progress.
  // A main-content target (see isMainContent()) does not scroll itself: what scrolls it (see
  // scrollerOf()) is scrolled from the element's top to its bottom, and only the element's height
  // counts as growth, so content loading elsewhere on the page does not keep the capture going.
  // Collapsed content is expanded before the first snapshot and after each step (see expand()), and
  // videos are looked for at the same points (see detectVideos()); child frames report theirs at the
  // end, and every video is written as a figure (see placeVideos()).
  // The target's element and ancestors are returned as shells (see shellsOf()).
  // Returns the CapturedContent wire format as a JSON string.
  async function capture(options) {
    const o = Object.assign({
      wholePage: false, stepRatio: 0.8, settleDelay: 300, stallDelay: 800, imageTimeout: 2000, stallLimit: 3,
      expandDelay: 50, maxExpandClicks: 50, revealTimeout: 3000,
    }, options || {});

    let root, scroller;
    let content = false; // a main-content target, scrolled by `scroller`
    if (o.wholePage || picker.picked === document) {
      root = document.body || document.documentElement;
      scroller = document.scrollingElement || document.documentElement;
    } else if (picker.picked && picker.picked.isConnected) {
      root = picker.picked;
      content = !isScrollable(root);
      scroller = content ? scrollerOf(root) : root;
    } else {
      throw new Error('The picked area is no longer on the page.');
    }
    const isDocument = scroller === document.scrollingElement || scroller === document.documentElement;
    const viewHeight = () => (isDocument ? window.innerHeight : scroller.clientHeight);
    // For a main-content target: the scroll positions showing its top and its bottom.
    const contentTop = () => Math.round(root.getBoundingClientRect().top + scroller.scrollTop -
      (isDocument ? 0 : scroller.getBoundingClientRect().top + scroller.clientTop));
    const contentEnd = () => Math.max(contentTop(), Math.ceil(contentTop() + root.getBoundingClientRect().height - viewHeight()));
    const extent = () => (content ? root.getBoundingClientRect().height : scroller.scrollHeight);

    collector.stopRequested = false;
    const ids = new WeakMap();
    let nextId = 1;
    const idOf = (n) => {
      let id = ids.get(n);
      if (!id) { id = nextId++; ids.set(n, id); }
      return id;
    };

    const originalTop = scroller.scrollTop;
    let tree = null;
    let stopped = false;
    const take = () => {
      // Measured at each snapshot: what the target holds changes as it scrolls and expands.
      if (content) collector.furniture = furnitureOf(root);
      // A target the page has hidden shows nothing now: what was collected stays.
      const snap = snapshot(root, idOf);
      if (!snap) return 0;
      const merged = Merge.merge(tree, snap);
      tree = merged.tree;
      return merged.added;
    };
    const expansion = { clicked: new WeakSet(), seen: new WeakMap(), clickedTabs: new WeakSet() };
    const videos = newVideoState();
    collector.videos = videos;
    collector.headings = newHeadingState(root);
    const detect = () => detectVideos(root, videos, { reveal: true, revealTimeout: o.revealTimeout });
    try {
      scrollTo(scroller, content ? Math.max(0, contentTop()) : 0);
      await settle(root, scroller, isDocument, o.settleDelay, o.imageTimeout);
      await detect();
      await expand(root, scroller, take, expansion, o);
      let stalls = 0;
      let progressed = true;
      for (;;) {
        const added = take();
        if (collector.stopRequested) { stopped = true; break; }
        stalls = progressed || added > 0 ? 0 : stalls + 1;
        if (stalls >= o.stallLimit) break;

        const topBefore = scroller.scrollTop;
        const heightBefore = extent();
        const next = topBefore + Math.max(1, Math.floor(viewHeight() * o.stepRatio));
        scrollTo(scroller, content ? Math.min(next, contentEnd()) : next);
        await settle(root, scroller, isDocument, stalls > 0 ? o.stallDelay : o.settleDelay, o.imageTimeout);
        await detect();
        const clicks = await expand(root, scroller, take, expansion, o);
        progressed = scroller.scrollTop !== topBefore || extent() > heightBefore || clicks > 0;
      }
    } finally {
      scrollTo(scroller, originalTop);
      collector.wake = null;
      collector.videos = null;
      collector.headings = null;
      collector.furniture = null;
      for (const el of root.querySelectorAll('[' + EXPANDED + ']')) el.removeAttribute(EXPANDED);
      for (const el of root.querySelectorAll('[' + TAB_TITLE + ']')) el.removeAttribute(TAB_TITLE);
      for (const el of root.querySelectorAll('[' + TAB_BAR + ']')) el.removeAttribute(TAB_BAR);
    }

    // After a stop, child frames only report what they already show.
    const childVideos = await childFrameVideos(frameTokensIn(tree, []), videos,
      { reveal: !stopped, revealTimeout: o.revealTimeout });
    const found = placeVideos(tree, videos, childVideos);
    const { html, imageURLs } = Merge.serialize(tree);
    return JSON.stringify({
      html, imageURLs, stopped, videos: found,
      ancestors: shellsOf(root),
      baseURL: document.baseURI,
      title: document.title,
      stylesheets: stylesheets(),
    });
  }

  globalThis.__pageCapture = Object.freeze({ setPicking, capture, stop, frameVideos });
  post({ type: 'frameReady' });
})();
