// PageCaptureMerge: pure merge/dedup of DOM snapshots and serialisation to HTML.
// No DOM access, so it runs both in the page (PageCapture content world) and in JavaScriptCore tests.
//
// Snapshot node shapes (built by capture.js from the live DOM):
//   element: { id, tag, attrs: [[name, value], ...], children: [node, ...], keepChildren?: true }
//   text:    { id, text }
// `id` identifies a live DOM node across snapshots of one capture.
//
// The accumulated tree uses the same shapes; merge() mutates and returns it.
(function (global) {
  'use strict';
  if (global.PageCaptureMerge) return;

  const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
    'param', 'source', 'track', 'wbr']);
  const RAW_TEXT = new Set(['style', 'script', 'xmp', 'iframe', 'noembed', 'noframes', 'plaintext']);

  function hash(h, mul, s) {
    for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), mul) >>> 0;
    return h;
  }

  function digest(s) {
    return hash(0x811c9dc5, 16777619, s).toString(36) + ':' + hash(0x9747b28c, 0x5bd1e995, s).toString(36);
  }

  // Content signature of a subtree, ignoring node identity. Memoised on the node as `sig`.
  function sign(node) {
    if (node.sig !== undefined) return node.sig;
    if ('text' in node) {
      node.sig = digest('#' + node.text);
    } else {
      const parts = ['<' + node.tag];
      for (const [k, v] of node.attrs) parts.push(k + '=' + v);
      for (const c of node.children) parts.push(sign(c));
      node.sig = digest(parts.join('\u0000'));
    }
    return node.sig;
  }

  // Merges child list `snaps` (current snapshot) into `list` (accumulated records).
  //  - a snapshot node with a known id updates its record in place (lazy content, attribute changes);
  //  - a new element whose content equals an element record that is no longer in the page is the same
  //    content re-rendered (virtualised or re-mounted lists): it takes over that record instead of
  //    duplicating. Only when that keeps the order: the record must come after the last matched one,
  //    and the previous element in the snapshot must have matched too (or be absent), so a new
  //    separator after new rows is new content, not an earlier separator re-rendered;
  //  - other new nodes are inserted in snapshot order: before the next record still in the page after
  //    their predecessor, so records the page has removed keep their place;
  //  - element records absent from the snapshot are kept; text records absent from it are dropped,
  //    because this element is in the page and its text shows the live state (a ticking clock).
  // `stats.added` counts new elements only.
  // Returns the new list.
  function mergeChildren(list, snaps, stats) {
    const present = new Set();
    for (const s of snaps) present.add(s.id);
    const byId = new Map();
    const index = new Map();
    for (let i = 0; i < list.length; i++) {
      byId.set(list[i].id, list[i]);
      index.set(list[i], i);
    }

    let absentBySig = null;
    const used = new Set();
    const matches = new Array(snaps.length);
    let last = -1; // index of the last matched record
    let inOrder = true; // no element seen yet, or the last element seen matched a record
    for (let i = 0; i < snaps.length; i++) {
      const s = snaps[i];
      const isText = 'text' in s;
      let r = byId.get(s.id);
      if (!r && !isText && inOrder) {
        if (!absentBySig) {
          absentBySig = new Map();
          for (const rec of list) {
            if ('text' in rec || present.has(rec.id)) continue;
            const key = sign(rec);
            if (!absentBySig.has(key)) absentBySig.set(key, []);
            absentBySig.get(key).push(rec);
          }
        }
        const bucket = absentBySig.get(sign(s));
        if (bucket) r = bucket.find((c) => !used.has(c) && index.get(c) > last);
        if (r) r.id = s.id; // the twin is now this live node
      }
      if (r) {
        used.add(r);
        last = index.get(r);
      }
      if (!isText) inOrder = !!r;
      matches[i] = r || null;
    }

    // For each record, the next record (at or after it) that is still in the page.
    const nextPresent = new Array(list.length + 1);
    nextPresent[list.length] = null;
    for (let i = list.length - 1; i >= 0; i--) {
      nextPresent[i] = present.has(list[i].id) ? list[i] : nextPresent[i + 1];
    }

    const END = {};
    const before = new Map(); // record (or END) -> new nodes to insert before it
    let pending = []; // new nodes seen before the first match
    let anchor = -1;
    for (let i = 0; i < snaps.length; i++) {
      const r = matches[i];
      if (r) {
        const k = index.get(r);
        if (anchor < 0 && pending.length) {
          before.set(r, (before.get(r) || []).concat(pending));
          pending = [];
        }
        anchor = k;
        continue;
      }
      const s = snaps[i];
      sign(s);
      if (!('text' in s)) stats.added++;
      if (anchor < 0) { pending.push(s); continue; }
      const key = nextPresent[anchor + 1] || END;
      if (!before.has(key)) before.set(key, []);
      before.get(key).push(s);
    }
    if (pending.length) before.set(END, (before.get(END) || []).concat(pending));

    const out = [];
    for (const r of list) {
      const inserted = before.get(r);
      if (inserted) for (const n of inserted) out.push(n);
      if ('text' in r && !present.has(r.id)) continue;
      out.push(r);
    }
    const tail = before.get(END);
    if (tail) for (const n of tail) out.push(n);

    for (let i = 0; i < snaps.length; i++) {
      if (matches[i]) mergeNode(matches[i], snaps[i], stats);
    }
    return out;
  }

  // A snapshot element with `keepChildren` (a collapsed panel whose content the page may have
  // removed) updates the record's attributes only.
  function mergeNode(record, snap, stats) {
    if ('text' in snap) {
      record.sig = sign(snap);
      record.text = snap.text;
      return;
    }
    record.tag = snap.tag;
    record.attrs = snap.attrs;
    if (snap.keepChildren) {
      record.sig = undefined;
      sign(record);
      return;
    }
    record.sig = sign(snap);
    record.children = mergeChildren(record.children, snap.children, stats);
  }

  // Merges snapshot `snap` of the capture root into `tree` (null for the first snapshot).
  // Returns { tree, added } where `added` counts elements that were new to the tree.
  function merge(tree, snap) {
    sign(snap);
    if (!tree) {
      const added = snap.children ? snap.children.filter((c) => !('text' in c)).length : 0;
      return { tree: snap, added };
    }
    const stats = { added: 0 };
    tree.id = snap.id;
    mergeNode(tree, snap, stats);
    return { tree, added: stats.added };
  }

  function escapeText(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/ /g, '&nbsp;');
  }

  function escapeAttr(s) {
    return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/ /g, '&nbsp;');
  }

  function write(node, out, images, seen, raw) {
    if ('text' in node) {
      out.push(raw ? node.text : escapeText(node.text));
      return;
    }
    out.push('<', node.tag);
    for (const [k, v] of node.attrs) out.push(' ', k, '="', escapeAttr(v), '"');
    out.push('>');
    if (node.tag === 'img') {
      const src = node.attrs.find(([k]) => k === 'src');
      if (src && src[1] && !seen.has(src[1])) {
        seen.add(src[1]);
        images.push(src[1]);
      }
    }
    if (VOID.has(node.tag)) return;
    const childRaw = RAW_TEXT.has(node.tag);
    for (const c of node.children) write(c, out, images, seen, childRaw);
    out.push('</', node.tag, '>');
  }

  // Serialises the root's children. Returns { html, imageURLs } with image `src`s unique, in order.
  function serialize(tree) {
    const out = [];
    const images = [];
    const seen = new Set();
    if (tree) for (const c of tree.children) write(c, out, images, seen, false);
    return { html: out.join(''), imageURLs: images };
  }

  global.PageCaptureMerge = Object.freeze({ merge, serialize, sign });
})(globalThis);
