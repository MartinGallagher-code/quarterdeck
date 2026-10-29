// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Martin J. Gallagher
//
// quarterdeck web: the store in a browser.
//
// The page draws and asks; it never computes a figure itself.  Filters,
// sorts, statistics, groups, pivots, trends and diffs all come back from
// the server, which runs the same functions `qd stats` and `qd diff` print
// -- so a number here is always the number the terminal would give.
//
// Everything that came from a dataset (host names, column names, cell
// values) goes into the page with textContent, never as markup.
"use strict";

(function () {
  // -------------------------------------------------------------------------
  // Small helpers
  // -------------------------------------------------------------------------

  const $ = (id) => document.getElementById(id);

  function h(tag, attrs, ...kids) {
    const el = document.createElementNS(
      SVG_TAGS.has(tag) ? "http://www.w3.org/2000/svg" :
        "http://www.w3.org/1999/xhtml", tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === "text") el.textContent = v;
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (k === "class") el.setAttribute("class", v);
      else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
      else el.setAttribute(k, v === true ? "" : v);
    }
    for (const kid of kids.flat(Infinity)) {
      if (kid === null || kid === undefined || kid === false) continue;
      el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }

  const SVG_TAGS = new Set(["svg", "g", "path", "line", "rect", "circle",
    "text", "title", "polyline"]);

  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

  // The toolchain's own number style: four significant digits, fixed
  // notation, so 1.163e+06 never appears.  Formatting only -- the figures
  // themselves come from the server.
  function fmtNum(v) {
    if (v === null || v === undefined || v === "") return "";
    if (typeof v !== "number") return String(v);
    if (!isFinite(v)) return v > 0 ? "+inf" : "-inf";
    if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v);
    if (v === 0) return "0";
    const mag = Math.floor(Math.log10(Math.abs(v)));
    const dec = Math.max(0, Math.min(6, 3 - mag));
    let s = v.toFixed(dec);
    if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
    return s === "-0" ? "0" : s;
  }

  function compact(v) {
    const a = Math.abs(v);
    if (a >= 1e9) return fmtNum(v / 1e9) + "G";
    if (a >= 1e6) return fmtNum(v / 1e6) + "M";
    if (a >= 1e3) return fmtNum(v / 1e3) + "K";
    return fmtNum(v);
  }

  const BARE = /^[^\s()<>=!~"']+$/;
  function quoteVal(v) {
    if (v && BARE.test(v)) return v;
    return '"' + v.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
  }
  function quoteCol(c) { return BARE.test(c) ? c : quoteVal(c); }
  function shq(s) {
    if (s === "") return "''";
    return /^[\w@%+=:,./-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'";
  }

  const STATUS = {
    ok: "good", pass: "good", tested: "good", reporting: "good",
    warn: "warning", skipped: "warning", silent: "serious",
    timeout: "serious", "push-failed": "critical", failed: "critical",
    fail: "critical", unreachable: "critical", "no-data": "critical",
  };

  function statusEl(value) {
    const cls = STATUS[String(value).trim().toLowerCase()];
    if (!cls) return null;
    return h("span", { class: "status " + cls, title: value }, value);
  }

  // -------------------------------------------------------------------------
  // State, kept in the URL hash so a view can be bookmarked or sent on
  // -------------------------------------------------------------------------

  const S = {
    entries: [], root: "", floor: false, layout: null,
    e: null, t: null, tab: "table", where: [], sort: "", col: null,
    p: {}, info: null, rows: null, busy: 0,
  };

  const TABS = [["table", "Table"], ["group", "Group"], ["pivot", "Pivot"],
    ["trend", "Trend"], ["diff", "Diff"], ["about", "About"]];

  function readHash() {
    const q = new URLSearchParams(location.hash.slice(1));
    S.e = q.get("e") || null;
    S.t = q.get("t") || null;
    S.tab = q.get("tab") || "table";
    S.where = q.getAll("w");
    S.sort = q.get("sort") || "";
    S.col = q.get("col") || null;
    S.p = {};
    for (const [k, v] of q.entries()) if (k.startsWith("p.")) S.p[k.slice(2)] = v;
  }

  function writeHash() {
    const q = new URLSearchParams();
    if (S.e) q.set("e", S.e);
    if (S.t) q.set("t", S.t);
    if (S.tab !== "table") q.set("tab", S.tab);
    for (const w of S.where) q.append("w", w);
    if (S.sort) q.set("sort", S.sort);
    if (S.col) q.set("col", S.col);
    for (const [k, v] of Object.entries(S.p)) if (v !== "" && v != null) q.set("p." + k, v);
    const s = q.toString();
    history.replaceState(null, "", s ? "#" + s : location.pathname);
  }

  // -------------------------------------------------------------------------
  // The server
  // -------------------------------------------------------------------------

  function tableParams(extra) {
    const p = { e: S.e, where: S.where };
    if (S.t) p.t = S.t;
    return Object.assign(p, extra || {});
  }

  async function api(path, params) {
    const u = new URL(path, location.href);
    for (const [k, v] of Object.entries(params || {})) {
      if (v === null || v === undefined) continue;
      if (Array.isArray(v)) v.forEach((x) => u.searchParams.append(k, x));
      else u.searchParams.set(k, v);
    }
    S.busy++;
    document.body.style.cursor = "progress";
    try {
      const r = await fetch(u);
      let data;
      try { data = await r.json(); } catch (e) { data = { error: r.statusText }; }
      if (!r.ok) throw new Error(data.error || ("HTTP " + r.status));
      return data;
    } finally {
      if (--S.busy === 0) document.body.style.cursor = "";
    }
  }

  function exportUrl(fmt) {
    const u = new URL("/api/export", location.href);
    const p = tableParams({ format: fmt });
    if (S.sort) p.sort = S.sort;
    for (const [k, v] of Object.entries(p)) {
      if (Array.isArray(v)) v.forEach((x) => u.searchParams.append(k, x));
      else if (v != null) u.searchParams.set(k, v);
    }
    return u.toString();
  }

  function showError(err) {
    const b = clear($("banner"));
    if (!err) return;
    b.append(h("div", { class: "banner", role: "alert" },
      String(err.message || err), " ",
      h("button", { type: "button", class: "link", onclick: () => clear(b), text: "dismiss" })));
  }

  // -------------------------------------------------------------------------
  // Theme
  // -------------------------------------------------------------------------

  const THEMES = ["auto", "light", "dark"];
  function setTheme(mode) {
    if (mode === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = mode;
    $("theme").textContent = "Theme: " + mode;
    try { localStorage.setItem("qd-theme", mode); } catch (e) { /* private window */ }
  }

  // -------------------------------------------------------------------------
  // The runs in the store
  // -------------------------------------------------------------------------

  async function loadEntries() {
    const d = await api("/api/entries");
    S.entries = d.entries;
    S.root = d.root;
    S.floor = d.floor;
    S.layout = d.layout;
    $("root").textContent = d.root;
    renderEntries();
  }

  function entryById(id) { return S.entries.find((e) => e.id === id) || null; }

  function entryTitle(e) {
    return e.name && e.name !== e.kind ? e.name : (e.command || e.id);
  }

  function renderEntries() {
    const ol = clear($("entries"));
    const f = $("entry-filter").value.trim().toLowerCase();
    const shown = S.entries.filter((e) => !f ||
      (e.id + " " + e.name + " " + e.command).toLowerCase().includes(f));
    if (!S.entries.length) {
      ol.append(h("li", { class: "empty" }, "No runs in this store yet. ",
        h("code", { text: "qd run" }), ", ", h("code", { text: "qd do" }), " or ",
        h("code", { text: "qd import" }), " files the first."));
      return;
    }
    for (const e of shown) {
      const sub = [h("span", { class: "kind", text: e.kind })];
      sub.push(h("span", { text: e.summary }));
      if (e.created) sub.push(h("span", { text: e.created.slice(5, 16).replace("T", " ") }));
      ol.append(h("li", null, h("button", {
        type: "button", "aria-current": e.id === S.e ? "true" : "false",
        title: e.id, onclick: () => openEntry(e.id),
      }, h("span", { class: "e-title", text: entryTitle(e) }),
      h("span", { class: "e-sub" }, sub))));
    }
  }

  async function openEntry(id, keep) {
    S.e = id;
    if (!keep) {
      S.t = null; S.where = []; S.sort = ""; S.col = null; S.p = {};
      if (!["table", "about", "diff"].includes(S.tab)) S.tab = "table";
    }
    const col = S.col;
    closePanel(true);
    S.col = col;
    renderEntries();
    try {
      S.info = await api("/api/entry", { e: id });
    } catch (err) {
      showError(err);
      return;
    }
    const e = entryById(id);
    if (!S.t && e && e.tables.length) S.t = e.tables[0].name;
    renderHead();
    renderTabs();
    await renderView();
    if (S.col) openPanel(S.col);
  }

  // -------------------------------------------------------------------------
  // The entry's head: what ran, how it went, which table
  // -------------------------------------------------------------------------

  function renderHead() {
    const head = clear($("head"));
    const e = entryById(S.e);
    if (!e) return;
    const m = S.info ? S.info.meta : {};
    head.append(h("h1", { text: entryTitle(e) }));
    const meta = [h("span", { class: "mono", text: e.id }), h("span", { class: "kind", text: e.kind })];
    if (m.created) meta.push(h("span", { text: m.created.replace("T", " ").replace("Z", " UTC") }));
    if (m.parse) meta.push(h("span", { text: "parsed as " + m.parse }));
    if (m.passes > 1) meta.push(h("span", { text: m.passes + " passes, every " + m.every + "s" }));
    if (m.duration_s != null) meta.push(h("span", { text: "took " + m.duration_s + "s" }));
    if (m.rc != null) meta.push(h("span", { text: "exit " + m.rc }));
    head.append(h("div", { class: "meta" }, meta));
    if (e.command) head.append(h("pre", { class: "cmd", text: (m.ran || e.command) }));

    if (m.hosts) {
      const hs = m.hosts;
      const tiles = [tile("Hosts", hs.total, null)];
      tiles.push(tile("Answered", hs.ok || 0, "good"));
      for (const [k, cls] of [["failed", "critical"], ["unreachable", "critical"],
        ["timeout", "serious"], ["push-failed", "critical"]]) {
        if (hs[k]) tiles.push(tile(k[0].toUpperCase() + k.slice(1), hs[k], cls, k));
      }
      head.append(h("div", { class: "tiles" }, tiles));
    }

    if (e.tables.length > 1) {
      head.append(h("div", { class: "tables", role: "group", "aria-label": "Tables" },
        e.tables.map((t) => h("button", {
          type: "button", "aria-pressed": t.name === S.t ? "true" : "false",
          title: t.from || "", onclick: () => switchTable(t.name),
        }, t.name, h("span", { class: "rows", text: t.rows + " rows" })))));
    }

    const fmts = [["csv", "CSV"], ["tsv", "TSV"], ["json", "JSON"], ["ndjson", "NDJSON"],
      ["md", "Markdown"], ["overlay", "Floor-plan overlay"]];
    const sel = h("select", { "aria-label": "Export this view" },
      h("option", { value: "", text: "Export this view…" }),
      fmts.map(([v, l]) => h("option", { value: v, text: l })));
    sel.addEventListener("change", () => {
      if (sel.value) location.href = exportUrl(sel.value);
      sel.value = "";
    });
    head.append(h("div", { class: "actions" },
      h("button", { type: "button", onclick: floorPlan,
        title: S.floor ? "Paint this view on the floor plan" :
          "Write this view as a floor-plan overlay" }, "Floor plan"),
      sel));
  }

  function tile(label, value, cls, statusWord) {
    return h("div", { class: "tile" },
      h("div", { class: "label" }, cls ? h("span", { class: "status " + cls }, "") : null, label),
      h("div", { class: "value", text: String(value) }),
      statusWord && value ? h("button", { type: "button", class: "link",
        onclick: () => { S.tab = "table"; addFilter("status=" + statusWord); },
        text: "show them" }) : null);
  }

  async function floorPlan() {
    try {
      const r = await api("/api/overlay", tableParams());
      if (r.url) {
        window.open(r.url, "_blank", "noopener");
      } else {
        showError(new Error("Wrote " + r.samples + " samples (" + r.overlays.length +
          " overlays) to " + r.file + ". The floor-plan viewer is not installed here: " +
          "pip install datacenter-layout-viewer, then qd web or qd floor opens it."));
      }
    } catch (err) { showError(err); }
  }

  function switchTable(name) {
    S.t = name; S.where = []; S.sort = ""; S.col = null; S.p = {};
    closePanel(true);
    renderHead();
    renderView();
  }

  // -------------------------------------------------------------------------
  // Tabs, the filter bar, and the command that would print the same
  // -------------------------------------------------------------------------

  function renderTabs() {
    const tabs = clear($("tabs"));
    for (const [id, label] of TABS) {
      tabs.append(h("button", {
        type: "button", role: "tab", "aria-selected": id === S.tab ? "true" : "false",
        onclick: () => { S.tab = id; renderTabs(); renderView(); }, text: label,
      }));
    }
  }

  function renderFilterbar(count) {
    const bar = clear($("filterbar"));
    if (S.tab === "about") return;
    const input = h("input", {
      type: "text", "aria-label": "Filter rows",
      placeholder: "Filter: status!=ok   mbps<900   host~^wr01   rtt_p99=",
    });
    const form = h("form", { onsubmit: (ev) => {
      ev.preventDefault();
      if (input.value.trim()) addFilter(input.value.trim());
    } }, input, h("button", { type: "submit", text: "Add" }));
    const chips = h("div", { class: "chips" }, S.where.map((w, i) =>
      h("span", { class: "chip" }, w, h("button", {
        type: "button", "aria-label": "Remove filter " + w,
        onclick: () => { S.where.splice(i, 1); refresh(); }, text: "×",
      }))));
    bar.append(form, chips);
    if (S.where.length > 1) bar.append(h("button", { type: "button", class: "link",
      onclick: () => { S.where = []; refresh(); }, text: "clear all" }));
    if (count) bar.append(h("span", { class: "count", text: count }));
  }

  function renderCli(cmd) {
    const el = clear($("cli"));
    if (!cmd) return;
    const copy = h("button", { type: "button", class: "link", text: "copy" });
    copy.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(cmd); copy.textContent = "copied"; }
      catch (e) { copy.textContent = "select it to copy"; }
    });
    el.append(h("span", { text: "same in a terminal" }), h("code", { text: cmd, title: cmd }), copy);
  }

  function refArg() {
    const e = entryById(S.e);
    return S.e + (S.t && e && e.tables.length > 1 && S.t !== e.tables[0].name ? ":" + S.t : "");
  }

  function whereArgs() { return S.where.map((w) => "--where " + shq(w)).join(" "); }

  function cli(verb, rest) {
    return ["qd", verb, shq(refArg()), rest || "", whereArgs()].filter(Boolean).join(" ")
      .replace(/\s+/g, " ").trim();
  }

  async function addFilter(expr) {
    S.where.push(expr);
    await refresh();
  }

  async function refresh() {
    renderHead();
    renderTabs();
    await renderView();
    if (S.col) openPanel(S.col);
  }

  async function renderView() {
    writeHash();
    const view = $("view");
    view.style.opacity = "0.55";
    showError(null);
    try {
      if (!S.e) {
        renderFilterbar(); renderCli("");
        clear(view).append(h("p", { class: "empty", text: "Pick an entry on the left." }));
        return;
      }
      const fn = { table: viewTable, group: viewGroup, pivot: viewPivot,
        trend: viewTrend, diff: viewDiff, about: viewAbout }[S.tab] || viewTable;
      await fn(view);
    } catch (err) {
      showError(err);
    } finally {
      view.style.opacity = "";
    }
  }

  // -------------------------------------------------------------------------
  // Table
  // -------------------------------------------------------------------------

  function cellNode(value, kind) {
    const td = h("td");
    if (value === "" || value === undefined) { td.className = "blank"; td.title = "not measured"; return td; }
    if (kind === "num") td.className = "num";
    const st = statusEl(value);
    if (st) { td.append(st); return td; }
    const nl = value.indexOf("\n");
    if (nl >= 0) {
      td.append(value.slice(0, nl), h("span", { class: "more-lines",
        text: "+" + (value.split("\n").length - 1) + " lines" }));
      td.title = value.slice(0, 2000);
    } else {
      td.textContent = value;
      if (value.length > 40) td.title = value;
    }
    return td;
  }

  function sortState(col) {
    const s = S.sort;
    if (s === col || s === quoteCol(col)) return "asc";
    if (s === "-" + col || s === "-" + quoteCol(col)) return "desc";
    return "";
  }

  async function viewTable(view) {
    const params = tableParams({ offset: 0, limit: 200 });
    if (S.sort) params.sort = S.sort;
    const d = await api("/api/rows", params);
    S.rows = d;
    S.rowsKey = rowsKey();
    renderFilterbar(d.matched === d.total ? d.total + " rows" :
      d.matched + " of " + d.total + " rows");
    renderCli(cli("show", S.sort ? "--sort " + shq(S.sort) : ""));
    clear(view);
    if (!d.columns.length) {
      view.append(h("p", { class: "empty", text: "This table has no columns." }));
      return;
    }
    const thead = h("tr", null, d.columns.map((c) => {
      const st = sortState(c);
      return h("th", { class: d.kinds[c] === "num" ? "num" : null,
        "aria-current": c === S.col ? "true" : null,
        "aria-sort": st === "asc" ? "ascending" : st === "desc" ? "descending" : null },
      h("div", { class: "th" },
        h("button", { type: "button", title: "Statistics for " + c,
          onclick: () => openPanel(c), text: c }),
        h("button", { type: "button", class: "sorter",
          "aria-label": "Sort by " + c,
          onclick: () => {
            S.sort = st === "" ? c : st === "asc" ? "-" + c : "";
            renderView();
          }, text: st === "asc" ? "▲" : st === "desc" ? "▼" : "⇅" })));
    }));
    const tbody = h("tbody");
    const addRows = (rows, start) => rows.forEach((r, i) => {
      const tr = h("tr", { tabindex: "0", onclick: () => openDetail(r),
        onkeydown: (ev) => { if (ev.key === "Enter") openDetail(r); } },
      r.map((v, j) => cellNode(v, d.kinds[d.columns[j]])));
      tr.dataset.n = String(start + i);
      tbody.append(tr);
    });
    addRows(d.rows, 0);
    view.append(h("div", { class: "grid-wrap" },
      h("table", { class: "grid" }, h("thead", null, thead), tbody)));
    let shown = d.rows.length;
    const pager = h("div", { class: "pager" });
    const update = () => {
      clear(pager);
      pager.append(h("span", { text: "showing " + shown + " of " + d.matched }));
      if (shown < d.matched) {
        pager.append(h("button", { type: "button", text: "Show 200 more", onclick: async () => {
          const p = Object.assign({}, params, { offset: shown });
          const more = await api("/api/rows", p);
          addRows(more.rows, shown);
          shown += more.rows.length;
          update();
        } }));
      }
    };
    update();
    view.append(pager);
    if (d.notes && d.notes.length) {
      view.append(h("ul", { class: "notes" }, d.notes.slice(0, 12).map((n) => h("li", { text: n }))));
    }
  }

  // -------------------------------------------------------------------------
  // One row in full, with the host's raw answer
  // -------------------------------------------------------------------------

  async function openDetail(row) {
    const d = S.rows;
    const dlg = $("detail");
    clear(dlg);
    const body = h("div", { class: "d-body" });
    const dl = h("dl");
    d.columns.forEach((c, i) => {
      dl.append(h("dt", { text: c }), h("dd", { text: row[i] === "" ? "· not measured" : row[i] }));
    });
    body.append(dl);
    const hi = d.columns.indexOf("host");
    const title = hi >= 0 ? row[hi] : "row";
    dlg.append(h("div", { class: "d-head" }, h("strong", { text: title }),
      h("button", { type: "button", onclick: () => dlg.close(), text: "Close" })), body);
    if (typeof dlg.showModal === "function") dlg.showModal(); else dlg.setAttribute("open", "");
    const ci = d.columns.indexOf("capture");
    if (d.raw && (hi >= 0 || ci >= 0)) {
      const pi = d.columns.indexOf("pass");
      try {
        const raw = await api("/api/raw", tableParams({ host: hi >= 0 ? row[hi] : null,
          pass: pi >= 0 ? row[pi] : null, capture: ci >= 0 ? row[ci] : null }));
        if (raw.out !== undefined) body.append(h("h3", { text: raw.label || "Raw answer" }), h("pre", { text: raw.out || "(nothing)" }));
        if (raw.err) body.append(h("h3", { text: "stderr" }), h("pre", { text: raw.err }));
      } catch (err) { body.append(h("p", { class: "count", text: String(err.message) })); }
    }
  }

  // -------------------------------------------------------------------------
  // A column in depth: figures, histogram, values, outliers
  // -------------------------------------------------------------------------

  function closePanel(quiet) {
    $("panel").hidden = true;
    $("shell").classList.remove("with-panel");
    S.col = null;
    document.querySelectorAll(".grid th[aria-current]").forEach((th) => th.setAttribute("aria-current", "false"));
    if (!quiet) writeHash();
  }

  async function openPanel(col) {
    S.col = col;
    writeHash();
    const panel = $("panel");
    let d;
    try { d = await api("/api/column", tableParams({ c: col })); }
    catch (err) { showError(err); return; }
    clear(panel);
    panel.hidden = false;
    $("shell").classList.add("with-panel");
    document.querySelectorAll(".grid th").forEach((th) => {
      th.setAttribute("aria-current", th.textContent.replace(/[▲▼⇅]$/, "") === col ? "true" : "false");
    });
    panel.append(h("button", { type: "button", class: "close", onclick: () => closePanel(), text: "Close" }),
      h("h2", { text: d.name }),
      h("div", { class: "sub", text: [d.kind, d.unit ? "in " + d.unit : null,
        d.n + " measured", d.blank ? d.blank + " blank" : null,
        d.distinct + " distinct"].filter(Boolean).join(" · ") }));
    renderCli(cli("stats", shq(d.name)));
    const s = d.summary;
    if (s && s.n) {
      const kv = h("dl", { class: "kv" });
      for (const [k, label] of [["mean", "mean"], ["stdev", "stdev"], ["min", "min"], ["max", "max"],
        ["p05", "p05"], ["p95", "p95"], ["p25", "p25"], ["p75", "p75"], ["median", "median"], ["sum", "sum"]]) {
        kv.append(h("dt", { text: label }), h("dd", { text: fmtNum(s[k]) }));
      }
      panel.append(h("h3", { text: "Figures" }), kv);
      if (d.kind === "mixed") {
        panel.append(h("p", { class: "note", text: "Only the " + s.n + " numeric cells are in these figures." }));
      }
      if (d.hist && d.hist.length) panel.append(h("h3", { text: "Distribution" }), histogram(d.hist, d.unit));
    }
    if (d.outliers && d.outliers.n > 2) {
      const o = d.outliers;
      panel.append(h("h3", { text: "Far from the rest" }));
      panel.append(h("p", { class: "note", text: "median " + fmtNum(o.median) + ", MAD " + fmtNum(o.mad) +
        ", robust z beyond " + o.z + ", one value per " + o.per }));
      if (!o.rows.length) panel.append(h("p", { class: "note", text: "None: every " + o.per + " is close to the median." }));
      else {
        panel.append(h("ul", { class: "vals" }, o.rows.slice(0, 15).map(([k, v, rel, z, side]) =>
          h("li", null,
            h("span", { class: "v" }, h("button", { type: "button", class: "link",
              onclick: () => addFilter(quoteCol(o.per) + "=" + quoteVal(String(k))), text: String(k) })),
            h("span", { class: "n", text: fmtNum(v) + (rel != null ? "  (" + fmtNum(rel) + "% of median)" : "") +
              (z != null ? "  z " + (z > 0 ? "+" : "") + z.toFixed(1) : "  differs") })))));
      }
    }
    // For a continuous number, value counts are noise (every value once);
    // they earn their place for words, and for numbers that repeat.
    const repeats = d.top && d.top.length && d.top[0][1] > 1;
    if (d.top && d.top.length && (d.kind !== "num" || (repeats && d.distinct <= 20))) {
      const total = d.n + d.blank;
      const top = d.top[0][1];
      panel.append(h("h3", { text: d.top.length > 1 ? "Values, most common first" : "Value" }));
      if (d.top.length > 1) panel.append(h("p", { class: "note", text: d.top[0][1] + " agree on the most common; " + (total - d.top[0][1]) + " do not" }));
      panel.append(h("ul", { class: "vals" }, d.top.map(([v, n, labels, nlab]) => {
        const shown = v === "" ? "(blank)" : v.split("\n")[0] + (v.includes("\n") ? "  …" : "");
        const expr = quoteCol(d.name) + (v.includes("\n") ? "~" + quoteVal("^" + escRe(v.split("\n")[0])) :
          "=" + (v === "" ? "" : quoteVal(v)));
        const nexpr = quoteCol(d.name) + "!=" + (v === "" ? "" : quoteVal(v));
        return h("li", null,
          h("span", { class: "v", title: v.slice(0, 1000), text: shown }),
          h("span", { class: "n", text: n + "  " + fmtNum(100 * n / Math.max(1, total)) + "%" }),
          h("div", { class: "track" }, h("div", { class: "fill", style: { width: (100 * n / top) + "%" } })),
          labels.length && d.top.length > 1 ? h("span", { class: "who", text: labels.join(" ") + (nlab > labels.length ? " +" + (nlab - labels.length) : "") }) : null,
          h("span", { class: "ops" },
            h("button", { type: "button", class: "link", onclick: () => addFilter(expr), text: "keep" }),
            v.includes("\n") ? null : h("button", { type: "button", class: "link", onclick: () => addFilter(nexpr), text: "drop" })));
      })));
      if (d.more_values) panel.append(h("p", { class: "note", text: "…and " + d.more_values + " more values" }));
    }
    const btns = h("div", { class: "buttons" },
      h("button", { type: "button", onclick: () => { S.sort = d.name; S.tab = "table"; refresh(); }, text: "Sort ▲" }),
      h("button", { type: "button", onclick: () => { S.sort = "-" + d.name; S.tab = "table"; refresh(); }, text: "Sort ▼" }),
      h("button", { type: "button", onclick: () => { S.tab = "group"; S.p.by = d.name; refresh(); }, text: "Group by this" }));
    if (s && s.n) btns.append(h("button", { type: "button",
      onclick: () => { S.tab = "trend"; S.p.c = d.name; refresh(); }, text: "Over time" }));
    panel.append(btns);
  }

  function escRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

  // -------------------------------------------------------------------------
  // Charts.  Hand-drawn SVG: thin marks, hairline grid, single-hue
  // magnitude, one tooltip -- and the numbers stay in the table beside them.
  // -------------------------------------------------------------------------

  const tip = () => $("tip");

  function showTip(ev, title, rows) {
    const t = clear(tip());
    if (title) t.append(h("div", { class: "t-title", text: title }));
    for (const r of rows) {
      t.append(h("div", { class: "t-row" },
        r.color ? h("span", { class: "key", style: { background: r.color } }) : null,
        h("b", { text: r.value }), r.name ? h("span", { class: "nm", text: r.name }) : null));
    }
    t.hidden = false;
    const x = Math.min(window.innerWidth - t.offsetWidth - 12, ev.clientX + 14);
    const y = Math.min(window.innerHeight - t.offsetHeight - 12, ev.clientY + 14);
    t.style.left = Math.max(8, x) + "px";
    t.style.top = Math.max(8, y) + "px";
  }
  function hideTip() { tip().hidden = true; }

  function niceTicks(lo, hi, n) {
    if (lo === hi) { lo -= 1; hi += 1; }
    const span = hi - lo;
    const step0 = Math.pow(10, Math.floor(Math.log10(span / n)));
    const err = (span / n) / step0;
    const step = step0 * (err >= 7.5 ? 10 : err >= 3.5 ? 5 : err >= 1.5 ? 2 : 1);
    const start = Math.floor(lo / step) * step;
    const out = [];
    for (let v = start; v <= hi + step * 0.5; v += step) out.push(+v.toFixed(10));
    return out;
  }

  function histogram(bins, unit) {
    const W = 300, H = 140, L = 30, B = 22, T = 8;
    const top = Math.max(...bins.map((b) => b[2]));
    const svg = h("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": "Histogram" });
    const ticks = niceTicks(0, top, 3).filter((v) => v <= top * 1.001 && Number.isInteger(v));
    const y = (v) => T + (H - T - B) * (1 - v / top);
    for (const t of ticks) {
      svg.append(h("line", { class: "gridline", x1: L, x2: W, y1: y(t), y2: y(t) }));
      svg.append(h("text", { x: L - 4, y: y(t) + 4, "text-anchor": "end", text: compact(t) }));
    }
    const bw = (W - L) / bins.length;
    bins.forEach(([lo, hi, n], i) => {
      const w = Math.max(1, Math.min(24, bw - 2));
      const x = L + i * bw + (bw - w) / 2;
      const hgt = (H - T - B) * (n / top);
      const r = Math.min(4, w / 2, hgt);
      const yy = H - B - hgt;
      // flat at the baseline, rounded at the data end
      const d = n ? "M" + x + "," + (H - B) + "V" + (yy + r) + "Q" + x + "," + yy + " " + (x + r) + "," + yy +
        "H" + (x + w - r) + "Q" + (x + w) + "," + yy + " " + (x + w) + "," + (yy + r) + "V" + (H - B) + "Z" : "";
      const label = lo === hi ? fmtNum(lo) : fmtNum(lo) + " – " + fmtNum(hi);
      const hit = h("rect", { x: L + i * bw, y: T, width: bw, height: H - T - B, fill: "transparent" });
      const bar = n ? h("path", { class: "hist-bar", d: d }) : null;
      const g = h("g", { tabindex: "0", "aria-label": label + ": " + n }, bar, hit);
      const on = (ev) => { if (bar) bar.classList.add("hot"); showTip(ev, label + (unit ? " " + unit : ""), [{ value: String(n), name: n === 1 ? "row" : "rows" }]); };
      g.addEventListener("pointermove", on);
      g.addEventListener("focus", (ev) => on({ clientX: ev.target.getBoundingClientRect().x, clientY: ev.target.getBoundingClientRect().y }));
      g.addEventListener("pointerleave", () => { if (bar) bar.classList.remove("hot"); hideTip(); });
      g.addEventListener("blur", () => { if (bar) bar.classList.remove("hot"); hideTip(); });
      svg.append(g);
    });
    svg.append(h("line", { class: "axis", x1: L, x2: W, y1: H - B, y2: H - B }));
    const first = bins[0], last = bins[bins.length - 1];
    svg.append(h("text", { x: L, y: H - 6, text: fmtNum(first[0]) }));
    svg.append(h("text", { x: W, y: H - 6, "text-anchor": "end", text: fmtNum(last[1]) }));
    return svg;
  }

  const SERIES = ["--s1", "--s2", "--s3", "--s4", "--s5", "--s6", "--s7", "--s8"];
  function seriesColor(i) { return "var(" + SERIES[i % SERIES.length] + ")"; }

  function isEpoch(lo, hi) { return lo > 1e9 && hi < 2.2e9; }
  function fmtX(v, epoch, span, labels) {
    if (labels) {
      const l = labels[Math.round(v)];
      if (l === undefined) return "";
      return /^\d{4}-\d\d-\d\d[T ]\d\d:\d\d/.test(l) ? l.slice(5, 16).replace("T", " ") : l;
    }
    if (!epoch) return compact(v);
    const d = new Date(v * 1000);
    const iso = d.toISOString();
    return span > 2 * 86400 ? iso.slice(5, 16).replace("T", " ") : iso.slice(11, 19);
  }

  function lineChart(series, opts) {
    const W = Math.max(320, opts.width), H = 300, L = 54, R = 16, T = 12, B = 30;
    const pts = series.flatMap((s) => s.points.filter((p) => p[2] !== null));
    if (!pts.length) return h("p", { class: "empty", text: "Nothing measured to draw." });
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[2]);
    let x0 = Math.min(...xs), x1 = Math.max(...xs);
    let y0 = Math.min(...ys), y1 = Math.max(...ys);
    if (x0 === x1) { x0 -= 1; x1 += 1; }
    const yt = niceTicks(y0, y1, 5);
    y0 = Math.min(y0, yt[0]); y1 = Math.max(y1, yt[yt.length - 1]);
    if (y0 === y1) { y0 -= 1; y1 += 1; }
    const X = (v) => L + (W - L - R) * (v - x0) / (x1 - x0);
    const Y = (v) => T + (H - T - B) * (1 - (v - y0) / (y1 - y0));
    const epoch = opts.numericX && isEpoch(x0, x1);
    const svg = h("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": opts.label, style: { height: H + "px" } });
    for (const t of yt) {
      if (t < y0 || t > y1) continue;
      svg.append(h("line", { class: "gridline", x1: L, x2: W - R, y1: Y(t), y2: Y(t) }));
      svg.append(h("text", { x: L - 6, y: Y(t) + 4, "text-anchor": "end", text: compact(t) }));
    }
    svg.append(h("line", { class: "axis", x1: L, x2: W - R, y1: H - B, y2: H - B }));
    const xt = niceTicks(x0, x1, Math.max(2, Math.floor((W - L) / 110)));
    for (const t of xt) {
      if (t < x0 || t > x1) continue;
      if (epoch && !Number.isInteger(t)) continue;   // never half a second
      if (opts.labels && !Number.isInteger(t)) continue;
      svg.append(h("text", { x: X(t), y: H - 10, "text-anchor": "middle", text: fmtX(t, epoch, x1 - x0, opts.labels) }));
    }
    const many = series.length > 8;
    const paths = series.map((s, i) => {
      const p = s.points.filter((q) => q[2] !== null);
      let d = "";
      let gap = true;
      for (const q of s.points) {
        if (q[2] === null) { gap = true; continue; }
        d += (gap ? "M" : "L") + X(q[0]).toFixed(1) + "," + Y(q[2]).toFixed(1);
        gap = false;
      }
      const el = h("path", { class: "series" + (many ? " muted" : ""), d: d,
        stroke: many ? null : seriesColor(i) });
      el.dataset.i = String(i);
      svg.append(el);
      if (!many && p.length === 1) {
        svg.append(h("circle", { class: "dot", cx: X(p[0][0]), cy: Y(p[0][2]), r: 4, fill: seriesColor(i) }));
      }
      return el;
    });
    if (opts.highlight != null && many && paths[opts.highlight]) {
      paths[opts.highlight].setAttribute("class", "series hot");
      svg.append(paths[opts.highlight]);
    }
    const cross = h("line", { class: "crosshair", y1: T, y2: H - B, visibility: "hidden" });
    svg.append(cross);
    const allX = Array.from(new Set(xs)).sort((a, b) => a - b);
    const overlay = h("rect", { x: L, y: T, width: W - L - R, height: H - T - B, fill: "transparent" });
    let hot = null;
    overlay.addEventListener("pointermove", (ev) => {
      const box = svg.getBoundingClientRect();
      const px = (ev.clientX - box.left) * (W / box.width);
      const py = (ev.clientY - box.top) * (H / box.height);
      const xv = x0 + (px - L) / (W - L - R) * (x1 - x0);
      let best = allX[0];
      for (const v of allX) if (Math.abs(v - xv) < Math.abs(best - xv)) best = v;
      cross.setAttribute("x1", X(best)); cross.setAttribute("x2", X(best));
      cross.setAttribute("visibility", "visible");
      const at = series.map((s, i) => {
        let q = null;
        for (const p of s.points) if (p[2] !== null && (q === null || Math.abs(p[0] - best) < Math.abs(q[0] - best))) q = p;
        return { i, s, q };
      }).filter((r) => r.q && r.q[0] === best);
      let rows;
      if (many) {
        // the line nearest the pointer, lifted; the rest stay grey
        let near = null;
        for (const r of at) if (near === null || Math.abs(Y(r.q[2]) - py) < Math.abs(Y(near.q[2]) - py)) near = r;
        if (hot !== null && hot !== opts.highlight) paths[hot].setAttribute("class", "series muted");
        if (near) { hot = near.i; paths[hot].setAttribute("class", "series hot"); svg.insertBefore(paths[hot], cross); }
        rows = near ? [{ value: fmtNum(near.q[2]), name: near.s.group, color: "var(--s1)" }] : [];
        rows.push({ value: String(at.length), name: "series at this point" });
      } else {
        rows = at.map((r) => ({ value: fmtNum(r.q[2]), name: r.s.group, color: seriesColor(r.i) }));
      }
      const xl = at.length ? at[0].q[1] : fmtX(best, epoch, x1 - x0, opts.labels);
      showTip(ev, (opts.over || "row") + " " + (epoch ? fmtX(best, true, 0) + " (" + xl + ")" : xl), rows);
    });
    overlay.addEventListener("pointerleave", () => {
      cross.setAttribute("visibility", "hidden");
      hideTip();
      if (many && hot !== null && hot !== opts.highlight) paths[hot].setAttribute("class", "series muted");
      hot = null;
    });
    svg.append(overlay);
    return svg;
  }

  // -------------------------------------------------------------------------
  // Group, pivot, trend
  // -------------------------------------------------------------------------

  function rowsKey() { return S.e + ":" + (S.t || ""); }

  // The columns of the table in view; the table tab's own fetch is reused
  // when it is for this same entry and table.
  async function columnsOf() {
    if (S.rows && S.rowsKey === rowsKey()) return S.rows;
    const d = await api("/api/rows", tableParams({ limit: 1 }));
    S.rows = d;
    S.rowsKey = rowsKey();
    return d;
  }

  function select(label, value, options, onchange) {
    const sel = h("select", { "aria-label": label }, options.map(([v, l]) =>
      h("option", { value: v, text: l, selected: v === value ? true : null })));
    sel.addEventListener("change", () => onchange(sel.value));
    return h("label", null, label, sel);
  }

  function resultTable(d, opts) {
    const numCols = d.columns.filter((c) => d.kinds[c] === "num");
    const maxes = {};
    for (const c of numCols) {
      const i = d.columns.indexOf(c);
      maxes[c] = Math.max(0, ...d.rows.map((r) => Math.abs(parseFloat(r[i])) || 0));
    }
    const tbody = h("tbody");
    for (const r of d.rows) {
      const tr = h("tr", { tabindex: opts.onRow ? "0" : null,
        onclick: opts.onRow ? () => opts.onRow(r) : null,
        onkeydown: opts.onRow ? (ev) => { if (ev.key === "Enter") opts.onRow(r); } : null });
      r.forEach((v, j) => {
        const c = d.columns[j];
        const td = cellNode(v, d.kinds[c]);
        if (opts.bars && maxes[c] && v !== "" && j > 0 && c !== "n") {
          td.classList.add("bar-cell");
          const span = h("span", { text: td.textContent });
          clear(td).append(h("div", { class: "bar", style: { width: (100 * Math.abs(parseFloat(v)) / maxes[c]) + "%" } }), span);
        }
        if (opts.heat) opts.heat(td, v, c, r);
        tr.append(td);
      });
      tbody.append(tr);
    }
    return h("div", { class: "grid-wrap" }, h("table", { class: "grid" },
      h("thead", null, h("tr", null, d.columns.map((c) => h("th", { class: d.kinds[c] === "num" ? "num" : null },
        h("div", { class: "th" }, h("span", { style: { padding: "6px 10px" }, text: c })))))), tbody));
  }

  async function viewGroup(view) {
    const cols = await columnsOf();
    const columns = cols.columns;
    const pick = (cands) => cands.find((c) => columns.includes(c));
    const by = S.p.by || pick(["rack", "row", "room", "role", "status", "test", "dir", "peer"]) ||
      columns.find((c) => cols.kinds[c] === "text") || columns[0];
    S.p.by = by;
    const agg = S.p.agg || "";
    const valcol = S.p.cols || "";
    renderFilterbar();
    clear(view);
    const ctl = h("div", { class: "controls" },
      select("Group by", by, columns.map((c) => [c, c]), (v) => { S.p.by = v; renderView(); }),
      select("Columns", valcol, [["", "every number"]].concat(columns.filter((c) => c !== by).map((c) => [c, c])),
        (v) => { S.p.cols = v; renderView(); }),
      select("Figure", agg, [["", "default"], ["mean", "mean"], ["median", "median"], ["min", "min"],
        ["max", "max"], ["sum", "sum"], ["p95", "p95"], ["p05", "p05"], ["stdev", "stdev"], ["count", "count"],
        ["distinct", "distinct"], ["top", "most common"], ["worst", "worst"]], (v) => { S.p.agg = v; renderView(); }));
    view.append(ctl);
    const d = await api("/api/group", tableParams({ by: by, cols: valcol || null, agg: agg || null }));
    renderCli(cli("stats", (valcol ? shq(valcol) + " " : "") + "--by " + shq(by) + (agg ? " --agg " + agg : "")));
    view.append(h("p", { class: "count", text: d.rows.length + " groups. Pick one to see its rows." }));
    view.append(resultTable(d, { bars: true, onRow: (r) => {
      S.tab = "table";
      addFilter(quoteCol(by) + "=" + (r[0] === "" ? "" : quoteVal(r[0])));
    } }));
  }

  async function viewPivot(view) {
    const cols = await columnsOf();
    const columns = cols.columns;
    const has = (c) => columns.includes(c);
    const results = cols.results;
    const rows = S.p.rows || (results ? "target" : has("host") ? "host" : has("src") ? "src" : columns[0]);
    const colc = S.p.cols_ || (results ? "test" : ["peer", "dst", "test", "pass", "dir"].find((c) => has(c) && c !== rows) ||
      columns.find((c) => c !== rows && cols.kinds[c] === "text") || columns[1] || columns[0]);
    const values = S.p.values !== undefined ? S.p.values : (results ? "value" :
      (columns.find((c) => cols.kinds[c] === "num" && c !== rows && c !== colc && !["rc", "duration_s", "pass", "ts"].includes(c)) || ""));
    const agg = S.p.agg || "auto";
    Object.assign(S.p, { rows: rows, cols_: colc, values: values });
    renderFilterbar();
    clear(view);
    const opts = columns.map((c) => [c, c]);
    view.append(h("div", { class: "controls" },
      select("Rows", rows, opts, (v) => { S.p.rows = v; renderView(); }),
      select("Columns", colc, opts, (v) => { S.p.cols_ = v; renderView(); }),
      select("Cells", values, [["", "count of rows"]].concat(opts), (v) => { S.p.values = v; renderView(); }),
      select("Figure", agg, [["auto", "auto"], ["mean", "mean"], ["median", "median"], ["min", "min"], ["max", "max"],
        ["sum", "sum"], ["p95", "p95"], ["last", "last"], ["worst", "worst"], ["count", "count"]], (v) => { S.p.agg = v; renderView(); })));
    const d = await api("/api/pivot", tableParams({ rows: rows, cols: colc, values: values || null, agg: agg }));
    renderCli(cli("pivot", "--rows " + shq(rows) + " --cols " + shq(colc) + (values ? " --values " + shq(values) : "") +
      (agg !== "auto" ? " --agg " + agg : "")));
    // One metric across the grid shares one scale; a pivot whose columns
    // are different tests scales each column on its own, because a scale
    // shared by microseconds and percentages says nothing.
    const perCol = colc === "test";
    const nums = {};
    d.columns.slice(1).forEach((c, k) => {
      const v = d.rows.map((r) => parseFloat(r[k + 1])).filter((x) => isFinite(x));
      nums[c] = v;
    });
    const all = [].concat(...Object.values(nums));
    const range = (c) => {
      const v = perCol ? nums[c] : all;
      return v.length ? [Math.min(...v), Math.max(...v)] : [0, 0];
    };
    view.append(h("p", { class: "count", text: d.rows.length + " rows × " + (d.columns.length - 1) + " columns" +
      (perCol ? "; each column shaded on its own scale" : "; one shading scale for the whole grid") }));
    view.append(resultTable(d, { heat: (td, v, c, r) => {
      if (c === d.columns[0] || v === "") return;
      const x = parseFloat(v);
      if (!isFinite(x)) return;
      const [lo, hi] = range(c);
      if (!(hi > lo)) return;               // nothing to compare: no shade
      const k = Math.round(5 * (x - lo) / (hi - lo));
      td.style.background = "var(--seq-" + k + ")";
      const dark = document.documentElement.dataset.theme === "dark" ||
        (!document.documentElement.dataset.theme && matchMedia("(prefers-color-scheme: dark)").matches);
      td.style.color = (dark ? k <= 2 : k >= 3) ? "#ffffff" : "#0b0b0b";
      td.addEventListener("pointermove", (ev) => showTip(ev, r[0] + " → " + c, [{ value: v, name: values || "rows" }]));
      td.addEventListener("pointerleave", hideTip);
    } }));
  }

  async function viewTrend(view) {
    const cols = await columnsOf();
    const columns = cols.columns;
    const nums = columns.filter((c) => cols.kinds[c] === "num" && !["rc", "pass", "ts", "duration_s"].includes(c));
    const c = S.p.c || (cols.results ? "value" : nums[0]);
    renderFilterbar();
    clear(view);
    if (!c) { view.append(h("p", { class: "empty", text: "No numeric column to draw." })); return; }
    const by = S.p.by_t !== undefined ? S.p.by_t : null;
    const over = S.p.over !== undefined ? S.p.over : null;
    const d = await api("/api/trend", tableParams({ c: c, by: by, over: over }));
    S.p.c = c;
    view.append(h("div", { class: "controls" },
      select("Column", c, (cols.results ? ["value"] : []).concat(columns.filter((x) => cols.kinds[x] === "num")).map((x) => [x, x]),
        (v) => { S.p.c = v; renderView(); }),
      select("One line per", d.by || "", [["", "(one line)"]].concat(columns.map((x) => [x, x])),
        (v) => { S.p.by_t = v; renderView(); }),
      select("Over", d.over || "", [["", "row order"]].concat(columns.map((x) => [x, x])),
        (v) => { S.p.over = v; renderView(); })));
    renderCli(cli("trend", shq(c) + (d.by ? " --by " + shq(d.by) : "") + (d.over ? " --over " + shq(d.over) : "")));
    if (cols.results && c === "value" && !S.where.some((w) => /^test\b/.test(w))) {
      view.append(h("p", { class: "count", text: "Several tests share the value column: add a filter like test=mx_pps to draw one." }));
    }
    const card = h("div", { class: "card" });
    view.append(card);
    const hl = S.p.hl != null ? parseInt(S.p.hl, 10) : null;
    const many = d.series.length > 8;
    const width = Math.max(320, view.clientWidth - 34);
    card.append(h("h3", { text: d.column + (d.by ? " by " + d.by : "") + " over " + (d.over || "row order") }));
    card.append(lineChart(d.series, { width: width, numericX: d.numeric_x, over: d.over,
      labels: d.x_labels, label: d.column + " over time", highlight: hl }));
    if (!many && d.series.length > 1) {
      card.append(h("div", { class: "legend" }, d.series.map((s, i) =>
        h("span", null, h("span", { class: "key", style: { background: seriesColor(i) } }), s.group))));
    } else if (many) {
      card.append(h("p", { class: "count", text: d.series.length + " series, drawn grey: point at a line to lift it, or pick one in the table below." }));
    }
    const rows = d.series.map((s, i) => {
      const v = s.points.map((p) => p[2]).filter((x) => x !== null);
      return [s.group, String(v.length), fmtNum(v[0]), fmtNum(v[v.length - 1]),
        fmtNum(v.length ? Math.min(...v) : null), fmtNum(v.length ? Math.max(...v) : null), i];
    });
    const t = { columns: [d.by || "series", "n", "first", "last", "min", "max"],
      kinds: { n: "num", first: "num", last: "num", min: "num", max: "num" },
      rows: rows.map((r) => r.slice(0, 6)) };
    view.append(resultTable(t, { onRow: (r) => {
      const i = rows.findIndex((x) => x[0] === r[0]);
      S.p.hl = many ? String(i) : "";
      if (!many) { S.tab = "table"; addFilter(quoteCol(d.by || "host") + "=" + quoteVal(r[0])); return; }
      renderView();
    } }));
  }

  // -------------------------------------------------------------------------
  // Diff
  // -------------------------------------------------------------------------

  async function viewDiff(view) {
    renderFilterbar();
    clear(view);
    const against = S.p.a !== undefined ? S.p.a : (S.info && S.info.previous) || "";
    const opts = [["", against ? "" : "(pick an entry)"]].concat(S.entries.filter((e) => e.id !== S.e).map((e) =>
      [e.id, e.id + "  " + (entryTitle(e) || "").slice(0, 40)]));
    const keyIn = h("input", { type: "text", value: S.p.key || "", placeholder: "auto", "aria-label": "Match rows on" });
    const tolIn = h("input", { type: "number", value: S.p.tol || "", placeholder: "0", min: "0", step: "any", "aria-label": "Tolerance percent", style: { width: "6em" } });
    const run = h("button", { type: "button", class: "primary", text: "Compare", onclick: () => {
      S.p.key = keyIn.value.trim(); S.p.tol = tolIn.value.trim(); renderView();
    } });
    view.append(h("div", { class: "controls" },
      select("Compare against (A, older)", against, opts.filter((o, i) => i > 0 || !against), (v) => { S.p.a = v; renderView(); }),
      h("label", null, "Match rows on", keyIn), h("label", null, "Ignore changes within %", tolIn), run));
    if (!against) {
      view.append(h("p", { class: "empty", text: "Nothing earlier in the store ran what this ran. Pick a run to compare against." }));
      renderCli("");
      return;
    }
    const a = against + (S.t && !against.includes(":") ? ":" + S.t : "");
    const b = S.e + (S.t ? ":" + S.t : "");
    const d = await api("/api/diff", { a: a, b: b, where: S.where, key: S.p.key || null, tolerance: S.p.tol || null });
    renderCli(["qd diff", shq(a), shq(b), S.p.key ? "--key " + shq(S.p.key) : "", S.p.tol ? "--tolerance " + S.p.tol : "", whereArgs()].filter(Boolean).join(" "));
    const both = d.changed_total + d.same;
    view.append(h("div", { class: "tiles" },
      tile("Changed", d.changed_total, d.changed_total ? "serious" : "good"),
      tile("The same", d.same, null), tile("Only in A (gone)", d.only_a.length, d.only_a.length ? "critical" : null),
      tile("Only in B (new)", d.only_b.length, null)));
    view.append(h("ul", { class: "notes" },
      h("li", { text: "A " + d.a + " (" + d.a_rows + " rows) → B " + d.b + " (" + d.b_rows + " rows), matched on " + d.key.join(", ") + "; " + both + " keys in both" }),
      h("li", { text: "compared: " + (d.cols.join(", ") || "nothing") }),
      d.ignored.length ? h("li", { text: "ignored, as they differ on every run by construction: " + d.ignored.join(", ") }) : null,
      d.notes.map((n) => h("li", { text: n }))));
    if (d.col_summary.length) {
      const t = { columns: ["column", "pairs", "mean A", "mean B", "change", "median delta", "rose", "fell", "same"],
        kinds: { pairs: "num", "mean A": "num", "mean B": "num", change: "num", "median delta": "num", rose: "num", fell: "num", same: "num" },
        rows: d.col_summary.map((c) => [c.column, String(c.n), fmtNum(c.mean_a), fmtNum(c.mean_b),
          c.mean_pct == null ? "" : (c.mean_pct > 0 ? "+" : "") + fmtNum(c.mean_pct) + "%", fmtNum(c.median_delta),
          String(c.rose), String(c.fell), String(c.same)]) };
      view.append(h("div", { class: "card" }, h("h3", { text: "Each column, across the matched rows" }), resultTable(t, {})));
    }
    if (d.changed.length) {
      const card = h("div", { class: "card" }, h("h3", { text: "What changed, worst first" + (d.changed_total > d.changed.length ? " (first " + d.changed.length + " of " + d.changed_total + ")" : "") }));
      const tbody = h("tbody");
      for (const ch of d.changed) {
        ch.changes.forEach((c, k) => {
          const tr = h("tr", null,
            h("td", { text: k === 0 ? ch.key.join(" ") : "" }),
            h("td", { text: c.col }),
            cellNode(c.a.includes("\n") ? c.a.split("\n")[0] : c.a),
            cellNode(c.b.includes("\n") ? c.b.split("\n")[0] : c.b),
            h("td", { class: "num " + (c.delta > 0 ? "delta-up" : c.delta < 0 ? "delta-down" : ""),
              text: c.kind === "changed" ? (c.delta != null ? fmtNum(c.delta) : "") : c.kind }),
            h("td", { class: "num", text: c.pct != null ? (c.pct > 0 ? "+" : "") + fmtNum(c.pct) + "%" : "" }));
          tbody.append(tr);
          if (c.text_diff) {
            const pre = h("div", { class: "diffline" }, c.text_diff.map((ln) =>
              h("div", { class: ln.startsWith("+") ? "add" : ln.startsWith("-") ? "del" : null, text: ln })));
            tbody.append(h("tr", null, h("td", { colspan: "6" }, pre)));
          }
        });
      }
      card.append(h("div", { class: "grid-wrap" }, h("table", { class: "grid" },
        h("thead", null, h("tr", null, ["key", "column", "A", "B", "change", "%"].map((c) =>
          h("th", null, h("div", { class: "th" }, h("span", { style: { padding: "6px 10px" }, text: c })))))), tbody)));
      view.append(card);
    }
    for (const [title, keys] of [["Only in A: gone since", d.only_a], ["Only in B: new", d.only_b]]) {
      if (keys.length) view.append(h("div", { class: "card" }, h("h3", { text: title + " (" + keys.length + ")" }),
        h("p", { class: "mono", text: keys.map((k) => k.join(" ")).join("   ") })));
    }
    if (!d.changed_total && !d.only_a.length && !d.only_b.length) {
      view.append(h("p", { class: "empty", text: "No differences." }));
    }
  }

  // -------------------------------------------------------------------------
  // About: what the store says about this run
  // -------------------------------------------------------------------------

  async function viewAbout(view) {
    renderFilterbar();
    renderCli("qd log " + shq(S.e));
    clear(view);
    const info = S.info || await api("/api/entry", { e: S.e });
    view.append(h("div", { class: "card" }, h("h3", { text: "Logbook entry" }),
      h("pre", { class: "mono", text: info.describe.join("\n") })));
    const m = info.meta;
    if (m.host_list && m.host_list.length) {
      view.append(h("div", { class: "card" }, h("h3", { text: "Host list (" + m.host_list.length + ")" }),
        h("pre", { class: "mono", text: m.host_list.join("\n") })));
    }
    const id = shq(S.e);
    view.append(h("div", { class: "card" }, h("h3", { text: "From a terminal" }),
      h("pre", { class: "mono", text: [
        "qd view " + id + "                 # the same, full-screen in a terminal",
        "qd stats " + id + "                # every column described",
        "qd diff " + id + "                 # against the last run of the same thing",
        "qd export " + id + " -o out.csv",
        "qd floor " + id + " --layout floor.dc",
      ].join("\n") })));
  }

  // -------------------------------------------------------------------------
  // Start
  // -------------------------------------------------------------------------

  async function start() {
    let mode = "auto";
    try { mode = localStorage.getItem("qd-theme") || "auto"; } catch (e) { /* no storage */ }
    setTheme(THEMES.includes(mode) ? mode : "auto");
    $("theme").addEventListener("click", () => {
      const cur = document.documentElement.dataset.theme || "auto";
      setTheme(THEMES[(THEMES.indexOf(cur) + 1) % THEMES.length]);
      if (S.tab === "pivot") renderView();
    });
    $("entry-filter").addEventListener("input", renderEntries);
    $("refresh").addEventListener("click", async () => {
      try { await loadEntries(); if (S.e) await openEntry(S.e, true); } catch (err) { showError(err); }
    });
    window.addEventListener("keydown", (ev) => {
      if (ev.key === "Escape" && !$("panel").hidden && !$("detail").open) closePanel();
    });
    try {
      await loadEntries();
    } catch (err) { showError(err); return; }
    await fromHash();
    // A hash typed, pasted, or reached with Back: our own updates use
    // replaceState, which does not fire this.
    window.addEventListener("hashchange", fromHash);
  }

  // The hash may name an entry the way the command line does -- latest,
  // latest~1, a name, part of an id -- so it is resolved by the server.
  async function fromHash() {
    readHash();
    renderTabs();
    if (S.e && !entryById(S.e)) {
      try {
        const info = await api("/api/entry", { e: S.e });
        S.e = info.id;
      } catch (err) {
        showError(err);
        S.e = null;
      }
    }
    if (S.e) await openEntry(S.e, true);
    else if (S.entries.length) await openEntry(S.entries[0].id);
    else renderView();
  }

  start();
})();
