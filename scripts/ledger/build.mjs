#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const STATES = ["Shipped", "Partial", "Stub", "Absent", "Unknown"];
const STATE_ICONS = { Shipped: "●", Partial: "◐", Stub: "◌", Absent: "○", Unknown: "?" };

function parseArguments(argv) {
  const options = {
    source: resolve("docs/feature-ledger.md"),
    output: resolve("docs/feature-ledger.html"),
    check: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--check") options.check = true;
    else if (argument === "--source" && argv[index + 1]) options.source = resolve(argv[++index]);
    else if (argument === "--output" && argv[index + 1]) options.output = resolve(argv[++index]);
    else throw new Error(`unknown or incomplete argument: ${argument}`);
  }
  return options;
}

function escapeHtml(value) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function renderInline(value) {
  let html = "";
  let plain = "";
  const flush = () => {
    html += escapeHtml(plain);
    plain = "";
  };
  for (let index = 0; index < value.length;) {
    if (value[index] === "`") {
      const end = value.indexOf("`", index + 1);
      if (end !== -1) {
        flush();
        html += `<code>${escapeHtml(value.slice(index + 1, end))}</code>`;
        index = end + 1;
        continue;
      }
    }
    if (value.startsWith("**", index)) {
      const end = value.indexOf("**", index + 2);
      if (end !== -1) {
        flush();
        html += `<strong>${renderInline(value.slice(index + 2, end))}</strong>`;
        index = end + 2;
        continue;
      }
    }
    if (value[index] === "[") {
      const middle = value.indexOf("](", index + 1);
      const end = middle === -1 ? -1 : value.indexOf(")", middle + 2);
      if (middle !== -1 && end !== -1) {
        flush();
        const label = value.slice(index + 1, middle);
        const href = value.slice(middle + 2, end);
        const external = /^https?:\/\//.test(href) ? ' target="_blank" rel="noopener noreferrer"' : "";
        html += `<a href="${escapeHtml(href)}"${external}>${renderInline(label)}</a>`;
        index = end + 1;
        continue;
      }
    }
    plain += value[index++];
  }
  flush();
  return html;
}

function stripMarkdown(value) {
  return value
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .trim();
}

function slugify(value) {
  return stripMarkdown(value)
    .toLowerCase()
    .replace(/[—–/]+/g, "-")
    .replace(/[，、：；！？（）()·“”‘’<>]/g, "")
    .replace(/[^\p{Letter}\p{Number}_-]+/gu, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

function splitTableRow(line) {
  const cells = [];
  let cell = "";
  let inCode = false;
  const body = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  for (let index = 0; index < body.length; index += 1) {
    const character = body[index];
    if (character === "`" && body[index - 1] !== "\\") inCode = !inCode;
    if (character === "|" && !inCode && body[index - 1] !== "\\") {
      cells.push(cell.trim());
      cell = "";
    } else {
      cell += character;
    }
  }
  cells.push(cell.trim());
  return cells.map((value) => value.replaceAll("\\|", "|"));
}

function parseMarkdown(markdown) {
  const lines = markdown.replaceAll("\r\n", "\n").split("\n");
  const blocks = [];
  for (let index = 0; index < lines.length;) {
    const line = lines[index];
    if (!line.trim()) {
      index += 1;
      continue;
    }
    const heading = line.match(/^(#{1,3})\s+(.+)$/);
    if (heading) {
      blocks.push({ type: "heading", level: heading[1].length, text: heading[2], id: slugify(heading[2]) });
      index += 1;
      continue;
    }
    if (/^---+$/.test(line.trim())) {
      blocks.push({ type: "hr" });
      index += 1;
      continue;
    }
    if (line.startsWith("|") && lines[index + 1]?.match(/^\|(?:\s*:?-+:?\s*\|)+$/)) {
      const header = splitTableRow(line);
      index += 2;
      const rows = [];
      while (index < lines.length && lines[index].startsWith("|")) rows.push(splitTableRow(lines[index++]));
      blocks.push({ type: "table", header, rows });
      continue;
    }
    if (/^- /.test(line)) {
      const items = [];
      while (index < lines.length && /^- /.test(lines[index])) items.push(lines[index++].slice(2));
      blocks.push({ type: "list", ordered: false, items });
      continue;
    }
    if (/^\d+\. /.test(line)) {
      const items = [];
      while (index < lines.length && /^\d+\. /.test(lines[index])) items.push(lines[index++].replace(/^\d+\. /, ""));
      blocks.push({ type: "list", ordered: true, items });
      continue;
    }
    const paragraph = [line.trim()];
    index += 1;
    while (index < lines.length && lines[index].trim() && !/^(#{1,3})\s+|^---+$|^\||^- |^\d+\. /.test(lines[index])) {
      paragraph.push(lines[index++].trim());
    }
    blocks.push({ type: "paragraph", text: paragraph.join(" ") });
  }
  return blocks;
}

function inventoryRow(row) {
  if (row.length !== 7) throw new Error(`row ${row[0] || "<unknown>"}: expected 7 cells`);
  const [id, capability, state, verification, plan, location, confirmation] = row;
  const phases = [...plan.matchAll(/P(\d+)/g)].map((match) => Number(match[1]));
  const phase = phases.length ? Math.min(...phases) : 99;
  const search = [id, capability, plan, stripMarkdown(location), stripMarkdown(confirmation)].join(" ").toLowerCase();
  const stateClass = `s-${state.toLowerCase()}`;
  return `<tr id="${escapeHtml(id)}" data-state="${escapeHtml(state)}" data-phase="${phase}" data-search="${escapeHtml(search)}"><td class="mono id"><a href="#${escapeHtml(id)}">${escapeHtml(id)}</a></td><td class="cap">${renderInline(capability)}</td><td><span class="state ${stateClass}"><span aria-hidden="true">${STATE_ICONS[state] ?? "?"}</span> ${escapeHtml(state)}</span></td><td class="ver">${renderInline(verification)}</td><td class="mono plan">${renderInline(plan)}</td><td class="where">${renderInline(location)}</td><td class="how">${renderInline(confirmation)}</td></tr>`;
}

function renderTable(block) {
  const inventory = block.header.join("|") === "ID|能力|状态|验证|计划|在哪|怎么确认";
  const className = inventory ? ' class="inv"' : "";
  const header = block.header.map((cell) => `<th scope="col">${renderInline(cell)}</th>`).join("");
  const rows = block.rows.map((row) => inventory
    ? inventoryRow(row)
    : `<tr>${row.map((cell) => `<td>${renderInline(cell)}</td>`).join("")}</tr>`).join("\n");
  return `<div class="table-wrap"><table${className}><thead><tr>${header}</tr></thead><tbody>\n${rows}\n</tbody></table></div>`;
}

function toolbar(counts) {
  const chips = STATES.map((state) => `<button type="button" class="chip" data-filter-state="${state}" aria-pressed="false"><span aria-hidden="true">${STATE_ICONS[state]}</span> ${state}<span class="mono">${counts[state]}</span></button>`).join("");
  return `<div class="toolbar" role="search" aria-label="筛选账簿">
<div role="group" aria-label="按状态筛选">${chips}</div>
<label class="result" for="milestone">范围</label>
<select id="milestone"><option value="all">全部阶段</option><option value="3">MVP（P0–P3）</option><option value="6">首发 v1（P0–P6）</option><option value="7">增强（P7）</option></select>
<input type="search" id="q" placeholder="搜索 ID、能力、工作包、确认步骤" aria-label="搜索账簿行">
<span class="result" id="result" aria-live="polite"></span>
<button type="button" class="clear hidden" id="clear">清除筛选</button>
</div>`;
}

function analyze(blocks) {
  const counts = Object.fromEntries(STATES.map((state) => [state, 0]));
  const areas = [];
  const documents = [];
  let inPart1 = false;
  let currentArea = null;
  for (const block of blocks) {
    if (block.type === "heading" && block.level === 2) {
      documents.push(block);
      inPart1 = block.text.startsWith("Part 1");
      if (block.text.startsWith("Part 2")) inPart1 = false;
    } else if (inPart1 && block.type === "heading" && block.level === 3) {
      currentArea = { ...block, count: 0 };
      areas.push(currentArea);
    } else if (block.type === "table" && block.header.join("|") === "ID|能力|状态|验证|计划|在哪|怎么确认") {
      for (const row of block.rows) {
        if (counts[row[2]] !== undefined) counts[row[2]] += 1;
        if (currentArea) currentArea.count += 1;
      }
    }
  }
  return { counts, areas: areas.filter((area) => area.count > 0), documents };
}

function renderContent(blocks, counts) {
  const output = [];
  let toolbarAdded = false;
  for (const block of blocks) {
    if (block.type === "heading") output.push(`<h${block.level}${block.level > 1 ? ` id="${escapeHtml(block.id)}"` : ""}>${renderInline(block.text)}</h${block.level}>`);
    else if (block.type === "paragraph") {
      const meta = output.length === 1 ? ' class="meta"' : "";
      output.push(`<p${meta}>${renderInline(block.text)}</p>`);
    } else if (block.type === "list") {
      const tag = block.ordered ? "ol" : "ul";
      output.push(`<${tag}>${block.items.map((item) => `<li>${renderInline(item)}</li>`).join("")}</${tag}>`);
    } else if (block.type === "table") {
      const inventory = block.header.join("|") === "ID|能力|状态|验证|计划|在哪|怎么确认";
      if (inventory && !toolbarAdded) {
        output.push(toolbar(counts));
        toolbarAdded = true;
      }
      output.push(renderTable(block));
    }
    else if (block.type === "hr") output.push("<hr>");
  }
  return output.join("\n");
}

function renderSidebar(areas, documents) {
  const areaLinks = areas.map((area) => `<li><a class="nav-row" href="#${escapeHtml(area.id)}"><span class="nav-name">${renderInline(area.text)}</span><span class="count mono">${area.count}</span></a></li>`).join("");
  const documentLinks = documents.map((heading) => `<li><a class="nav-row" href="#${escapeHtml(heading.id)}"><span class="nav-name">${renderInline(heading.text)}</span></a></li>`).join("");
  return `<aside aria-label="账簿目录">
<h2>Part 1 区域</h2><ul>${areaLinks}</ul>
<h2>文档</h2><ul>${documentLinks}</ul>
</aside>`;
}

const STYLE = `:root{--color-bg:#fff;--color-surface:#f6f7fb;--color-panel:#fff;--color-text:#1a1a1a;--color-muted:#6b7280;--color-accent:#2563eb;--color-accent-fill:#2563eb;--color-on-accent:#fff;--color-error-text:#b91c1c;
--line:color-mix(in srgb,var(--color-text) 12%,transparent);--soft:color-mix(in srgb,var(--color-accent) 12%,transparent);
--font:-apple-system,"SF Pro Text",BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;--mono:"SF Mono",ui-monospace,Menlo,monospace;color-scheme:light}
:root[data-theme=dark]{--color-bg:#0f1115;--color-surface:#161a22;--color-panel:#141821;--color-text:#e5e7eb;--color-muted:#9aa4b2;--color-accent:#60a5fa;--color-accent-fill:#1d4ed8;--color-error-text:#f87171;color-scheme:dark}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--color-bg:#0f1115;--color-surface:#161a22;--color-panel:#141821;--color-text:#e5e7eb;--color-muted:#9aa4b2;--color-accent:#60a5fa;--color-accent-fill:#1d4ed8;--color-error-text:#f87171;color-scheme:dark}}
*{box-sizing:border-box}html,body{margin:0;height:100%}body{font:13px/1.55 var(--font);color:var(--color-text);background:var(--color-bg);display:grid;grid-template-rows:38px 1fr 40px;grid-template-columns:220px minmax(0,1fr);grid-template-areas:"title title" "side main" "bar bar"}
.titlebar{grid-area:title;display:flex;align-items:center;justify-content:center;gap:8px;border-bottom:1px solid var(--line);background:var(--color-surface);font-size:13px;position:relative}.titlebar .lights{position:absolute;left:12px;display:flex;gap:8px}.titlebar .lights i{width:12px;height:12px;border-radius:50%;background:var(--line)}
aside{grid-area:side;background:var(--color-surface);border-right:1px solid var(--line);overflow:auto;padding:12px 8px}aside h2{font-size:12px;font-weight:600;color:var(--color-muted);margin:12px 8px 4px}aside ul{list-style:none;margin:0;padding:0}.nav-row{display:flex;align-items:center;gap:8px;min-height:28px;padding:4px 8px;border-radius:6px;color:var(--color-text);text-decoration:none}.nav-row:hover{background:var(--line)}.nav-row.active{background:var(--soft);color:var(--color-accent)}.nav-name{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.count{color:var(--color-muted);font-size:12px}
main{grid-area:main;overflow:auto;padding:16px 24px 48px}.content{max-width:1180px}.meta{color:var(--color-muted);font-size:12px;margin:0 0 16px}h1{font-size:16px;margin:0 0 4px}h2{font-size:16px;margin:32px 0 8px;padding-top:8px;border-top:1px solid var(--line)}h3{font-size:14px;margin:24px 0 8px}p,li{max-width:76ch}a{color:var(--color-accent)}code,.mono{font-family:var(--mono);font-size:12px}code{background:var(--line);padding:1px 4px;border-radius:4px;overflow-wrap:anywhere}pre{background:var(--color-surface);border:1px solid var(--line);border-radius:6px;padding:12px;overflow:auto}pre code{background:none;padding:0}hr{border:0;border-top:1px solid var(--line);margin:24px 0}
.table-wrap{overflow-x:auto;margin:8px 0 16px}table{border-collapse:collapse;width:100%;font-size:13px}th{text-align:left;font-weight:600;color:var(--color-muted);font-size:12px;border-bottom:1px solid var(--line);padding:6px 8px;white-space:nowrap}td{border-bottom:1px solid var(--line);padding:8px;vertical-align:top}table.inv td.id{white-space:nowrap}table.inv td.id a{color:var(--color-text);text-decoration:none}table.inv td.cap{min-width:120px;font-weight:500}table.inv td.plan{white-space:nowrap;color:var(--color-muted)}table.inv td.ver,table.inv td.where{white-space:nowrap;color:var(--color-muted)}table.inv td.how{min-width:320px}tr:target td{background:var(--soft)}
.state{display:inline-flex;gap:4px;align-items:center;white-space:nowrap;border:1px solid var(--line);border-radius:4px;padding:0 6px;font-size:12px;color:var(--color-muted)}.s-shipped{color:var(--color-accent);border-color:var(--color-accent)}.s-partial{color:var(--color-text);border-style:dashed}.toolbar{position:sticky;top:-16px;z-index:2;background:var(--color-bg);padding:12px 0;margin:0 0 8px;border-bottom:1px solid var(--line);display:flex;flex-wrap:wrap;gap:8px;align-items:center}.chip,select,input[type=search],.icon-btn{font:inherit;font-size:12px;color:var(--color-text);background:var(--color-panel);border:1px solid var(--line);border-radius:6px;min-height:28px;padding:2px 8px}.chip{display:inline-flex;gap:6px;align-items:center;cursor:pointer}.chip .mono{color:var(--color-muted)}.chip[aria-pressed=true]{background:var(--soft);border-color:var(--color-accent);color:var(--color-accent)}input[type=search]{width:220px}.result{color:var(--color-muted);font-size:12px}.clear{font:inherit;font-size:12px;background:none;border:0;color:var(--color-accent);cursor:pointer;padding:4px}.statusbar{grid-area:bar;display:flex;align-items:center;gap:12px;padding:0 12px;border-top:1px solid var(--line);background:var(--color-surface);font-size:12px;color:var(--color-muted)}.statusbar .spacer{flex:1}:focus-visible{outline:2px solid var(--color-accent);outline-offset:2px}.hidden{display:none}@media (max-width:860px){body{grid-template-columns:minmax(0,1fr);grid-template-areas:"title" "main" "bar"}aside{display:none}}@media (prefers-reduced-motion:no-preference){html{scroll-behavior:smooth}}`;

const SCRIPT = `(() => {
  const rows = [...document.querySelectorAll("table.inv tbody tr")];
  const chips = [...document.querySelectorAll("[data-filter-state]")];
  const q = document.getElementById("q"), ms = document.getElementById("milestone");
  const result = document.getElementById("result"), clear = document.getElementById("clear");
  function apply() {
    const states = chips.filter(c => c.getAttribute("aria-pressed") === "true").map(c => c.dataset.filterState);
    const term = q.value.trim().toLowerCase(), m = ms.value;
    let n = 0;
    for (const r of rows) {
      const ph = +r.dataset.phase;
      const okPhase = m === "all" || (m === "7" ? ph === 7 : ph <= +m);
      const ok = (!states.length || states.includes(r.dataset.state)) && okPhase && (!term || r.dataset.search.includes(term));
      r.classList.toggle("hidden", !ok); if (ok) n++;
    }
    for (const t of document.querySelectorAll("table.inv")) {
      const vis = t.querySelectorAll("tbody tr:not(.hidden)").length;
      t.closest(".table-wrap").classList.toggle("hidden", vis === 0);
    }
    const active = states.length || term || m !== "all";
    result.textContent = active ? n + " 行匹配" : rows.length + " 行";
    clear.classList.toggle("hidden", !active);
  }
  chips.forEach(c => c.addEventListener("click", () => { c.setAttribute("aria-pressed", c.getAttribute("aria-pressed") === "true" ? "false" : "true"); apply(); }));
  q.addEventListener("input", apply); ms.addEventListener("change", apply);
  clear.addEventListener("click", () => { chips.forEach(c => c.setAttribute("aria-pressed", "false")); q.value = ""; ms.value = "all"; apply(); q.focus(); });
  document.addEventListener("keydown", e => { if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); q.focus(); } if (e.key === "Escape" && document.activeElement === q && q.value) { q.value = ""; apply(); } });
  const theme = document.getElementById("theme"), root = document.documentElement;
  const saved = localStorage.getItem("picsee-ledger-theme") || "system";
  const setTheme = v => { v === "system" ? root.removeAttribute("data-theme") : root.setAttribute("data-theme", v); };
  theme.value = saved; setTheme(saved); theme.addEventListener("change", () => { localStorage.setItem("picsee-ledger-theme", theme.value); setTheme(theme.value); });
  const links = [...document.querySelectorAll("aside a.nav-row")];
  const heads = links.map(a => document.getElementById(decodeURIComponent(a.hash.slice(1)))).filter(Boolean);
  const main = document.getElementById("main");
  main.addEventListener("scroll", () => { let cur = null; for (const h of heads) if (h.getBoundingClientRect().top < 120) cur = h.id; links.forEach(a => a.classList.toggle("active", decodeURIComponent(a.hash.slice(1)) === cur)); }, { passive: true });
  apply();
})();`;

function generate(markdown) {
  const blocks = parseMarkdown(markdown);
  const { counts, areas, documents } = analyze(blocks);
  const total = STATES.reduce((sum, state) => sum + counts[state], 0);
  const digest = createHash("sha256").update(markdown).digest("hex").slice(0, 12);
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>功能账簿 · Mado</title>
<style>
${STYLE}
</style>
</head>
<body>
<header class="titlebar"><span class="lights" aria-hidden="true"><i></i><i></i><i></i></span><span>Mado · 功能账簿</span></header>
${renderSidebar(areas, documents)}
<main id="main">
<div class="content">
${renderContent(blocks, counts)}
</div>
</main>
<footer class="statusbar">
<span>${total} 项能力</span><span>·</span><span>${STATES.map((state) => `${state} ${counts[state]}`).join(" · ")}</span>
<span class="spacer"></span>
<span>由 docs/feature-ledger.md 生成 · sha256 ${digest} · 请勿手改</span>
<label for="theme" class="result">外观</label>
<select id="theme"><option value="system">跟随系统</option><option value="light">浅色</option><option value="dark">深色</option></select>
</footer>
<script>
${SCRIPT}
</script>
</body>
</html>
`;
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const expected = generate(readFileSync(options.source, "utf8"));
  if (options.check) {
    let actual = "";
    try { actual = readFileSync(options.output, "utf8"); } catch {}
    if (actual !== expected) {
      process.stderr.write("feature ledger HTML is stale; run npm run ledger:build\n");
      process.exitCode = 1;
    }
    return;
  }
  writeFileSync(options.output, expected);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
