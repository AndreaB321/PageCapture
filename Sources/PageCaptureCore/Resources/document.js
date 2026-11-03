// PageCaptureDocument: turns the current (blank) page into the capture's document: printable for the
// PDF, or for the screen as the HTML file.
//
//   PageCaptureDocument.build({ html, title, baseURL, sheets: [{href}|{css}], images: {url: localURL},
//                               videos: {"<N>": {href, title, poster?, note?}}, page? })
//     Writes <base>, the stylesheets in order and the captured fragment into the document. Images with a
//     local copy use it; spacer styles left by virtualised lists are removed; lazy images load eagerly;
//     panels the collector expanded are shown in full; every tab panel is shown under its tab's title
//     and tab bars are left out. Each `<figure data-pc-video="N">` with an entry
//     in `videos` becomes one link to `href`: the preview image (`poster`, else the figure's own) under
//     a play button, the caption and the note.
//     With `page` ({width, height: the printable area in CSS px; paperWidth, paperHeight, margin in
//     points}), the document is laid out and paginated for that page (printCSS()).
//     Without `baseURL` (the HTML file) there is no <base> and the document is laid out for the screen.
//   PageCaptureDocument.wrap(shells) rebuilds the target's element and ancestors ([{tag, attributes}],
//     outermost first, from capture.js) around the built content, so the site's layout rules match
//     as on the page: the <html> and <body> shells' attributes go onto the document's own (classes
//     merged), the others become nested wrappers, the innermost the target element. Nothing in them
//     clips or hides the content (SHELL_CSS).
//   PageCaptureDocument.standalone() -> the document's HTML without scripts, <base> or <link>s.
//   PageCaptureDocument.settle(page) fits the laid-out document to the page (fitPage()).
//   PageCaptureDocument.pending() -> number of stylesheets, images and fonts still loading.
//   PageCaptureDocument.cleanStyle(style, tag) -> the inline style without spacer declarations (pure).
(function (global) {
  'use strict';
  if (global.PageCaptureDocument) return;

  // Replaced elements keep their sizes: their inline height is real, not a spacer.
  const REPLACED = new Set(['img', 'picture', 'video', 'canvas', 'svg', 'iframe', 'embed', 'object', 'input']);
  // Vertical sizing that virtualised lists use to reserve room for rows that are not rendered.
  const SPACER = new Set(['height', 'min-height', 'max-height', 'padding-top', 'padding-bottom',
    'padding-block', 'padding-block-start', 'padding-block-end']);
  // Absolutely positioned rows (react-window, TanStack Virtual) are put back in flow.
  const POSITIONED_ROW = new Set(['position', 'top', 'left', 'transform']);

  // Panels the collector saw expanded (capture.js) print in full, also when the page collapsed them
  // again ("hidden": exclusive accordions) by class-based CSS. So does every tab panel (marked with
  // its tab's title), whichever tab is selected; tab bars are hidden (see tabTitles()).
  const EXPANDED_CSS =
    '[data-pc-expanded], [data-pc-tab-title] { height: auto !important; max-height: none !important;' +
    ' overflow: visible !important; visibility: visible !important; opacity: 1 !important;' +
    ' content-visibility: visible !important; }\n' +
    '[data-pc-expanded="hidden"], [data-pc-tab-title]:not([data-pc-expanded="shown"]) { display: revert !important; }\n' +
    '[data-pc-tabs] { display: none !important; }\n' +
    // Pages stack tab panels for fade effects (absolutely positioned in a fixed-height box, or all in
    // one grid cell); printed one after another, they go back into the flow.
    '[data-pc-tab-title] { position: static !important; inset: auto !important; transform: none !important;' +
    ' float: none !important; grid-area: auto !important; margin-top: 0 !important; }\n' +
    ':has(> [data-pc-tab-title], > .pc-keep > [data-pc-tab-title]) { display: block !important; height: auto !important; min-height: 0 !important;' +
    ' max-height: none !important; overflow: visible !important; }\n' +
    '.pc-tab-title { display: block !important; visibility: visible !important; font-weight: bold !important; }';

  // Printing: the root is exactly as wide as the paper's printable area, so WebKit prints CSS px at
  // 72/96 pt without shrinking the page to fit (it lays out at least 1.25 times the printable width in
  // points, then scales to fit the widest content); anything wider is clipped at the right margin.
  // Page breaks fall between lines and outside blocks that should stay whole.
  function printCSS(page) {
    return '@page { size: ' + page.paperWidth + 'pt ' + page.paperHeight + 'pt; margin: ' + page.margin + 'pt; }\n' +
      'html { width: ' + page.width + 'px !important; min-width: 0 !important; max-width: none !important;' +
      ' overflow-x: clip !important; }\n' +
      'body { min-width: 0 !important; overflow-x: clip !important; orphans: 3; widows: 3; }\n' +
      'p, li, h1, h2, h3, h4, h5, h6, figure, img, svg, video, tr, blockquote, pre, table' +
      ' { break-inside: avoid !important; }\n' +
      'h1, h2, h3, h4, h5, h6 { break-after: avoid !important; }';
  }

  // A play button over each video's preview, and a dark frame when there is no preview.
  const VIDEO_CSS =
    'a.pc-video { display: block !important; color: inherit !important; text-decoration: none !important; }\n' +
    '.pc-video-frame { position: relative !important; display: inline-block !important; max-width: 100%;' +
    ' min-width: 160px; min-height: 90px; background: #222; vertical-align: top; }\n' +
    '.pc-video-frame > img { display: block !important; max-width: 100%; height: auto; margin: 0 auto; }\n' +
    '.pc-video-frame:not(:has(img)) { width: 320px; height: 180px; }\n' +
    '.pc-video-play { position: absolute !important; display: block !important; left: 50%; top: 50%;' +
    ' width: 64px; height: 64px; margin: -32px 0 0 -32px; box-sizing: border-box; border: 2px solid #fff;' +
    ' border-radius: 50%; background: rgba(0, 0, 0, 0.6); }\n' +
    '.pc-video-play::after { content: ""; position: absolute; left: 22px; top: 16px; width: 0; height: 0;' +
    ' border-style: solid; border-width: 14px 0 14px 22px; border-color: transparent transparent transparent #fff; }\n' +
    'a.pc-video figcaption { display: block; }';

  function declarations(style) {
    const out = [];
    for (const part of style.split(';')) {
      const i = part.indexOf(':');
      if (i < 0) continue;
      const name = part.slice(0, i).trim().toLowerCase();
      const value = part.slice(i + 1).trim();
      if (name) out.push([name, value]);
    }
    return out;
  }

  function cleanStyle(style, tag) {
    if (REPLACED.has(tag)) return style;
    let decls = declarations(style);
    const value = (n) => (decls.find(([k]) => k === n) || [])[1] || '';
    const absolute = /^(absolute|fixed)\b/i.test(value('position'));
    const placed = value('top') !== '' || /translate/i.test(value('transform'));
    const isRow = absolute && placed;
    decls = decls.filter(([k]) => !SPACER.has(k) && !(isRow && POSITIONED_ROW.has(k)));
    return decls.map(([k, v]) => k + ': ' + v).join('; ');
  }

  function prepare(root, images) {
    for (const el of root.querySelectorAll('[style]')) {
      const original = el.getAttribute('style');
      const cleaned = cleanStyle(original, el.localName);
      if (cleaned !== original) el.dataset.pcStyle = original;
      if (cleaned) el.setAttribute('style', cleaned); else el.removeAttribute('style');
    }
    for (const img of root.querySelectorAll('img')) {
      img.removeAttribute('loading');
      img.setAttribute('decoding', 'sync');
      const local = images[img.getAttribute('src') || ''];
      if (!local) continue;
      img.setAttribute('src', local);
      img.removeAttribute('srcset');
      img.removeAttribute('sizes');
      const picture = img.parentElement;
      if (picture && picture.localName === 'picture') {
        for (const source of picture.querySelectorAll(':scope > source')) source.remove();
      }
    }
  }

  function videoFigures(root, videos) {
    for (const figure of root.querySelectorAll('figure[data-pc-video]')) {
      const v = videos[figure.getAttribute('data-pc-video')];
      if (!v) continue;
      const own = figure.querySelector('img');
      let img = own;
      if (v.poster) {
        img = document.createElement('img');
        img.src = v.poster;
        img.alt = own ? own.getAttribute('alt') || '' : '';
      }
      const frame = document.createElement('span');
      frame.className = 'pc-video-frame';
      if (img) frame.appendChild(img);
      const play = document.createElement('span');
      play.className = 'pc-video-play';
      frame.appendChild(play);
      const caption = document.createElement('figcaption');
      caption.textContent = 'Video' + (v.title ? ': ' + v.title : '');
      if (v.note) {
        const note = document.createElement('em');
        note.textContent = '(' + v.note + ')';
        caption.append(document.createElement('br'), note);
      }
      const link = document.createElement('a');
      link.className = 'pc-video';
      link.href = v.href;
      link.append(frame, caption);
      figure.replaceChildren(link);
    }
  }

  // Puts each tab panel's title before it as a heading one level below the section it is in, as the
  // Markdown does, so the page's heading styles apply.
  function tabTitles(root) {
    let section = 0;
    for (const el of root.querySelectorAll('h1, h2, h3, h4, h5, h6, [data-pc-tab-title]')) {
      const title = el.getAttribute('data-pc-tab-title');
      if (title === null) {
        if (!el.closest('[data-pc-expanded], details, [data-pc-tab-title]')) section = +el.localName[1];
        continue;
      }
      if (!title.trim()) continue;
      const heading = document.createElement('h' + (section ? Math.min(6, Math.max(3, section + 1)) : 4));
      heading.className = 'pc-tab-title';
      heading.textContent = title.trim();
      el.before(heading);
    }
  }

  function track(el) {
    el.dataset.pcLoading = '1';
    const done = () => { delete el.dataset.pcLoading; };
    el.addEventListener('load', done, { once: true });
    el.addEventListener('error', done, { once: true });
  }

  function build(opts) {
    const head = document.head;
    head.replaceChildren();
    const meta = document.createElement('meta');
    meta.setAttribute('charset', 'utf-8');
    head.appendChild(meta);
    if (opts.baseURL) {
      const base = document.createElement('base');
      base.href = opts.baseURL;
      head.appendChild(base);
    } else {
      // On screen (the HTML file): laid out for the window's width.
      const viewport = document.createElement('meta');
      viewport.name = 'viewport';
      viewport.content = 'width=device-width, initial-scale=1';
      head.appendChild(viewport);
    }
    const title = document.createElement('title');
    title.textContent = opts.title || '';
    head.appendChild(title);
    for (const sheet of opts.sheets || []) {
      let el;
      if (sheet.href) {
        el = document.createElement('link');
        el.rel = 'stylesheet';
        track(el);
        el.href = sheet.href;
      } else {
        el = document.createElement('style');
        el.textContent = sheet.css || '';
      }
      head.appendChild(el);
    }
    const override = document.createElement('style');
    override.textContent = 'html, body { height: auto !important; overflow: visible !important; }\n' +
      (opts.page ? printCSS(opts.page) + '\n' : '') +
      'img, svg, video { max-width: 100%; }\n' + EXPANDED_CSS + '\n' + VIDEO_CSS;
    head.appendChild(override);

    const template = document.createElement('template');
    template.innerHTML = opts.html;
    videoFigures(template.content, opts.videos || {});
    tabTitles(template.content);
    prepare(template.content, opts.images || {});
    document.body.replaceChildren(document.importNode(template.content, true));
  }

  // Once stylesheets have loaded: an element whose stripped height was real (a banner holding a
  // heading anchored with `bottom`) now has an absolutely positioned child sticking out above it,
  // drawn over the content before it. Those get their original style back.
  function settle(page) {
    for (const el of document.querySelectorAll('[data-pc-style]')) {
      const top = el.getBoundingClientRect().top;
      const overflowsUp = [...el.children].some((child) => {
        const position = getComputedStyle(child).position;
        return (position === 'absolute' || position === 'fixed') && child.getBoundingClientRect().top < top - 1;
      });
      if (overflowsUp) el.setAttribute('style', el.dataset.pcStyle);
      delete el.dataset.pcStyle;
    }
    if (page) fitPage(page);
  }

  const SCROLLS = /^(auto|scroll|overlay)$/;
  const VISIBLE_BORDER = (s) => ['Top', 'Right', 'Bottom', 'Left'].some((side) =>
    s['border' + side + 'Style'] !== 'none' && parseFloat(s['border' + side + 'Width']) > 0);
  const TRANSPARENT = /^(transparent|rgba\(.*,\s*0\))$/;

  function important(el, properties) {
    for (const [name, value] of Object.entries(properties)) el.style.setProperty(name, value, 'important');
  }

  // Measured on the laid-out document (as wide as the page), then changed, so layout runs once more.
  //  - Elements wider than the page (a desktop-only fixed or minimum width) are narrowed to it.
  //  - Scroll containers print whole: WebKit cannot split them across pages, so it slices through their
  //    text lines and images, and it would leave out what they scroll to.
  //  - Cards (a box with a background, border or shadow) and flex and grid rows shorter than 40% of a
  //    page are not split. A taller grid becomes a wrapping flex row of its cells at their widths:
  //    WebKit slices through a grid cell at a page break, but splits flex items between lines.
  //  - Tab titles are at least as large as the text of their panel.
  // Every box between a tab panel and its widget (the nearest ancestor holding the hidden tab bar, else
  // the panels' common ancestor) goes back into the flow and grows to fit: pages stack panels with
  // absolutely positioned slots, a shared grid cell or a fixed-height box, at any depth.
  function freeTabPanels() {
    const panels = [...document.querySelectorAll('[data-pc-tab-title]')];
    const freed = new Set();
    for (const panel of panels) {
      const root = panel.parentElement && panel.parentElement.closest(':has([data-pc-tabs])');
      const siblings = panels.filter((other) => other !== panel);
      for (let el = panel.parentElement; el && el !== document.body; el = el.parentElement) {
        if (!freed.has(el)) {
          freed.add(el);
          const style = getComputedStyle(el);
          const change = { height: 'auto', 'min-height': '0', 'max-height': 'none', overflow: 'visible' };
          if (style.position === 'absolute' || style.position === 'fixed') {
            Object.assign(change, { position: 'static', inset: 'auto', transform: 'none' });
          }
          // Panels and their titles stack, however many boxes wrap them: no flex row or grid cell.
          if (/grid|flex/.test(style.display)) change.display = 'block';
          important(el, change);
        }
        if (root ? el === root : siblings.every((other) => el.contains(other))) break;
      }
    }
  }

  function fitPage(page) {
    freeTabPanels();
    const right = document.documentElement.getBoundingClientRect().right + 1;
    const small = 0.4 * page.height;
    const changes = [];
    for (const el of document.body.querySelectorAll('*')) {
      const style = getComputedStyle(el);
      if (style.display === 'none' || style.display === 'contents' || style.display.startsWith('inline')) continue;
      const rect = el.getBoundingClientRect();
      const change = {};
      if (rect.right > right && !REPLACED.has(el.localName)) Object.assign(change, { 'max-width': '100%', 'min-width': '0' });
      if (SCROLLS.test(style.overflowY) || SCROLLS.test(style.overflowX)) {
        Object.assign(change, { 'overflow-y': 'visible', 'max-height': 'none',
          'overflow-x': style.overflowX === 'visible' ? 'visible' : 'clip' });
        if (el.scrollHeight > el.clientHeight + 1) change.height = 'auto';
      }
      const row = /flex|grid/.test(style.display);
      if (rect.height > 0 && rect.height < small && (row || VISIBLE_BORDER(style) || style.boxShadow !== 'none' ||
          !TRANSPARENT.test(style.backgroundColor) || style.backgroundImage !== 'none')) {
        change['break-inside'] = 'avoid';
      } else if (rect.height >= small && /grid/.test(style.display)) {
        // Cells keep their widths and wrap into rows like the grid's; flex items split across pages.
        Object.assign(change, { display: 'flex', 'flex-wrap': 'wrap' });
        for (const cell of el.children) {
          const position = getComputedStyle(cell).position;
          if (position === 'absolute' || position === 'fixed') continue;
          changes.push([cell, { flex: 'none', width: cell.getBoundingClientRect().width + 'px', 'box-sizing': 'border-box' }]);
        }
      } else if (rect.height >= small && /flex/.test(style.display)) {
        // A tall flex box that stacks its items (a column, or a row with one item) prints as a block:
        // WebKit ignores `break-inside: avoid` inside it and slices images and cards at page breaks.
        // Its gap becomes the items' top margin.
        const items = [...el.children].filter((child) => {
          const s = getComputedStyle(child);
          return s.display !== 'none' && s.position !== 'absolute' && s.position !== 'fixed';
        });
        if (style.flexDirection.startsWith('column') || items.length <= 1) {
          change.display = 'block';
          const gap = parseFloat(style.rowGap) || 0;
          if (gap > 0) items.slice(1).forEach((item) => changes.push([item, { 'margin-top': gap + 'px' }]));
        }
      }
      if (Object.keys(change).length) changes.push([el, change]);
    }
    // An image sits in a line box, which WebKit slices at a page break like any other content: the
    // nearest block around each image no taller than a page is kept whole.
    for (const img of document.body.querySelectorAll('img, svg, video, canvas')) {
      // The nearest ancestor that makes a box of its own (not inline, not `display: contents`).
      let block = img.parentElement;
      while (block && block !== document.body &&
             (/^(inline|contents)/.test(getComputedStyle(block).display) || block.getBoundingClientRect().height === 0)) {
        block = block.parentElement;
      }
      if (!block || block === document.body) continue;
      const height = block.getBoundingClientRect().height;
      if (height > 0 && height < page.height) changes.push([block, { 'break-inside': 'avoid' }]);
    }
    for (const title of document.querySelectorAll('.pc-tab-title')) {
      const size = (el) => (el ? parseFloat(getComputedStyle(el).fontSize) : 0);
      const text = Math.max(size(title.parentElement), size(title.nextElementSibling));
      if (size(title) < text) changes.push([title, { 'font-size': text + 'px' }]);
    }
    for (const [el, change] of changes) important(el, change);
    keepHeadingsWithNext(small);
  }

  // WebKit ignores `break-after: avoid`, so a heading can end a page alone. A heading and the block
  // after it, together shorter than `small`, go into one wrapper that is not split.
  function keepHeadingsWithNext(small) {
    for (const heading of document.body.querySelectorAll('h1, h2, h3, h4, h5, h6, [data-pc-heading]')) {
      const next = heading.nextElementSibling;
      if (!next || /^h[1-6]$/.test(next.localName) || next.hasAttribute('data-pc-heading')) continue;
      const position = getComputedStyle(next).position;
      if (position === 'absolute' || position === 'fixed') continue;
      const top = heading.getBoundingClientRect().top;
      if (next.getBoundingClientRect().bottom - top >= small) continue;
      const wrapper = document.createElement('div');
      wrapper.className = 'pc-keep';
      wrapper.style.setProperty('break-inside', 'avoid', 'important');
      heading.before(wrapper);
      wrapper.append(heading, next);
    }
  }

  // URL parsing strips tabs and newlines anywhere and leading controls and spaces before the scheme.
  function isJavaScriptURL(value) {
    return /^javascript:/i.test(value.replace(/[\t\n\r]/g, '').replace(/^[\u0000-\u0020]+/, ''));
  }

  // Shells (see wrap()) keep their width, margins, padding, flex and grid, and their classes keep
  // matching; in a static file nothing in them may clip or hide the content: no fixed or viewport
  // height, no scrolling or clipping box, no fixed, absolute or sticky placement ("static"), never
  // `display: none` ("shown").
  const SHELL = 'data-pc-shell';
  const SHELL_CSS =
    '[data-pc-shell] { height: auto !important; min-height: 0 !important; max-height: none !important;' +
    ' overflow: visible !important; visibility: visible !important; opacity: 1 !important; }\n' +
    '[data-pc-shell~="static"] { position: static !important; inset: auto !important; transform: none !important; }\n' +
    '[data-pc-shell~="shown"] { display: block !important; }';
  // Inline declarations those rules replace: an inline `!important` would win over them.
  const SHELL_INLINE = ['height', 'min-height', 'max-height', 'overflow', 'visibility', 'opacity'];
  const PLACEMENT = ['position', 'inset', 'top', 'right', 'bottom', 'left', 'transform'];
  // Shells hold no content.
  const SHELL_DROP = new Set(['src', 'srcset', 'href', 'poster']);

  function wrap(shells) {
    const content = [...document.body.childNodes];
    const own = [];
    let inner = document.body;
    for (const shell of shells || []) {
      let el;
      if (shell.tag === 'html') el = document.documentElement;
      else if (shell.tag === 'body') el = document.body;
      else {
        try { el = document.createElement(shell.tag); } catch (e) { el = document.createElement('div'); }
        inner.appendChild(el);
        inner = el;
      }
      for (const [name, value] of Object.entries(shell.attributes || {})) {
        if (/^on/i.test(name) || SHELL_DROP.has(name) || isJavaScriptURL(value)) continue;
        try {
          if (name === 'class') el.classList.add(...value.split(/\s+/).filter(Boolean));
          else el.setAttribute(name, value);
        } catch (e) { /* a name the parser allows but setAttribute does not (`@click`) */ }
      }
      for (const name of SHELL_INLINE) el.style.removeProperty(name);
      if (el.style.display === 'none') el.style.removeProperty('display');
      el.setAttribute(SHELL, '');
      own.push(el);
    }
    if (inner !== document.body) inner.append(...content);
    const style = document.createElement('style');
    style.textContent = SHELL_CSS;
    document.head.appendChild(style);
    for (const el of own) {
      const computed = getComputedStyle(el);
      const marks = [];
      if (/^(fixed|absolute|sticky)$/.test(computed.position)) {
        marks.push('static');
        for (const name of PLACEMENT) el.style.removeProperty(name);
      }
      if (computed.display === 'none') marks.push('shown');
      el.setAttribute(SHELL, marks.join(' '));
      if (!el.getAttribute('style')) el.removeAttribute('style');
    }
  }

  // Attributes that hold a URL, which must not run script.
  const URL_ATTRS = new Set(['href', 'src', 'poster', 'action', 'formaction', 'cite', 'background', 'data', 'xlink:href']);

  // The built document as one self-contained file: no scripts, event handlers or `javascript:` URLs,
  // no <base> and no external stylesheets (build() got them inlined); embedded frames run no script.
  function standalone() {
    const root = document.documentElement;
    for (const el of root.querySelectorAll('script, base, link, meta[http-equiv]')) el.remove();
    for (const el of root.querySelectorAll('*')) {
      for (const a of [...el.attributes]) {
        if (/^on/i.test(a.name) || (URL_ATTRS.has(a.name) && isJavaScriptURL(a.value))) el.removeAttribute(a.name);
      }
    }
    for (const frame of root.querySelectorAll('iframe, frame')) frame.setAttribute('sandbox', '');
    for (const el of root.querySelectorAll('[data-pc-style]')) delete el.dataset.pcStyle;
    return '<!doctype html>\n' + root.outerHTML;
  }

  function pending() {
    let n = document.querySelectorAll('link[data-pc-loading]').length;
    for (const img of document.images) if (!img.complete) n++;
    if (document.fonts && document.fonts.status === 'loading') n++;
    return n;
  }

  global.PageCaptureDocument = Object.freeze({ build, wrap, pending, settle, standalone, cleanStyle });
})(globalThis);
