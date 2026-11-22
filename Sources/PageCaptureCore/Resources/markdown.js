// PageCaptureMarkdown: rewrites a captured HTML fragment as plain, semantic HTML, which the bundled
// MarkItDown then writes as Markdown (MarkdownExporter). This script understands the page; MarkItDown
// only writes what it is given. Parses with DOMParser (inert: no scripts run, no images load), so it
// needs a DOM but no network.
//
//   PageCaptureMarkdown.semanticHTML(html, images, videos) -> string (the body's HTML)
//     images: { "<absolute image URL>": "images/<file>" } for the images that downloaded; any other
//     image keeps its remote URL.
//     videos: { "<N>": { href, title, poster?, note? } } for the `<figure data-pc-video="N">` that
//     capture.js left for each video: the figure becomes its preview image (`poster`, else the
//     figure's own image) or caption, linking to `href`, then the emphasised `note` if there is one.
//     Figures without an entry keep their image and caption.
//
// The result keeps the content and its structure, not the page's chrome: video player controls,
// site navigation, headers and footers, dialogs, menus and empty bullets are left out (see prune()),
// layout tables are unwrapped into their blocks, tables of marked rows (a ✓, a number or an icon, then
// the text) become lists (see markerTable()), expanded accordion headers become headings, each tab
// widget becomes its panels, each under its tab's title (see tabs()), and elements capture.js found
// styled as headings (`data-pc-heading="N"`) become headings of level N, kept within 2-6. It holds
// only what MarkItDown turns into Markdown: headings, paragraphs, lists, block quotes, code blocks,
// data tables (no merged cells), links, images, emphasis, code and line breaks.
(function (global) {
  'use strict';
  if (global.PageCaptureMarkdown) return;

  // Never converted: scripts, styles, embeds, form controls... (chrome.js, loaded first).
  const SKIP = global.PageCaptureChrome.NOT_TEXT;
  const BLOCK = new Set(['address', 'article', 'aside', 'blockquote', 'body', 'center', 'dd', 'details', 'div',
    'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'header', 'hgroup', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'summary', 'table', 'tbody',
    'td', 'tfoot', 'th', 'thead', 'tr', 'ul', 'caption', 'legend']);
  const BLOCK_SELECTOR = Array.from(BLOCK).join(',');
  const HEADING_SELECTOR = 'h1,h2,h3,h4,h5,h6';
  // A tab panel's tab title, and a tab bar, as capture.js marks them (or tabs() for unmarked HTML).
  const TAB_TITLE = 'data-pc-tab-title';
  const TAB_BAR = 'data-pc-tabs';
  // An element the page styles as a heading, with the level it reads as, as capture.js marks it.
  const HEADING_MARK = 'data-pc-heading';
  // Accordion and tab panels: headings inside them do not move the level of the titles around them.
  const PANEL = '[data-pc-expanded], details, [' + TAB_TITLE + ']';

  function isHidden(el) {
    if (el.hasAttribute('hidden')) return true;
    const style = (el.getAttribute('style') || '').toLowerCase().replace(/\s+/g, '');
    return /(^|;)display:none(!important)?(;|$)/.test(style) || /(^|;)visibility:hidden(!important)?(;|$)/.test(style);
  }

  function skipped(node) {
    if (node.nodeType === 8) return true;
    if (node.nodeType !== 1) return false;
    // A button that discloses content (an accordion header) is part of the text.
    if (node.localName === 'button' && isAccordionHeader(node)) return isHidden(node);
    // Every tab panel is shown, also those the page hides while another tab is selected.
    if (node.hasAttribute(TAB_TITLE)) return SKIP.has(node.localName);
    return SKIP.has(node.localName) || isHidden(node);
  }

  // A control that opens a panel in place: a <summary>, or a button with aria-expanded that is not a
  // popup (menu, listbox, dialog) trigger.
  function isAccordionHeader(el) {
    if (el.localName === 'summary') return true;
    if (!el.hasAttribute('aria-expanded')) return false;
    const popup = el.getAttribute('aria-haspopup');
    if (popup !== null && popup !== 'false') return false;
    return el.localName === 'button' || el.getAttribute('role') === 'button';
  }

  function isBlock(node) {
    return node.nodeType === 1 && (BLOCK.has(node.localName) || isAccordionHeader(node) ||
      node.hasAttribute(TAB_TITLE) || node.hasAttribute(HEADING_MARK));
  }

  // An inline element (span, label, custom element...) wrapping blocks: its blocks are kept as blocks.
  function wrapsBlocks(node) {
    return node.nodeType === 1 && node.localName !== 'a' &&
      node.querySelector(BLOCK_SELECTOR + ',[aria-expanded],[' + TAB_TITLE + '],[' + HEADING_MARK + ']') !== null;
  }

  // Percent-encodes one path segment fully, like encodeURIComponent plus the characters it leaves
  // that Markdown or URLs treat specially.
  function encodeSegment(segment) {
    return encodeURIComponent(segment).replace(/[!'()*~]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
  }

  // Relative destinations of saved images and videos are encoded per path segment, so a file name
  // holding `#`, `?` or `%` is not read as a fragment, a query or an escape. Spaces and parentheses
  // never reach the Markdown raw, which would end the link.
  function escapeURL(url) {
    if (/^(images|videos)\//.test(url)) return url.split('/').map(encodeSegment).join('/');
    return url.replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');
  }

  // MarkItDown writes an image's alt text as it is: brackets and backslashes are escaped here.
  function altText(text) {
    return text.replace(/\s+/g, ' ').trim().replace(/[[\]\\]/g, '\\$&');
  }

  // ------------------------------------------------- the semantic HTML

  // A new element in `doc` with `attrs` and, optionally, text.
  function make(ctx, tag, attrs, text) {
    const el = ctx.doc.createElement(tag);
    for (const [name, value] of Object.entries(attrs || {})) el.setAttribute(name, value);
    if (text !== undefined) el.textContent = text;
    return el;
  }

  // Text or an image: what makes a block worth keeping.
  function hasVisible(el) {
    return el.textContent.trim() !== '' || el.querySelector('img') !== null;
  }

  function image(node, ctx) {
    const src = node.getAttribute('src');
    if (!src) return null;
    return make(ctx, 'img', { src: escapeURL(ctx.images[src] || src), alt: altText(node.getAttribute('alt') || '') });
  }

  // A captured video's figure as a link (around its preview image, else its label), then its note;
  // null when it has no entry in `videos`.
  function video(el, ctx) {
    const v = ctx.videos[el.getAttribute('data-pc-video')];
    if (!v) return null;
    const label = ('Video' + (v.title ? ': ' + v.title : '')).replace(/\s+/g, ' ').trim();
    let poster = v.poster;
    if (!poster) {
      const img = el.querySelector('img');
      const src = img && img.getAttribute('src');
      if (src) poster = ctx.images[src] || src;
    }
    const link = make(ctx, 'a', { href: escapeURL(v.href) });
    link.append(poster ? make(ctx, 'img', { src: escapeURL(poster), alt: altText(label) }) : label);
    const out = [link];
    if (v.note) out.push(' ', make(ctx, 'em', {}, '(' + v.note.replace(/\s+/g, ' ').trim() + ')'));
    return out;
  }

  // Appends the inline content of `node` to `target`. Block descendants are flattened with spaces.
  function inline(node, target, ctx) {
    if (node.nodeType === 3) {
      target.append(node.data);
      return;
    }
    if (node.nodeType !== 1 || skipped(node)) return;
    const into = (parent) => {
      for (const c of node.childNodes) inline(c, parent, ctx);
      return parent;
    };
    switch (node.localName) {
      case 'br': target.append(make(ctx, 'br')); return;
      case 'img': {
        const img = image(node, ctx);
        if (img) target.append(img);
        return;
      }
      case 'strong': case 'b': target.append(into(make(ctx, 'strong'))); return;
      case 'em': case 'i': case 'cite': case 'dfn': target.append(into(make(ctx, 'em'))); return;
      case 'del': case 's': case 'strike': target.append(into(make(ctx, 'del'))); return;
      // Inline code is one line: a source line break would start a new block (`# b`, `- y`).
      case 'code': case 'kbd': case 'samp': case 'tt':
        target.append(make(ctx, 'code', {}, node.textContent.replace(/[ \t\n\r\f]+/g, ' ')));
        return;
      case 'a': {
        const href = (node.getAttribute('href') || '').trim();
        if (!href || /^javascript:/i.test(href)) into(target);
        else target.append(into(make(ctx, 'a', { href: escapeURL(href) })));
        return;
      }
      case 'figure': {
        const v = video(node, ctx);
        target.append(' ');
        if (v !== null) target.append(...v); else into(target);
        target.append(' ');
        return;
      }
      default:
        if (isBlock(node)) target.append(' ');
        into(target);
        if (isBlock(node)) target.append(' ');
    }
  }

  // The inline content of `el`'s children, in a new `tag` element.
  function inlineOf(el, tag, ctx) {
    const out = make(ctx, tag);
    for (const c of el.childNodes) inline(c, out, ctx);
    return out;
  }

  // Removes the bold around all of `el`'s content, as when the page makes a whole heading bold.
  function unbold(el) {
    const parts = Array.from(el.childNodes).filter((n) => n.nodeType !== 3 || n.data.trim());
    const only = parts.length === 1 ? parts[0] : null;
    if (only && only.localName === 'strong' && !only.querySelector('strong')) only.replaceWith(...only.childNodes);
  }

  // Appends the blocks of `parent`'s children to `target`: inline runs become paragraphs.
  function blocks(parent, target, ctx) {
    let run = null;
    const flush = () => {
      if (run && hasVisible(run)) target.append(run);
      run = null;
    };
    for (const child of parent.childNodes) {
      if (skipped(child)) continue;
      if (isBlock(child)) {
        flush();
        block(child, target, ctx);
      } else if (wrapsBlocks(child)) {
        flush();
        blocks(child, target, ctx);
      } else {
        if (!run) run = make(ctx, 'p');
        inline(child, run, ctx);
      }
    }
    flush();
  }

  // A list item holding one paragraph holds its text directly, so the list stays tight.
  function tighten(item) {
    const paragraphs = Array.from(item.children).filter((c) => c.localName === 'p');
    if (paragraphs.length === 1) paragraphs[0].replaceWith(...paragraphs[0].childNodes);
  }

  // Accordion headers and tab titles sit one level below the section they are in, so their panels
  // read as its subsections.
  function subsectionLevel(ctx) {
    return ctx.heading ? Math.min(6, Math.max(3, ctx.heading + 1)) : 4;
  }

  // A tab panel comes out under its tab's title, unless it is empty.
  function block(el, target, ctx) {
    const title = el.getAttribute(TAB_TITLE);
    if (title === null) {
      content(el, target, ctx);
      return;
    }
    const body = make(ctx, 'div');
    content(el, body, ctx);
    const text = title.replace(/\s+/g, ' ').trim();
    if (text && body.childNodes.length) target.append(make(ctx, 'h' + subsectionLevel(ctx), {}, text));
    target.append(...body.childNodes);
  }

  // The level capture.js marked `el` with, kept within 2-6, or 0.
  function markedLevel(el) {
    const n = parseInt(el.getAttribute(HEADING_MARK), 10);
    return isNaN(n) ? 0 : Math.min(6, Math.max(2, n));
  }

  // Appends `el` as a heading at `level`, unless it has no text; returns whether it did.
  function heading(el, level, target, ctx, unbolded) {
    const h = inlineOf(el, 'h' + level, ctx);
    if (unbolded) unbold(h);
    if (!hasVisible(h)) return false;
    target.append(h);
    return true;
  }

  function content(el, target, ctx) {
    const tag = el.localName;
    if (isAccordionHeader(el)) {
      heading(el, subsectionLevel(ctx), target, ctx, false);
      return;
    }
    const marked = markedLevel(el);
    if (marked && !/^(h[1-6]|table|ul|ol|pre|blockquote)$/.test(tag)) {
      // Like a real heading, it is the section that accordion headers and tab titles go below.
      if (heading(el, marked, target, ctx, true) && !el.closest(PANEL)) ctx.heading = marked;
      return;
    }
    switch (tag) {
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
        if (heading(el, +tag[1], target, ctx, false) && !el.closest(PANEL)) ctx.heading = +tag[1];
        return;
      case 'hr': target.append(make(ctx, 'hr')); return;
      case 'pre': target.append(pre(el, ctx)); return;
      case 'blockquote': {
        const quote = make(ctx, 'blockquote');
        blocks(el, quote, ctx);
        if (quote.childNodes.length) target.append(quote);
        return;
      }
      case 'ul': case 'ol': {
        const out = list(el, ctx);
        if (out) target.append(out);
        return;
      }
      case 'table': table(el, target, ctx); return;
      case 'figure': {
        const v = video(el, ctx);
        if (v === null) {
          blocks(el, target, ctx);
        } else {
          const p = make(ctx, 'p');
          p.append(...v);
          target.append(p);
        }
        return;
      }
      default: blocks(el, target, ctx);
    }
  }

  // A code block: its text, with line breaks, and its language (`language-…` or `lang-…` class).
  function pre(el, ctx) {
    let text = '';
    const walk = (n) => {
      if (n.nodeType === 3) text += n.data;
      else if (n.nodeType === 1 && n.localName === 'br') text += '\n';
      else if (n.nodeType === 1 && !skipped(n)) for (const c of n.childNodes) walk(c);
    };
    walk(el);
    let lang = '';
    for (const n of [el, el.querySelector('code')]) {
      const m = n && /(?:^|\s)(?:language|lang)-([\w+#.-]+)/.exec(n.getAttribute('class') || '');
      if (m) { lang = m[1]; break; }
    }
    const out = make(ctx, 'pre', lang ? { class: 'language-' + lang } : {});
    out.append(make(ctx, 'code', {}, text));
    return out;
  }

  // A list without its empty items (icon-only links, blank bullets), or null when none is left.
  function list(el, ctx) {
    const out = make(ctx, el.localName);
    const start = parseInt(el.getAttribute('start') || '', 10);
    if (el.localName === 'ol' && !isNaN(start)) out.setAttribute('start', String(start));
    for (const li of el.children) {
      if (li.localName !== 'li' || skipped(li)) continue;
      const item = make(ctx, 'li');
      blocks(li, item, ctx);
      if (!hasVisible(item)) continue;
      tighten(item);
      out.append(item);
    }
    return out.children.length ? out : null;
  }

  function rowsOf(table) {
    const rows = [];
    const collect = (parent) => {
      for (const c of parent.children) {
        if (c.localName === 'tr') rows.push(c);
        else if (c.localName === 'thead' || c.localName === 'tbody' || c.localName === 'tfoot') collect(c);
      }
    };
    collect(table);
    return rows;
  }

  function cellsOf(row) {
    return Array.from(row.children).filter((c) => (c.localName === 'td' || c.localName === 'th') && !skipped(c));
  }

  function spanOf(cell, name) {
    const n = parseInt(cell.getAttribute(name) || '1', 10);
    return isNaN(n) ? 1 : n;
  }

  // The table as a grid: each cell at its row and column, merged cells as `merged` in the slots
  // they cover. Returns { grid, width }.
  function gridOf(rows, cellValue, merged) {
    const grid = rows.map(() => []);
    rows.forEach((row, r) => {
      let c = 0;
      for (const cell of cellsOf(row)) {
        while (grid[r][c] !== undefined) c++;
        const cols = Math.min(Math.max(spanOf(cell, 'colspan'), 1), 1000);
        let span = spanOf(cell, 'rowspan');
        if (span <= 0) span = rows.length - r;
        for (let i = 0; i < span && r + i < rows.length; i++) {
          for (let j = 0; j < cols; j++) grid[r + i][c + j] = i === 0 && j === 0 ? cellValue(cell) : merged;
        }
        c += cols;
      }
    });
    const width = Math.max(0, ...grid.map((r) => r.length));
    return { grid, width };
  }

  // Content that does not fit in one table cell line: lists, figures, images, headings, nested
  // tables, or more than one block (paragraphs, divs) side by side.
  function hasBlockContent(cell) {
    if (cell.querySelector('ul,ol,dl,figure,img,picture,table,blockquote,pre,hr,' + HEADING_SELECTOR)) return true;
    for (const b of cell.querySelectorAll(BLOCK_SELECTOR)) {
      for (const sib of b.parentNode.childNodes) {
        if (sib === b) continue;
        if (sib.nodeType === 1 && !skipped(sib) && (isBlock(sib) || sib.textContent.trim())) return true;
        if (sib.nodeType === 3 && sib.data.trim()) return true;
      }
    }
    return false;
  }

  // A table used for layout rather than data: no header cells, a single column, or cells holding
  // block content.
  function isLayoutTable(el, rows, width) {
    const header = el.querySelector(':scope > thead') ||
      rows.some((r) => cellsOf(r).some((c) => c.localName === 'th'));
    if (!header || width <= 1) return true;
    return rows.some((r) => cellsOf(r).some(hasBlockContent));
  }

  // Visible text of a node, without what is never converted.
  function visibleText(node) {
    if (node.nodeType === 3) return node.data;
    if (node.nodeType !== 1 || skipped(node)) return '';
    let s = '';
    for (const c of node.childNodes) s += visibleText(c);
    return s;
  }

  // Images and inline SVG icons in `cell`.
  function iconsIn(cell) {
    return Array.from(cell.querySelectorAll('img, svg')).filter((i) => !i.parentElement.closest('svg'));
  }

  // At most this many visible characters make a marker (✓, •, 12., a)).
  const MARKER_LENGTH = 3;
  // An icon wider or taller than this, by its attributes, is a picture rather than a marker.
  const ICON_SIZE = 64;
  // Markers that are a bullet themselves: the list item's own bullet stands for them.
  const BULLET_MARKER = /^[•·▪▫◦●○■□‣⁃∙–—*+-]$/;

  // A row's marker cell: { text } for a few characters, { icon: true } for a lone small image or
  // icon without text, else null.
  function markerOf(cell) {
    const text = visibleText(cell).replace(/\s+/g, '');
    const icons = iconsIn(cell);
    if (text) return Array.from(text).length <= MARKER_LENGTH && !icons.length ? { text } : null;
    if (icons.length !== 1) return null;
    const big = ['width', 'height'].some((a) => parseInt(icons[0].getAttribute(a) || '0', 10) > ICON_SIZE);
    return big ? null : { icon: true };
  }

  function hasContent(cell) {
    return visibleText(cell).trim() !== '' || iconsIn(cell).length > 0;
  }

  // A checklist laid out as a table: after leading title rows (one cell across the whole table),
  // each row holds a marker cell (see markerOf()), then one cell with content (others empty). At
  // least two such rows, and no header row of <th> cells (a data table with a narrow first column).
  // Returns { titles: [cell], items: [{ marker, cell }] }, or null.
  function markerTable(rows, width) {
    if (width < 2) return null;
    let i = 0;
    const titles = [];
    for (; i < rows.length; i++) {
      const cells = cellsOf(rows[i]);
      if (cells.length !== 1 || spanOf(cells[0], 'colspan') < width) break;
      titles.push(cells[0]);
    }
    const items = [];
    for (const row of rows.slice(i)) {
      const cells = cellsOf(row);
      if (cells.length < 2 || cells.every((c) => c.localName === 'th')) return null;
      const marker = markerOf(cells[0]);
      const filled = cells.slice(1).filter(hasContent);
      if (!marker || filled.length !== 1) return null;
      items.push({ marker, cell: filled[0] });
    }
    return items.length >= 2 ? { titles, items } : null;
  }

  // A marker table's caption or title row: a heading when capture.js marked it as one, else bold.
  function titleBlocks(el, target, ctx) {
    const level = markedLevel(el);
    if (level) {
      heading(el, level, target, ctx, true);
      return;
    }
    if (el.querySelector('[' + HEADING_MARK + ']')) {
      blocks(el, target, ctx);
      return;
    }
    const p = inlineOf(el, 'p', ctx);
    unbold(p);
    if (!hasVisible(p)) return;
    if (!p.querySelector('strong')) {
      const bold = make(ctx, 'strong');
      bold.append(...p.childNodes);
      p.append(bold);
    }
    target.append(p);
  }

  // A marker table as a list: numbers give an ordered list; other text markers stay at the start of
  // their item (except bullets, which the list's own bullet replaces); an icon is dropped.
  function markerList(caption, found, target, ctx) {
    if (caption) titleBlocks(caption, target, ctx);
    for (const cell of found.titles) titleBlocks(cell, target, ctx);
    const ordered = found.items.every((it) => it.marker.text && /^\d{1,9}[.)]?$/.test(it.marker.text));
    const out = make(ctx, ordered ? 'ol' : 'ul');
    if (ordered) out.setAttribute('start', String(parseInt(found.items[0].marker.text, 10)));
    for (const { marker, cell } of found.items) {
      const item = make(ctx, 'li');
      blocks(cell, item, ctx);
      if (!hasVisible(item)) continue;
      tighten(item);
      if (!ordered && marker.text && !BULLET_MARKER.test(marker.text)) {
        const first = item.firstChild;
        (first.nodeType === 1 && first.localName === 'p' ? first : item).prepend(marker.text + ' ');
      }
      out.append(item);
    }
    if (out.children.length) target.append(out);
  }

  // A marker table becomes a list (see markerList()); a data table becomes a table with a header row
  // and no merged cells (a merged cell leaves empty cells beside or below it); a layout table becomes
  // the blocks of its cells, row by row.
  function table(el, target, ctx) {
    const rows = rowsOf(el);
    const caption = el.querySelector(':scope > caption');
    const shape = gridOf(rows, () => '', '');
    const markers = markerTable(rows, shape.width);
    if (markers) {
      markerList(caption, markers, target, ctx);
      return;
    }
    if (caption) {
      const p = inlineOf(caption, 'p', ctx);
      if (hasVisible(p)) target.append(p);
    }
    if (!rows.length) return;
    if (isLayoutTable(el, rows, shape.width)) {
      for (const row of rows) {
        for (const cell of cellsOf(row)) {
          if (!markedLevel(cell) || !heading(cell, markedLevel(cell), target, ctx, true)) blocks(cell, target, ctx);
        }
      }
      return;
    }
    const { grid, width } = gridOf(rows, (cell) => cell, null);
    const out = make(ctx, 'table');
    const sections = [make(ctx, 'thead'), make(ctx, 'tbody')];
    grid.forEach((cells, r) => {
      const tr = make(ctx, 'tr');
      for (let c = 0; c < width; c++) {
        const cell = cells[c] ? inlineOf(cells[c], r === 0 ? 'th' : 'td', ctx) : make(ctx, r === 0 ? 'th' : 'td');
        // A Markdown table row is one line.
        for (const br of Array.from(cell.querySelectorAll('br'))) br.replaceWith(' ');
        tr.append(cell);
      }
      sections[r === 0 ? 0 : 1].append(tr);
    });
    out.append(...sections.filter((s) => s.children.length));
    target.append(out);
  }

  // ------------------------------------------------- leaving out the page's chrome

  // Besides the site's header, navigation and footer (see chrome.js).
  const WIDGET_ROLES = ['dialog', 'alertdialog', 'menu', 'menubar', 'toolbar', 'tablist'];
  const UI_ROLES = /^(dialog|alertdialog|menu|menubar|menuitem\w*|slider|toolbar|presentation|none|progressbar|timer|status|tooltip|button)$/;
  const UI_CLASS = /vjs-|video-js|control|player|caption|subtitle|progress|volume|playback|menu|track|modal|spinner|loading|time|duration|transcript|fullscreen|seek|poster|overlay/i;
  // Most of the text a player wrapper may hold besides its video and controls (a stray label).
  const PLAYER_TEXT_SLACK = 40;

  function looksLikePlayerUI(el) {
    if (el.localName === 'button' || el.getAttribute('aria-hidden') === 'true') return true;
    if (UI_ROLES.test((el.getAttribute('role') || '').trim().toLowerCase())) return true;
    return UI_CLASS.test(el.getAttribute('class') || '');
  }

  // Text in `el` outside its video figures and anything that looks like player controls.
  function contentText(el) {
    let n = 0;
    for (const c of el.childNodes) {
      if (c.nodeType === 3) n += c.data.replace(/\s+/g, '').length;
      else if (c.nodeType === 1 && !SKIP.has(c.localName) && !c.hasAttribute('data-pc-video') && !looksLikePlayerUI(c)) {
        n += contentText(c);
      }
    }
    return n;
  }

  // The player around a video's figure: the nearest .video-js / *player* / [data-player] ancestor,
  // else the figure's parent when it holds nothing but player controls. Never one holding headings
  // or main content.
  function playerOf(figure, body) {
    const fits = (el, slack) => !el.querySelector(HEADING_SELECTOR + ',main,article') &&
      !el.closest(HEADING_SELECTOR) && contentText(el) <= slack;
    let el = figure.parentElement;
    for (let depth = 0; el && el !== body && depth < 6; depth++, el = el.parentElement) {
      if (el.matches('.video-js, [class*="player" i], [data-player]')) return fits(el, PLAYER_TEXT_SLACK) ? el : null;
    }
    const parent = figure.parentElement;
    if (parent && parent !== body && parent.children.length > 1 && fits(parent, 0)) return parent;
    return null;
  }

  // Drops each video's player controls, menus, settings dialogs and repeated poster image: the
  // player becomes the video's figure.
  function prunePlayers(body) {
    for (const figure of Array.from(body.querySelectorAll('figure[data-pc-video]'))) {
      if (!figure.isConnected) continue;
      const player = playerOf(figure, body);
      if (player) player.replaceWith(...player.querySelectorAll('figure[data-pc-video]'));
    }
  }

  // ------------------------------------------------- tab widgets
  // The same pairing as capture.js, for HTML that capture.js did not mark.

  const TABS = '[role="tab"], a[href^="#"], [data-toggle="tab"], [data-toggle="pill"], ' +
    '[data-bs-toggle="tab"], [data-bs-toggle="pill"]';

  // A class naming a tab list ("nav-tabs", "tabs", "tab-list", "c-tabs__nav"), not its panels or items.
  function hasTabListClass(el) {
    return (el.getAttribute('class') || '').split(/\s+/).some((t) =>
      /^([\w-]*[-_])?(tabs|tab-?list|tab-?bar|tab-?nav)([-_][\w-]*)?$/i.test(t) &&
      !/content|pane|panel|title|item|link/i.test(t));
  }

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
      const p = id ? root.ownerDocument.getElementById(id) : null;
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

  // [{ list, tabs: [{ tab, panel, title }] }]: see tabGroups() in capture.js.
  function tabGroups(root) {
    const groups = new Map();
    for (const tab of root.querySelectorAll(TABS)) {
      if (tab.hasAttribute('aria-expanded')) continue;
      const toggle = tab.getAttribute('data-toggle') || tab.getAttribute('data-bs-toggle') || '';
      const strong = tab.getAttribute('role') === 'tab' || /^(tab|pill)$/.test(toggle);
      let list = tabListOf(tab, root);
      if (!list && !strong) continue;
      if (!list) list = tab.parentElement.localName === 'li' ? tab.parentElement.parentElement : tab.parentElement;
      if (!groups.has(list)) groups.set(list, { list, tabs: [] });
      const title = tab.textContent.replace(/\s+/g, ' ').trim() || (tab.getAttribute('aria-label') || '').trim();
      groups.get(list).tabs.push({ tab, panel: panelOfTab(tab, root), title, strong });
    }
    return Array.from(groups.values()).filter((g) => {
      const paired = g.tabs.filter((t) => t.panel).length;
      return paired >= (g.tabs.some((t) => t.strong) ? 1 : 2);
    });
  }

  // Marks the tab panels and bars capture.js did not mark, puts panels that sit side by side in tab
  // order, and drops the bars: each panel comes out under its title (see block()).
  function tabs(body) {
    const doc = body.ownerDocument;
    for (const g of tabGroups(body)) {
      const paired = g.tabs.filter((t) => t.panel);
      const panels = paired.map((t) => t.panel);
      for (const t of paired) if (t.title && !t.panel.hasAttribute(TAB_TITLE)) t.panel.setAttribute(TAB_TITLE, t.title);
      const bars = panels.some((p) => g.list.contains(p)) ? g.tabs.map((t) => t.tab) : [g.list];
      for (const bar of bars) bar.setAttribute(TAB_BAR, '');
      const parent = panels[0].parentNode;
      if (new Set(panels).size === panels.length && panels.every((p) => p.parentNode === parent)) {
        const slots = panels.map((p) => parent.insertBefore(doc.createComment(''), p));
        slots.sort((a, b) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
        slots.forEach((slot, i) => slot.replaceWith(panels[i]));
      }
    }
    for (const bar of Array.from(body.querySelectorAll('[' + TAB_BAR + ']'))) bar.remove();
  }

  function prune(body) {
    tabs(body);
    prunePlayers(body);
    global.PageCaptureChrome.remove(body, WIDGET_ROLES);
    // Labels of form controls, which are never converted.
    for (const el of Array.from(body.querySelectorAll('label'))) {
      if (el.hasAttribute('for') || el.querySelector('input, select, textarea')) el.remove();
    }
  }

  // Collapses white space the way the page shows it: each run becomes one space, and a space at the
  // start of a block, after a line break or right after another space (also across elements, as in
  // `a <b> b</b>`) goes. MarkItDown keeps the line breaks of text and writes the space around an
  // emphasis outside it, so without this a source line break or a doubled space would reach the
  // Markdown. Code is left as it is (inline code was made one line by inline()).
  function collapseSpaces(root) {
    let afterSpace = true;
    const walk = (node) => {
      for (const c of Array.from(node.childNodes)) {
        if (c.nodeType === 3) {
          let text = c.data.replace(/[ \t\n\r\f]+/g, ' ');
          if (afterSpace) text = text.replace(/^ /, '');
          if (text) afterSpace = text.endsWith(' ');
          c.data = text;
        } else if (c.nodeType === 1) {
          const name = c.localName;
          if (name === 'pre' || name === 'code' || name === 'img') {
            afterSpace = name === 'pre';
            continue;
          }
          const breaks = name === 'br' || BLOCK.has(name);
          if (breaks) afterSpace = true;
          walk(c);
          if (breaks) afterSpace = true;
        }
      }
    };
    walk(root);
  }

  function semanticHTML(html, images, videos) {
    const doc = new DOMParser().parseFromString('<!doctype html><html><body>' + html + '</body></html>', 'text/html');
    const ctx = { doc, images: images || {}, videos: videos || {}, heading: 0 };
    prune(doc.body);
    const out = make(ctx, 'div');
    blocks(doc.body, out, ctx);
    collapseSpaces(out);
    return out.innerHTML;
  }

  global.PageCaptureMarkdown = Object.freeze({ semanticHTML });
})(globalThis);
