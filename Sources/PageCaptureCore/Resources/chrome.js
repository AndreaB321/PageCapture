// PageCaptureChrome: the page's chrome in a captured fragment (what belongs to the site, not to the
// content), left out of the Markdown (markdown.js) and of the HTML file (HTMLExporter).
//
//   PageCaptureChrome.remove(body, widgetRoles)
//     Removes from `body`: the site header, navigation and footer outside the article, and elements
//     with one of `widgetRoles` (dialogs, menus, toolbars...), unless together they hold more than half
//     of the text; then subtrees hidden from assistive technology, with the same limit; then skip
//     links. Never anything holding a captured video, nor an expanded panel or tab panel where noted.
//   PageCaptureChrome.NOT_TEXT: elements whose text is never content (scripts, styles, controls...).
(function (global) {
  'use strict';
  if (global.PageCaptureChrome) return;

  const NOT_TEXT = new Set(['script', 'style', 'noscript', 'template', 'head', 'title', 'meta', 'link', 'base',
    'iframe', 'frame', 'object', 'embed', 'svg', 'canvas', 'video', 'audio', 'source', 'track', 'map',
    'input', 'select', 'textarea', 'button', 'option', 'datalist', 'dialog']);
  // A tab panel's tab title, as capture.js marks it.
  const TAB_TITLE = 'data-pc-tab-title';
  const LANDMARK_ROLES = new Set(['navigation', 'contentinfo', 'banner']);

  // Visible characters of text, not counting what is never content.
  function textLength(node) {
    if (node.nodeType === 3) return node.data.replace(/\s+/g, '').length;
    if (node.nodeType !== 1 || NOT_TEXT.has(node.localName)) return 0;
    let n = 0;
    for (const c of node.childNodes) n += textLength(c);
    return n;
  }

  // Elements of the site rather than the content: site header, navigation and footer outside the
  // article, and elements with one of `widgetRoles` (unless they hold accordion panels; a tab list
  // unless it holds tab panels). Never one holding a captured video.
  function chrome(body, widgetRoles) {
    const out = [];
    for (const el of body.querySelectorAll('nav, header, footer, [role]')) {
      if (el.querySelector('[data-pc-video]')) continue;
      const tag = el.localName;
      const role = (el.getAttribute('role') || '').trim().toLowerCase();
      const inContent = (sel) => el.parentElement && el.parentElement.closest(sel) !== null;
      if (tag === 'nav' || role === 'navigation') {
        if (!inContent('article, main, [role="main"], [role="article"]')) out.push(el);
      } else if (LANDMARK_ROLES.has(role)) {
        out.push(el);
      } else if (tag === 'header' || tag === 'footer') {
        // As in HTML: only a header/footer outside sectioning content is the page's banner/footer.
        if (!inContent('article, aside, main, nav, section, [role="main"], [role="article"], [role="region"]')) out.push(el);
      } else if (widgetRoles.has(role)) {
        if (el.querySelector('[data-pc-expanded]')) continue;
        if (role === 'tablist' && el.querySelector('[aria-expanded], [role="tabpanel"]')) continue;
        out.push(el);
      }
    }
    return out;
  }

  // Subtrees hidden from assistive technology, unless they hold an expanded panel or a video (an
  // accordion often marks a closed panel aria-hidden; capture.js kept it as seen open).
  function ariaHidden(body) {
    const kept = '[data-pc-expanded], [' + TAB_TITLE + ']';
    return Array.from(body.querySelectorAll('[aria-hidden="true"]'))
      .filter((el) => !el.matches(kept) && !el.querySelector(kept + ', [data-pc-video]'));
  }

  // Removes `els` unless that would take more than half of the fragment's text: a page that wraps its
  // content in a header or nav keeps it.
  function removeUnlessMostOfText(body, els) {
    const outer = els.filter((el) => !els.some((o) => o !== el && o.contains(el)));
    const removed = outer.reduce((n, el) => n + textLength(el), 0);
    if (removed > textLength(body) / 2) return;
    for (const el of outer) el.remove();
  }

  function remove(body, widgetRoles) {
    removeUnlessMostOfText(body, chrome(body, new Set(widgetRoles)));
    removeUnlessMostOfText(body, ariaHidden(body));
    for (const el of Array.from(body.querySelectorAll('a[href^="#"]'))) {
      if (/^\s*skip\b/i.test(el.textContent)) el.remove();
    }
  }

  global.PageCaptureChrome = Object.freeze({ remove, NOT_TEXT });
})(globalThis);
