// PageCaptureMarkdown: converts a captured HTML fragment to Markdown.
// Parses with DOMParser (inert: no scripts run, no images load), so it needs a DOM but no network.
//
//   PageCaptureMarkdown.convert(html, images) -> string
//     images: { "<absolute image URL>": "images/<file>" } for the images that downloaded; any other
//     image keeps its remote URL.
//   videos: { "<N>": { href, title, poster?, note? } } for the `<figure data-pc-video="N">` that
//     capture.js left for each video: the figure becomes its preview image (`poster`, else the
//     figure's own image) or caption, linking to `href`, then the italic `note` if there is one.
//     Figures without an entry keep their image and caption.
//
// The Markdown keeps the content and its structure, not the page's chrome: video player controls,
// site navigation, headers and footers, dialogs, menus and empty bullets are left out (see prune()),
// layout tables are unwrapped into their blocks, tables of marked rows (a ✓, a number or an icon, then
// the text) become lists (see markerTable()), expanded accordion headers become headings, each tab
// widget becomes its panels, each under its tab's title (see tabs()), and elements capture.js found
// styled as headings (`data-pc-heading="N"`) become headings of level N, kept within 2-6.
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
  // Hard line break placeholder inside inline runs.
  const BR = '';

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

  function escapeText(s) {
    return s.replace(/[\\`*_[\]]/g, '\\$&').replace(/<(?=[A-Za-z/!?])/g, '\\<');
  }

  // Escapes characters that would start a Markdown block at the beginning of a line.
  function escapeLineStart(s) {
    return s.replace(/^(\s*)(#{1,6}\s|>|[-+]\s)/gm, '$1\\$2').replace(/^(\s*\d+)([.)]\s)/gm, '$1\\$2');
  }

  // Percent-encodes one path segment fully, like encodeURIComponent plus the characters it leaves
  // that Markdown or URLs treat specially.
  function encodeSegment(segment) {
    return encodeURIComponent(segment).replace(/[!'()*~]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
  }

  // Relative destinations of saved images and videos are encoded per path segment, so a file name
  // holding `#`, `?` or `%` is not read as a fragment, a query or an escape.
  function escapeURL(url) {
    if (/^(images|videos)\//.test(url)) return url.split('/').map(encodeSegment).join('/');
    return url.replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');
  }

  // A captured video's figure as one line, or null when it has no entry in `videos`.
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
    const target = '(' + escapeURL(v.href) + ')';
    let md = poster
      ? '[![' + label.replace(/[[\]\\]/g, '\\$&') + '](' + escapeURL(poster) + ')]' + target
      : '[' + escapeText(label) + ']' + target;
    if (v.note) md += ' *(' + escapeText(v.note.replace(/\s+/g, ' ').trim()) + ')*';
    return md;
  }

  // Moves surrounding whitespace outside a delimiter pair: "<b> x </b>" -> " **x** ".
  function wrap(content, mark) {
    const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(content);
    if (!m[2]) return content;
    return m[1] + mark + m[2] + mark + m[3];
  }

  function codeSpan(text) {
    const runs = text.match(/`+/g) || [];
    const fence = '`'.repeat(runs.reduce((n, r) => Math.max(n, r.length), 0) + 1);
    const pad = /^`|`$/.test(text) ? ' ' : '';
    return fence + pad + text + pad + fence;
  }

  // Inline Markdown for a node and its descendants. Block descendants are flattened with spaces.
  function inline(node, ctx) {
    if (node.nodeType === 3) return escapeText(node.data.replace(/[ \t\n\r\f]+/g, ' '));
    if (node.nodeType !== 1 || skipped(node)) return '';
    const tag = node.localName;
    const children = () => {
      let s = '';
      for (const c of node.childNodes) s += inline(c, ctx);
      return s;
    };
    switch (tag) {
      case 'br': return BR;
      case 'img': {
        const src = node.getAttribute('src');
        if (!src) return '';
        const alt = (node.getAttribute('alt') || '').replace(/\s+/g, ' ').trim().replace(/[[\]\\]/g, '\\$&');
        return '![' + alt + '](' + escapeURL(ctx.images[src] || src) + ')';
      }
      case 'strong': case 'b': return wrap(children(), '**');
      case 'em': case 'i': case 'cite': case 'dfn': return wrap(children(), '*');
      case 'del': case 's': case 'strike': return wrap(children(), '~~');
      case 'code': case 'kbd': case 'samp': case 'tt': {
        const text = node.textContent.replace(/[ \t\n\r\f]+/g, ' ');
        return text.trim() ? codeSpan(text) : text;
      }
      case 'a': {
        const text = children();
        const href = (node.getAttribute('href') || '').trim();
        if (!href || /^javascript:/i.test(href)) return text;
        const flat = text.replace(new RegExp(BR, 'g'), ' ');
        const label = clean(flat);
        if (!label) return '';
        const m = /^(\s*)[\s\S]*?(\s*)$/.exec(flat);
        return m[1] + '[' + label + '](' + escapeURL(href) + ')' + m[2];
      }
      case 'figure': {
        const v = video(node, ctx);
        if (v !== null) return ' ' + v + ' ';
        return ' ' + children() + ' ';
      }
      default: {
        const s = children();
        return isBlock(node) ? ' ' + s + ' ' : s;
      }
    }
  }

  // Tidies an inline run into one block's text: collapses spaces and turns placeholders into hard breaks.
  function clean(s) {
    return s
      .replace(/ {2,}/g, ' ')
      .replace(new RegExp(' *' + BR + ' *', 'g'), BR)
      .replace(new RegExp('^[\\s' + BR + ']+|[\\s' + BR + ']+$', 'g'), '')
      .replace(new RegExp(BR, 'g'), '  \n');
  }

  // A node's whole content as one line of inline Markdown (headings, table cells, captions).
  function inlineText(node, ctx) {
    let s = '';
    for (const c of node.childNodes) s += inline(c, ctx);
    return clean(s);
  }

  // Block-level Markdown chunks for a container's children: inline runs become paragraphs.
  function blocks(parent, ctx) {
    const out = [];
    let run = '';
    const flush = () => {
      const text = escapeLineStart(clean(run));
      if (text) out.push(text);
      run = '';
    };
    for (const child of parent.childNodes) {
      if (skipped(child)) continue;
      if (isBlock(child)) {
        flush();
        for (const b of block(child, ctx)) if (b) out.push(b);
      } else if (wrapsBlocks(child)) {
        flush();
        for (const b of blocks(child, ctx)) out.push(b);
      } else {
        run += inline(child, ctx);
      }
    }
    flush();
    return out;
  }

  function indent(text, first, rest) {
    return text.split('\n').map((line, i) => (i === 0 ? first : line ? rest : '') + line).join('\n');
  }

  // Accordion headers and tab titles sit one level below the section they are in, so their panels
  // read as its subsections.
  function subsectionLevel(ctx) {
    return ctx.heading ? Math.min(6, Math.max(3, ctx.heading + 1)) : 4;
  }

  // A tab panel comes out under its tab's title, unless it is empty.
  function block(el, ctx) {
    const title = el.getAttribute(TAB_TITLE);
    if (title === null) return content(el, ctx);
    const heading = escapeText(title.replace(/\s+/g, ' ').trim());
    const body = content(el, ctx);
    return heading && body.length ? ['#'.repeat(subsectionLevel(ctx)) + ' ' + heading, ...body] : body;
  }

  // The level capture.js marked `el` with, kept within 2-6, or 0.
  function markedLevel(el) {
    const n = parseInt(el.getAttribute(HEADING_MARK), 10);
    return isNaN(n) ? 0 : Math.min(6, Math.max(2, n));
  }

  // Inline Markdown without the bold around all of it, as when the page makes a whole heading bold.
  function unbold(text) {
    const m = /^\*\*([\s\S]*)\*\*$/.exec(text);
    return m && !m[1].includes('**') ? m[1] : text;
  }

  // `el` as a heading line at `level`, or null when it has no text.
  function headingLine(el, level, ctx) {
    const text = unbold(inlineText(el, ctx).replace(/ *\n */g, ' '));
    return text ? '#'.repeat(level) + ' ' + text : null;
  }

  function content(el, ctx) {
    const tag = el.localName;
    if (isAccordionHeader(el)) {
      const text = inlineText(el, ctx).replace(/ *\n */g, ' ');
      return text ? ['#'.repeat(subsectionLevel(ctx)) + ' ' + text] : [];
    }
    if (markedLevel(el) && !/^(h[1-6]|table|ul|ol|pre|blockquote)$/.test(tag)) {
      const line = headingLine(el, markedLevel(el), ctx);
      // Like a real heading, it is the section that accordion headers and tab titles go below.
      if (line && !el.closest('[data-pc-expanded], details, [' + TAB_TITLE + ']')) ctx.heading = markedLevel(el);
      return line ? [line] : [];
    }
    switch (tag) {
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': {
        const text = inlineText(el, ctx).replace(/ *\n */g, ' ');
        // Headings inside panels do not move the level of the accordion headers around them.
        if (text && !el.closest('[data-pc-expanded], details, [' + TAB_TITLE + ']')) ctx.heading = +tag[1];
        return text ? ['#'.repeat(+tag[1]) + ' ' + text] : [];
      }
      case 'hr': return ['---'];
      case 'pre': return [pre(el)];
      case 'blockquote': {
        const body = blocks(el, ctx).join('\n\n');
        return body ? [body.split('\n').map((l) => (l ? '> ' + l : '>')).join('\n')] : [];
      }
      case 'ul': case 'ol': return [list(el, ctx)];
      case 'table': return table(el, ctx);
      case 'figure': {
        const v = video(el, ctx);
        return v !== null ? [v] : blocks(el, ctx);
      }
      default: return blocks(el, ctx);
    }
  }

  function pre(el) {
    let text = '';
    const walk = (n) => {
      if (n.nodeType === 3) text += n.data;
      else if (n.nodeType === 1 && n.localName === 'br') text += '\n';
      else if (n.nodeType === 1 && !skipped(n)) for (const c of n.childNodes) walk(c);
    };
    walk(el);
    text = text.replace(/^\n/, '').replace(/\n$/, '');
    let lang = '';
    for (const n of [el, el.querySelector('code')]) {
      const m = n && /(?:^|\s)(?:language|lang)-([\w+#.-]+)/.exec(n.getAttribute('class') || '');
      if (m) { lang = m[1]; break; }
    }
    const runs = text.match(/^`{3,}/gm) || [];
    const fence = '`'.repeat(Math.max(3, ...runs.map((r) => r.length + 1)));
    return fence + lang + '\n' + text + '\n' + fence;
  }

  function list(el, ctx) {
    const ordered = el.localName === 'ol';
    let n = ordered ? parseInt(el.getAttribute('start') || '1', 10) : 1;
    if (isNaN(n)) n = 1;
    const items = [];
    let loose = false;
    for (const li of el.children) {
      if (li.localName !== 'li' || skipped(li)) continue;
      const marker = ordered ? n++ + '. ' : '- ';
      const hasParagraphs = Array.from(li.children).some((c) => c.localName === 'p');
      loose = loose || hasParagraphs;
      const body = blocks(li, ctx).join(hasParagraphs ? '\n\n' : '\n');
      // Icon-only links and empty items would be bare bullets.
      if (!body.trim()) continue;
      items.push(indent(body, marker, ' '.repeat(marker.length)));
    }
    return items.join(loose ? '\n\n' : '\n');
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
  function titleBlocks(el, ctx) {
    const level = markedLevel(el);
    if (level) {
      const line = headingLine(el, level, ctx);
      return line ? [line] : [];
    }
    if (el.querySelector('[' + HEADING_MARK + ']')) return blocks(el, ctx);
    const text = unbold(inlineText(el, ctx).replace(/ *\n */g, ' '));
    if (!text) return [];
    return [text.includes('**') ? escapeLineStart(text) : '**' + text + '**'];
  }

  // A marker table as a list: numbers give an ordered list; other text markers stay at the start of
  // their item (except bullets, which the list's own bullet replaces); an icon is dropped.
  function markerList(caption, found, ctx) {
    const out = caption ? titleBlocks(caption, ctx) : [];
    for (const cell of found.titles) out.push(...titleBlocks(cell, ctx));
    const ordered = found.items.every((it) => it.marker.text && /^\d{1,9}[.)]?$/.test(it.marker.text));
    const items = [];
    let loose = false;
    for (const { marker, cell } of found.items) {
      const body = blocks(cell, ctx);
      if (!body.length) continue;
      loose = loose || body.length > 1;
      let first, rest;
      if (ordered) {
        first = parseInt(marker.text, 10) + '. ';
        rest = ' '.repeat(first.length);
      } else {
        const kept = marker.text && !BULLET_MARKER.test(marker.text);
        first = '- ' + (kept ? escapeLineStart(escapeText(marker.text) + ' ') : '');
        rest = '  ';
      }
      items.push(indent(body.join('\n\n'), first, rest));
    }
    if (items.length) out.push(items.join(loose ? '\n\n' : '\n'));
    return out;
  }

  // A marker table becomes a list (see markerList()); a data table becomes a GFM table (a merged cell
  // leaves empty cells beside or below it); a layout table becomes the blocks of its cells, row by row.
  function table(el, ctx) {
    const rows = rowsOf(el);
    const caption = el.querySelector(':scope > caption');
    const shape = gridOf(rows, () => '', '');
    const markers = markerTable(rows, shape.width);
    if (markers) return markerList(caption, markers, ctx);
    const captionText = caption ? inlineText(caption, ctx) : '';
    const out = captionText ? [escapeLineStart(captionText)] : [];
    if (!rows.length) return out;
    if (isLayoutTable(el, rows, shape.width)) {
      for (const row of rows) {
        for (const cell of cellsOf(row)) {
          const line = markedLevel(cell) ? headingLine(cell, markedLevel(cell), ctx) : null;
          if (line) out.push(line); else out.push(...blocks(cell, ctx));
        }
      }
      return out;
    }
    const text = (c) => inlineText(c, ctx).replace(/\s*\n\s*/g, ' ').replace(/\|/g, '\\|');
    const { grid, width } = gridOf(rows, text, '');
    const line = (cells) => {
      const full = Array.from({ length: width }, (_, i) => cells[i] || '');
      return '| ' + full.join(' | ') + ' |';
    };
    const lines = [line(grid[0]), '| ' + Array(width).fill('---').join(' | ') + ' |'];
    for (const r of grid.slice(1)) lines.push(line(r));
    out.push(lines.join('\n'));
    return out;
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

  function convert(html, images, videos) {
    const doc = new DOMParser().parseFromString('<!doctype html><html><body>' + html + '</body></html>', 'text/html');
    const ctx = { images: images || {}, videos: videos || {}, heading: 0 };
    prune(doc.body);
    const text = blocks(doc.body, ctx).join('\n\n');
    return text.replace(/^[ \t]+$/gm, '').replace(/[ \t]+$/gm, (m, offset, s) => (m === '  ' && s[offset + 2] === '\n' ? m : ''))
      .replace(/\n{3,}/g, '\n\n').trim() + '\n';
  }

  global.PageCaptureMarkdown = Object.freeze({ convert });
})(globalThis);
