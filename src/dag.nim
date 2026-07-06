# The self-contained HTML page served by `hunim dag`. The graph JSON is
# embedded directly into the document, so rendering needs no further requests
# and no external assets. Layout is columnar — pages, templates, components,
# exec scripts — with SVG bezier edges; hovering (or clicking to pin) a node
# lights up its full upstream and downstream dependency chain.

const pageHead = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hunim DAG</title>
<style>
:root {
  --bg: #ffffff; --fg: #1a1f27; --muted: #667085; --line: #c5cedb;
  --panel: #f5f7fa; --border: #dde3ea;
  --page: #3572d8; --template: #8a4fd3; --component: #1f9d63;
  --script: #d97706; --missing: #d64545;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #12151a; --fg: #e6eaf0; --muted: #8b95a5; --line: #39414f;
          --panel: #1a1f27; --border: #2a313c; --page: #5b95ec;
          --template: #a875e8; --component: #34c283; --script: #f0a13c;
          --missing: #f26d6d; }
}
* { box-sizing: border-box; margin: 0; }
html, body { height: 100%; }
body { background: var(--bg); color: var(--fg); display: flex;
  flex-direction: column;
  font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { display: flex; align-items: baseline; gap: 1.5rem; flex-wrap: wrap;
  padding: 12px 20px; border-bottom: 1px solid var(--border); }
h1 { font-size: 16px; }
h1 span { color: var(--muted); font-weight: normal; }
.legend { display: flex; gap: 1rem; color: var(--muted); font-size: 12px; }
.legend i { display: inline-block; width: 10px; height: 10px;
  border-radius: 3px; margin-right: 5px; vertical-align: -1px; }
#hint { margin-left: auto; color: var(--muted); font-size: 12px; }
#viewport { flex: 1; overflow: auto; position: relative; }
#stage { position: relative; }
#stage svg { position: absolute; left: 0; top: 0; overflow: visible; }
.node { position: absolute; display: flex; align-items: center;
  padding: 0 10px; border: 1px solid var(--border); border-radius: 6px;
  background: var(--panel); cursor: pointer;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px; white-space: nowrap; overflow: hidden;
  text-overflow: ellipsis; transition: opacity .12s; }
.node::before { content: ""; width: 8px; height: 8px; border-radius: 50%;
  background: var(--kc); margin-right: 8px; flex: none; }
.node.missing { border-style: dashed; border-color: var(--missing);
  color: var(--missing); }
.node.missing::before { background: var(--missing); }
.colhead { position: absolute; font-size: 11px; font-weight: 600;
  letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
path.edge { fill: none; stroke: var(--line); stroke-width: 1.5;
  transition: opacity .12s, stroke .12s; }
.dim .node, .dim path.edge { opacity: .15; }
.dim .node.lit { opacity: 1; border-color: var(--kc); }
.dim .node.lit.missing { border-color: var(--missing); }
.dim path.edge.lit { opacity: 1; stroke: var(--edgehl); stroke-width: 2; }
#empty { padding: 40px 20px; color: var(--muted); }
</style>
</head>
<body>
<header>
  <h1>hunim dag <span id="site"></span></h1>
  <div class="legend" id="legend"></div>
  <div id="hint">hover a node to trace its edges &middot; click to pin</div>
</header>
<div id="viewport"><div id="stage"><svg id="edgesvg"></svg></div></div>
<script>
const GRAPH = """

const pageTail = """;
(function () {
  const KINDS = ["page", "template", "component", "script"];
  const KIND_LABEL = { page: "Pages", template: "Templates",
                       component: "Components", script: "Exec scripts" };
  const stage = document.getElementById("stage");
  const svg = document.getElementById("edgesvg");
  let pinned = null;

  function cssVar(name) {
    return getComputedStyle(document.documentElement)
      .getPropertyValue(name).trim();
  }

  if (GRAPH.title)
    document.getElementById("site").textContent = "— " + GRAPH.title;

  const legend = document.getElementById("legend");
  for (const k of KINDS) {
    const count = GRAPH.nodes.filter(n => n.kind === k).length;
    if (!count) continue;
    const el = document.createElement("span");
    const sw = document.createElement("i");
    sw.style.background = cssVar("--" + k);
    el.appendChild(sw);
    el.appendChild(document.createTextNode(KIND_LABEL[k] + " (" + count + ")"));
    legend.appendChild(el);
  }

  if (!GRAPH.nodes.length) {
    const d = document.createElement("div");
    d.id = "empty";
    d.textContent =
      "Nothing to draw: no pages, templates, or components found.";
    document.getElementById("viewport").appendChild(d);
    return;
  }

  // ---- layout: one column per dependency level. A node's level is the
  // longest chain of references leading to it, so pages sit at level 0 and
  // anything they use sits to the right of everything that uses it.
  const NODE_H = 30, ROW_GAP = 14, COL_GAP = 130, PAD = 48, HEAD_H = 30;
  const CHAR_W = 7.3, NODE_PAD = 42;

  const nodeIds = new Set(GRAPH.nodes.map(n => n.id));
  const incoming = {}; // id -> [ids that reference it]
  for (const e of GRAPH.edges) {
    if (!nodeIds.has(e.from) || !nodeIds.has(e.to)) continue;
    (incoming[e.to] = incoming[e.to] || []).push(e.from);
  }
  const levelOf = {};
  const visiting = new Set();
  function levelFor(id) {
    if (id in levelOf) return levelOf[id];
    if (visiting.has(id)) return 0; // cycle guard (builds reject cycles)
    visiting.add(id);
    let lv = 0;
    for (const from of (incoming[id] || []))
      lv = Math.max(lv, levelFor(from) + 1);
    visiting.delete(id);
    levelOf[id] = lv;
    return lv;
  }
  GRAPH.nodes.forEach(n => levelFor(n.id));

  const maxLevel = Math.max(...GRAPH.nodes.map(n => levelOf[n.id]));
  const cols = [];
  for (let i = 0; i <= maxLevel; i++)
    cols.push(GRAPH.nodes.filter(n => levelOf[n.id] === i));
  cols.forEach(c => c.sort((a, b) =>
    KINDS.indexOf(a.kind) - KINDS.indexOf(b.kind) ||
    a.label.localeCompare(b.label)));

  const colW = cols.map(c =>
    Math.max(120, ...c.map(n =>
      (n.label.length + (n.missing ? 10 : 0)) * CHAR_W + NODE_PAD)));
  const colH = cols.map(c => c.length * (NODE_H + ROW_GAP) - ROW_GAP);
  const maxH = Math.max(...colH);

  const pos = {}; // id -> { x, y, w, node }
  let x = PAD;
  cols.forEach((c, ci) => {
    const head = document.createElement("div");
    head.className = "colhead";
    head.style.left = x + "px";
    head.style.top = (PAD - 30) + "px";
    head.textContent = ci === 0 ? "Pages" : "Level " + ci;
    stage.appendChild(head);

    let y = PAD + HEAD_H + (maxH - colH[ci]) / 2;
    for (const n of c) {
      pos[n.id] = { x: x, y: y, w: colW[ci], node: n };
      y += NODE_H + ROW_GAP;
    }
    x += colW[ci] + COL_GAP;
  });

  const totalW = x - COL_GAP + PAD;
  const totalH = PAD + HEAD_H + maxH + PAD;
  stage.style.width = totalW + "px";
  stage.style.height = totalH + "px";
  svg.setAttribute("width", totalW);
  svg.setAttribute("height", totalH);

  // ---- edges
  const edges = GRAPH.edges.filter(e => pos[e.from] && pos[e.to]);
  const edgeEls = [];
  const down = {}, up = {};
  for (const e of edges) {
    const a = pos[e.from], b = pos[e.to];
    const sy = a.y + NODE_H / 2, ty = b.y + NODE_H / 2;
    let d;
    if (b.x <= a.x) {
      // Same or earlier column (only possible on a reference cycle, which the
      // build rejects but this viewer still draws): bow out to the right,
      // arriving at the target's right edge with a leftward arrowhead.
      const sx = a.x + a.w, ex = b.x + b.w;
      const bow = 40 + Math.abs(ty - sy) * 0.1;
      d = `M ${sx} ${sy} C ${sx + bow} ${sy}, ${ex + bow} ${ty}, ${ex} ${ty}`
        + ` M ${ex + 7} ${ty - 4} L ${ex} ${ty} L ${ex + 7} ${ty + 4}`;
    } else {
      const sx = a.x + a.w, tx = b.x;
      const mid = (sx + tx) / 2;
      d = `M ${sx} ${sy} C ${mid} ${sy}, ${mid} ${ty}, ${tx} ${ty}`
        + ` M ${tx - 7} ${ty - 4} L ${tx} ${ty} L ${tx - 7} ${ty + 4}`;
    }
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", d);
    p.setAttribute("class", "edge");
    svg.appendChild(p);
    edgeEls.push({ el: p, from: e.from, to: e.to });
    (down[e.from] = down[e.from] || []).push(e.to);
    (up[e.to] = up[e.to] || []).push(e.from);
  }

  // ---- nodes
  const nodeEls = {};
  for (const id in pos) {
    const p = pos[id], n = p.node;
    const el = document.createElement("div");
    el.className = "node" + (n.missing ? " missing" : "");
    el.style.setProperty("--kc", cssVar("--" + n.kind));
    el.style.left = p.x + "px";
    el.style.top = p.y + "px";
    el.style.width = p.w + "px";
    el.style.height = NODE_H + "px";
    el.textContent = n.label + (n.missing ? " (missing)" : "");
    el.title = n.missing ? "referenced but not found" : (n.file || n.label);
    stage.appendChild(el);
    nodeEls[id] = el;
    el.addEventListener("mouseenter", () => { if (!pinned) highlight(id); });
    el.addEventListener("mouseleave", () => { if (!pinned) clearHighlight(); });
    el.addEventListener("click", ev => {
      ev.stopPropagation();
      pinned = pinned === id ? null : id;
      if (pinned) highlight(pinned); else clearHighlight();
    });
  }
  document.body.addEventListener("click", () => {
    pinned = null;
    clearHighlight();
  });

  function closure(id, dir) {
    const seen = new Set([id]);
    const stack = [id];
    while (stack.length) {
      const cur = stack.pop();
      for (const next of (dir[cur] || []))
        if (!seen.has(next)) { seen.add(next); stack.push(next); }
    }
    return seen;
  }

  function highlight(id) {
    const lit = new Set([...closure(id, down), ...closure(id, up)]);
    stage.classList.add("dim");
    stage.style.setProperty("--edgehl", cssVar("--" + pos[id].node.kind));
    for (const nid in nodeEls)
      nodeEls[nid].classList.toggle("lit", lit.has(nid));
    for (const e of edgeEls)
      e.el.classList.toggle("lit", lit.has(e.from) && lit.has(e.to));
  }

  function clearHighlight() {
    stage.classList.remove("dim");
    for (const nid in nodeEls) nodeEls[nid].classList.remove("lit");
    for (const e of edgeEls) e.el.classList.remove("lit");
  }
})();
</script>
</body>
</html>
"""

func dagPage*(graphJson: string): string =
  pageHead & graphJson & pageTail
