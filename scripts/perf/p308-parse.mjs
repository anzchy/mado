// P3-08 (#146) signpost parser and report renderer. Pure: no process, file or clock access, so
// p308-parse.test.mjs can drive it with recorded `log show --signpost --style ndjson` lines.
//
// Timed boundaries (plan §10, benchmark-checklist.md):
//   open → grid   FolderScan begin (pid, generation g) → GridFirstThumbnails end (pid, g, outcome=complete)
//   scan          FolderScan begin → FolderScan end
//   grid after    FolderScan end → GridFirstThumbnails end
// Work counted inside a sample's closed interval [FolderScan begin, GridFirstThumbnails end], and outside it
// (the rest of that sample's window), per sample and in total.

export const SUBSYSTEM = 'io.github.anzchy.mado';
export const UNKNOWN = '未知';
export const MIN_SAMPLES = 30;

/** What a tier's files are, from TestAssets/README.md, so a pasted report states its limits. */
const TIER_CONTENT = {
  S2: 'S2 为很小的合成图（PNG/TIFF），不是照片；只证明枚举与网格拓扑，不证明真实照片解码吞吐',
};
/** How p308.mjs starts the App (launch()); a report pasted alone still names its protocol. */
export const LAUNCH_METHOD = '启动方式：直接执行 `Contents/MacOS/Mado`，作为脚本跟踪的子进程，不经 LaunchServices（非 open）；'
  + '计时区间从就绪等待之后的驱动命令开始，不含 App 启动';

/** `--content` when given, else the README's description of the tier, else 未知. */
export function fixtureContent(meta) {
  return meta.content || TIER_CONTENT[meta.tier] || UNKNOWN;
}

/** `log show` prints signpostID as a 64-bit integer; JSON.parse would round it. Quote it first. */
export function quoteSignpostIDs(line) {
  return line.replace(/"signpostID":(\d+)/g, '"signpostID":"$1"');
}

/** "2026-11-01 12:26:38.579024+0800" → microseconds since the epoch (exact to the µs). */
export function timestampMicros(text) {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?([+-])(\d{2}):?(\d{2})$/.exec(text);
  if (!m) throw new Error(`unparseable timestamp: ${text}`);
  const [, y, mo, d, h, mi, s, frac = '', sign, oh, om] = m;
  const seconds = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s) / 1000;
  const offset = (sign === '-' ? -1 : 1) * (+oh * 3600 + +om * 60);
  const micros = Number((frac + '000000').slice(0, 6));
  return (seconds - offset) * 1_000_000 + micros;
}

/** Signpost events of picsee's subsystem from ndjson text; other lines are skipped (non-JSON lines are counted). */
export function parseNdjson(text) {
  const events = [];
  let skipped = 0;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    let row;
    try { row = JSON.parse(quoteSignpostIDs(line)); } catch { skipped += 1; continue; }
    if (row.eventType !== 'signpostEvent' || row.subsystem !== SUBSYSTEM) continue;
    events.push({
      type: row.signpostType, name: row.signpostName, id: String(row.signpostID), pid: Number(row.processID),
      us: timestampMicros(row.timestamp), message: row.eventMessage ?? '', category: row.category ?? '',
    });
  }
  events.sort((a, b) => a.us - b.us);
  return { events, skipped };
}

/**
 * Events of several sample logs as one list. Each sample's `log show` starts a little before its window, so in one
 * process (warm-memory) consecutive files overlap and re-print the same events. Identical rows (same pid, µs
 * timestamp, name, type, signpost ID and message) inside one file are distinct events (a burst of equal-size
 * evictions), so each identical row is kept as many times as the file that printed it most often.
 */
export function mergeSampleLogs(texts) {
  const kept = new Map(); // key → events kept so far
  let skipped = 0;
  for (const text of texts) {
    const parsed = parseNdjson(text);
    skipped += parsed.skipped;
    const inFile = new Map();
    for (const e of parsed.events) {
      const key = [e.pid, e.us, e.name, e.type, e.id, e.message].join('\u0000');
      if (!inFile.has(key)) inFile.set(key, []);
      inFile.get(key).push(e);
    }
    for (const [key, events] of inFile) {
      const have = kept.get(key) ?? [];
      if (events.length > have.length) kept.set(key, [...have, ...events.slice(have.length)]);
    }
  }
  const events = [...kept.values()].flat().sort((a, b) => a.us - b.us);
  return { events, skipped };
}

/** "outcome=complete generation=7 visible=3" → { outcome: 'complete', generation: '7', visible: '3' }. */
export function fields(message) {
  const out = {};
  for (const m of message.matchAll(/(\w+)=(\S*)/g)) out[m[1]] = m[2];
  return out;
}

/** Nearest-rank percentile (p in 0…100) of numbers in any order; null for none. */
export function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.max(1, Math.ceil((p / 100) * sorted.length));
  return sorted[rank - 1];
}

export function summary(values) {
  if (!values.length) return { n: 0, p50: null, p95: null, min: null, max: null };
  return { n: values.length, p50: percentile(values, 50), p95: percentile(values, 95),
           min: Math.min(...values), max: Math.max(...values) };
}

/** Decode intervals paired by (pid, signpost ID), never by order. Unmatched ends are reported, not invented. */
export function pairIntervals(events, name) {
  const open = new Map();
  const intervals = [];
  const unmatched = [];
  for (const e of events) {
    if (e.name !== name) continue;
    const key = `${e.pid}:${e.id}`;
    if (e.type === 'begin') open.set(key, e);
    else if (e.type === 'end') {
      const begin = open.get(key);
      if (begin) { open.delete(key); intervals.push({ pid: e.pid, id: e.id, beginUs: begin.us, endUs: e.us, end: e }); }
      else unmatched.push(e);
    }
  }
  return { intervals, unmatchedEnds: unmatched, unfinished: [...open.values()] };
}

const COUNTED = [
  ['diskHit', (e) => e.type === 'event' && e.name === 'ThumbnailDiskLookup' && fields(e.message).outcome === 'hit'],
  ['diskMiss', (e) => e.type === 'event' && e.name === 'ThumbnailDiskLookup' && fields(e.message).outcome === 'miss'],
  ['memoryAdmission', (e) => e.type === 'event' && e.name === 'MemoryCacheAdmission'],
  // reason=budget: evicted to fit capacity, budget or pressure; reason=discarded: stale, revoked, replaced or removed.
  ['memoryEviction', (e) => e.type === 'event' && e.name === 'MemoryCacheEviction' && fields(e.message).reason === 'budget'],
  ['memoryDiscard', (e) => e.type === 'event' && e.name === 'MemoryCacheEviction' && fields(e.message).reason === 'discarded'],
];
const zeroCounts = () => ({ diskHit: 0, diskMiss: 0, memoryAdmission: 0, memoryEviction: 0, memoryDiscard: 0,
                            decode: 0, decodeStraddling: 0 });

/**
 * One sample per recorded window ({ index, pid, startUs, endUs, priming }). Each window must hold exactly one
 * FolderScan begin for its pid; the grid end is the first GridFirstThumbnails end with that generation after it.
 * Every requested sample appears in the result: valid, or with the anomalies that excluded it.
 */
export function analyze(events, windows) {
  const decodes = pairIntervals(events, 'Decode');
  const samples = [];
  const seenScan = new Set();
  for (const w of windows) {
    const mine = events.filter((e) => e.pid === w.pid && e.us >= w.startUs && e.us <= w.endUs);
    const anomalies = [];
    const scanBegins = mine.filter((e) => e.name === 'FolderScan' && e.type === 'begin');
    const sample = { index: w.index, pid: w.pid, priming: Boolean(w.priming), anomalies, valid: false,
                     inside: zeroCounts(), outside: zeroCounts() };
    samples.push(sample);
    if (scanBegins.length !== 1) {
      anomalies.push(scanBegins.length ? `${scanBegins.length} FolderScan begins in one sample window` : 'no FolderScan begin');
      continue;
    }
    const begin = scanBegins[0];
    const generation = fields(begin.message).generation;
    sample.generation = generation;
    const key = `${w.pid}:${generation}`;
    if (seenScan.has(key)) anomalies.push(`generation ${generation} already used by an earlier sample`);
    seenScan.add(key);
    const scanEnds = mine.filter((e) => e.name === 'FolderScan' && e.type === 'end' && e.id === begin.id && e.us >= begin.us);
    const gridBegins = mine.filter((e) => e.name === 'GridFirstThumbnails' && e.type === 'begin'
      && fields(e.message).generation === generation);
    const gridEnds = mine.filter((e) => e.name === 'GridFirstThumbnails' && e.type === 'end'
      && fields(e.message).generation === generation);
    if (scanEnds.length !== 1) anomalies.push(`${scanEnds.length} FolderScan ends for generation ${generation}`);
    if (gridBegins.length !== 1) anomalies.push(`${gridBegins.length} GridFirstThumbnails begins for generation ${generation}`);
    if (gridEnds.length !== 1) anomalies.push(`${gridEnds.length} GridFirstThumbnails ends for generation ${generation}`);
    const scanEnd = scanEnds[0];
    const gridEnd = gridEnds[0];
    if (scanEnd) {
      sample.scanOutcome = fields(scanEnd.message).outcome;
      if (sample.scanOutcome !== 'complete') anomalies.push(`FolderScan outcome=${sample.scanOutcome}`);
    }
    if (gridEnd) {
      const f = fields(gridEnd.message);
      sample.gridOutcome = f.outcome;
      sample.visible = Number(f.visible); sample.shown = Number(f.shown); sample.failed = Number(f.failed);
      if (f.outcome !== 'complete') anomalies.push(`GridFirstThumbnails outcome=${f.outcome}`);
      if (sample.failed > 0) sample.notes = [`${sample.failed} visible thumbnail(s) failed`];
      if (gridEnd.us < begin.us) anomalies.push('GridFirstThumbnails end before FolderScan begin');
    }
    const complete = mine.find((e) => e.name === 'scan_complete' && fields(e.message).generation === generation);
    if (complete) sample.items = Number(fields(complete.message).count);
    if (!anomalies.length) {
      sample.valid = !sample.priming;
      sample.openToGridMs = (gridEnd.us - begin.us) / 1000;
      sample.scanMs = (scanEnd.us - begin.us) / 1000;
      sample.gridAfterScanMs = (gridEnd.us - scanEnd.us) / 1000;
      sample.intervalUs = [begin.us, gridEnd.us];
    }
    const [from, to] = sample.intervalUs ?? [Infinity, -Infinity];
    const inside = (us) => us >= from && us <= to;
    for (const e of mine) {
      for (const [name, match] of COUNTED) if (match(e)) sample[inside(e.us) ? 'inside' : 'outside'][name] += 1;
    }
    for (const d of decodes.intervals) {
      if (d.pid !== w.pid || d.endUs < w.startUs || d.beginUs > w.endUs) continue;
      if (inside(d.beginUs) && inside(d.endUs)) sample.inside.decode += 1;
      else if (inside(d.beginUs) || inside(d.endUs)) sample.inside.decodeStraddling += 1;
      else sample.outside.decode += 1;
    }
  }
  const valid = samples.filter((s) => s.valid);
  const measured = samples.filter((s) => !s.priming);
  return {
    samples,
    requested: measured.length,
    valid: valid.length,
    excluded: measured.length - valid.length,
    priming: samples.length - measured.length,
    p95Claimable: valid.length >= MIN_SAMPLES && valid.length === measured.length,
    openToGrid: summary(valid.map((s) => s.openToGridMs)),
    scan: summary(valid.map((s) => s.scanMs)),
    gridAfterScan: summary(valid.map((s) => s.gridAfterScanMs)),
    unmatchedDecodeEnds: decodes.unmatchedEnds.length,
    unfinishedDecodes: decodes.unfinished.length,
  };
}

const ms = (v) => (v === null || v === undefined ? '—' : v.toFixed(3));
const value = (v) => (v === undefined || v === null || v === '' ? UNKNOWN : String(v));

function sumCounts(samples, side) {
  const total = zeroCounts();
  for (const s of samples) for (const k of Object.keys(total)) total[k] += s[side][k];
  return total;
}
const countText = (c) => `disk hit ${c.diskHit} / miss ${c.diskMiss}; memory admit ${c.memoryAdmission} / evict ${c.memoryEviction} / discard ${c.memoryDiscard}; `
  + `Decode ${c.decode} (straddling ${c.decodeStraddling})`;

/** The run's Markdown block: raw values, statistics, counts, anomalies and the checklist, with 未知 for unknowns. */
export function renderReport(meta, result) {
  const lines = [];
  const claim = result.p95Claimable ? '' : `（p95 不可宣称：有效样本 ${result.valid}/${result.requested}，需 ≥ ${MIN_SAMPLES} 且无排除）`;
  lines.push(`### 运行 \`${value(meta.runID)}\`（P3-08 测量脚本输出）`, '');
  lines.push(`- 构建：SHA ${value(meta.buildSHA)}；签名 ${value(meta.signing)}；配置 ${value(meta.configuration)}；调优设置 ${value(meta.tuning)}`);
  lines.push(`- 机器：${value(meta.machine)}；macOS ${value(meta.macOS)}；显示 scale ${value(meta.scale)}；存储 ${value(meta.storage)}`);
  lines.push(`- 素材：档位 ${value(meta.tier)}；路径 ${value(meta.fixture)}；文件数 ${value(meta.fixtureFiles)}；manifest ${value(meta.manifest)}`);
  lines.push(`- 内容：${fixtureContent(meta)}`);
  lines.push(`- ${LAUNCH_METHOD}`);
  lines.push(`- 缓存状态：${value(meta.cacheState)}（冷应用缓存不等于 OS 文件页缓存已清空）`);
  lines.push(`- 样本：请求 ${result.requested}，有效 ${result.valid}，排除 ${result.excluded}，预热 ${result.priming}${claim}`);
  lines.push(`- 计时边界：open→grid = FolderScan begin → GridFirstThumbnails end（outcome=complete，同 pid 与 generation）；`
    + 'scan = FolderScan begin → end；grid after scan = FolderScan end → GridFirstThumbnails end', '');
  lines.push('| 指标 (ms) | n | p50 | p95 | min | max |', '|---|---|---|---|---|---|');
  for (const [label, s] of [['open → grid', result.openToGrid], ['scan', result.scan], ['grid after scan', result.gridAfterScan]]) {
    lines.push(`| ${label} | ${s.n} | ${ms(s.p50)} | ${result.p95Claimable ? ms(s.p95) : `${ms(s.p95)}（不可宣称）`} | ${ms(s.min)} | ${ms(s.max)} |`);
  }
  lines.push('', '| # | pid | generation | 预热 | 有效 | open→grid | scan | grid after | items | visible/shown/failed | 区间内计数 | 区间外计数 | 异常 |',
    '|---|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (const s of result.samples) {
    lines.push(`| ${s.index} | ${s.pid} | ${value(s.generation)} | ${s.priming ? '是' : '否'} | ${s.valid ? '是' : '否'} | ${ms(s.openToGridMs)} | `
      + `${ms(s.scanMs)} | ${ms(s.gridAfterScanMs)} | ${value(s.items)} | ${s.visible ?? '—'}/${s.shown ?? '—'}/${s.failed ?? '—'} | `
      + `${countText(s.inside)} | ${countText(s.outside)} | ${[...s.anomalies, ...(s.notes ?? [])].join('; ') || '—'} |`);
  }
  const measured = result.samples.filter((s) => !s.priming);
  lines.push('', `区间内合计：${countText(sumCounts(measured, 'inside'))}。区间外合计：${countText(sumCounts(measured, 'outside'))}。`
    + `未配对的 Decode end ${result.unmatchedDecodeEnds}，未结束的 Decode ${result.unfinishedDecodes}。`
    + 'straddling = 只有一端落在区间内的 Decode，不计入区间内。', '');
  lines.push('#### 七个问题（脚本能回答的部分；其余为 未知）', '');
  lines.push(`1. 限制因素：${UNKNOWN}（脚本只给出阶段耗时与区间内计数；需要人根据 scan / grid after scan 占比与 CPU/IO 证据判断）`);
  lines.push(`2. 交付方式调优：签名 ${value(meta.signing)}；配置 ${value(meta.configuration)}；调优设置 ${value(meta.tuning)}；单侧绝对测量，另一侧不适用`);
  lines.push(`3. 物理上限：${UNKNOWN}（需要本机核心数与存储吞吐估算；脚本记录了 items 与区间内 Decode 数）`);
  lines.push(`4. 错误/拒绝/错误输出：排除 ${result.excluded} 个样本（见上表“异常”）；正确性（缩略图对应关系）${UNKNOWN}，由 GRID-03 自动检查与真机观察另证`);
  lines.push(`5. 复现：原始值见上表与运行目录 samples/*.ndjson；单侧运行，无 A/B 交替`);
  lines.push(`6. 端到端：open → grid 即用户从文件夹扫描开始到可见缩略图全部到位的等待；打开面板与授权时间不在区间内`);
  lines.push(`7. 计时区间内的工作：见“区间内/外计数”；起止 signpost 为 FolderScan begin 与 GridFirstThumbnails end`, '');
  lines.push('| metric | build (signed Release config) | machine | fixture tier | runs | median / range | limiter | inside-timed-region evidence (signposts and counts) | verdict |',
    '|---|---|---|---|---|---|---|---|---|');
  const o = result.openToGrid;
  lines.push(`| open → grid (ms, ${value(meta.runID)}) | ${value(meta.buildSHA)}，${value(meta.signing)}，${value(meta.configuration)} | `
    + `${value(meta.machine)}，macOS ${value(meta.macOS)}，scale ${value(meta.scale)}，${value(meta.storage)} | ${value(meta.tier)}，${value(meta.cacheState)} | `
    + `${result.valid}/${result.requested}，samples/*.ndjson | ${ms(o.p50)} / ${ms(o.min)}–${ms(o.max)}；p95 ${result.p95Claimable ? ms(o.p95) : '不可宣称'} | `
    + `${UNKNOWN} | FolderScan begin → GridFirstThumbnails end；${countText(sumCounts(measured, 'inside'))} | 待判定 |`);
  return lines.join('\n') + '\n';
}

/**
 * Resource rows over repeated rounds ({ round, rssKB, diskBytes, snapshot }). The growth verdict is left to the
 * reader; the configured high-water mark is what the caller passes, else 未知.
 */
export function renderResources(meta, rounds) {
  const lines = [`### 资源行 \`${value(meta.runID)}\`（${rounds.length} 轮重复浏览）`, ''];
  lines.push('| 轮 | RSS (KiB) | 磁盘缓存 (bytes) | ResourceSnapshot |', '|---|---|---|---|');
  for (const r of rounds) lines.push(`| ${r.round} | ${value(r.rssKB)} | ${value(r.diskBytes)} | ${value(r.snapshot)} |`);
  const sizes = rounds.map((r) => r.diskBytes).filter((v) => typeof v === 'number');
  const observed = sizes.length ? Math.max(...sizes) : null;
  const configured = meta.diskHighWaterBytes;
  lines.push('', `- 磁盘缓存高水位：配置 ${value(configured)}；观测最大 ${value(observed)}`
    + (typeof configured === 'number' && observed !== null ? `（${observed <= configured ? '不高于' : '高于'}配置）` : ''));
  lines.push('- 线性增长：未判定（三轮数值见上表，由记录者判断并写明依据）');
  lines.push(`- 构建 ${value(meta.buildSHA)}；签名 ${value(meta.signing)}；配置 ${value(meta.configuration)}；素材 ${value(meta.tier)} ${value(meta.fixture)}`);
  lines.push(`- 内容：${fixtureContent(meta)}`);
  lines.push(`- ${LAUNCH_METHOD}`);
  return lines.join('\n') + '\n';
}
