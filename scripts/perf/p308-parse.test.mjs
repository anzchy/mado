// node --test scripts/perf/p308-parse.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  SUBSYSTEM, UNKNOWN, analyze, fields, mergeSampleLogs, pairIntervals, parseNdjson, percentile, quoteSignpostIDs, renderReport,
  renderResources, summary, timestampMicros,
} from './p308-parse.mjs';

const table = JSON.parse(readFileSync(fileURLToPath(new URL('./fixtures/signpost-messages.json', import.meta.url)), 'utf8'));
/** A shared-table message with its generation (and optionally other fields) replaced. */
function message(key, replace = {}) {
  const source = table.package[key] ?? table.app[key];
  assert.ok(source, `no table entry ${key}`);
  let text = source;
  for (const [field, v] of Object.entries(replace)) {
    assert.match(text, new RegExp(`\\b${field}=\\S*`), `${key} has no ${field}=`);
    text = text.replace(new RegExp(`\\b${field}=\\S*`), `${field}=${v}`);
  }
  return text;
}

const BASE = Date.UTC(2026, 10, 1, 4, 0, 0) * 1000; // µs; rendered below in +08:00
/** One `log show --signpost --style ndjson` line, signpostID unquoted as the tool prints it. */
function line({ type, name, id = '17216892719917625070', pid = 501, us, msg = '', subsystem = SUBSYSTEM, category = 'grid' }) {
  const local = new Date((us + 8 * 3600 * 1e6) / 1000);
  const frac = String(us % 1_000_000).padStart(6, '0');
  const stamp = `${local.toISOString().slice(0, 19).replace('T', ' ')}.${frac}+0800`;
  return `{"eventType":"signpostEvent","signpostID":${id},"signpostScope":"process","subsystem":"${subsystem}",`
    + `"category":"${category}","signpostType":"${type}","timestamp":"${stamp}","signpostName":"${name}",`
    + `"processID":${pid},"eventMessage":${JSON.stringify(msg)}}`;
}

/** A complete sample: scan begin at t, scan end at t+scan, grid begin at scan end, grid end at t+total (ms). */
function sampleLines({ pid = 501, g, t, scan = 100, total = 300, outcome = 'complete', failed = 0, scanID }) {
  const at = (msOffset) => t + Math.round(msOffset * 1000);
  const sid = scanID ?? String(9_000_000_000_000_000_000n + BigInt(g));
  return [
    line({ type: 'begin', name: 'FolderScan', id: sid, pid, us: at(0), msg: message('FolderScan.begin', { generation: g }), category: 'filesystem' }),
    line({ type: 'event', name: 'scan_complete', id: '0', pid, us: at(scan), msg: message('scan_complete', { count: 5000, generation: g }), category: 'filesystem' }),
    line({ type: 'end', name: 'FolderScan', id: sid, pid, us: at(scan), msg: message('FolderScan.end', { generation: g }), category: 'filesystem' }),
    line({ type: 'begin', name: 'GridFirstThumbnails', id: `${g}1`, pid, us: at(scan + 1), msg: message('GridFirstThumbnails.begin', { generation: g }) }),
    line({ type: 'end', name: 'GridFirstThumbnails', id: `${g}1`, pid, us: at(total),
           msg: message('GridFirstThumbnails.end', { outcome, generation: g, failed, shown: 24 - failed }) }),
  ];
}
const window = (index, t, { pid = 501, priming = false, span = 2000 } = {}) => ({ index, pid, startUs: t - 1000, endUs: t + span * 1000, priming });

test('timestamps keep microseconds and honour the offset', () => {
  assert.equal(timestampMicros('2026-11-01 12:00:00.000001+0800'), Date.UTC(2026, 10, 1, 4, 0, 0) * 1000 + 1);
  assert.equal(timestampMicros('2026-11-01 04:00:00.5+0000') - timestampMicros('2026-11-01 12:00:00.000000+0800'), 500_000);
  assert.equal(timestampMicros('2026-11-01 03:59:59.999999-0100') - timestampMicros('2026-11-01 04:59:59.999998+0000'), 1);
  assert.throws(() => timestampMicros('yesterday'));
});

test('64-bit signpost IDs survive parsing exactly', () => {
  assert.equal(quoteSignpostIDs('{"signpostID":17216892719917625070,"x":1}'), '{"signpostID":"17216892719917625070","x":1}');
  const { events } = parseNdjson([
    line({ type: 'begin', name: 'Decode', id: '17216892719917625070', us: BASE }),
    line({ type: 'end', name: 'Decode', id: '17216892719917625071', us: BASE + 5 }),
  ].join('\n'));
  assert.deepEqual(events.map((e) => e.id), ['17216892719917625070', '17216892719917625071']);
  assert.equal(pairIntervals(events, 'Decode').intervals.length, 0, 'IDs differing in the last digit were paired');
});

test('only picsee signposts are kept; junk lines are counted, not fatal', () => {
  const text = [line({ type: 'event', name: 'X', us: BASE, subsystem: 'com.apple.AppKit' }),
    '{"eventType":"logEvent","subsystem":"io.github.anzchy.picsee"}', 'not json', '',
    line({ type: 'event', name: 'ThumbnailDiskLookup', us: BASE + 1, msg: message('ThumbnailDiskLookup.hit') })].join('\n');
  const { events, skipped } = parseNdjson(text);
  assert.equal(events.length, 1);
  assert.equal(skipped, 1);
});

test('fields read the shared-table formats', () => {
  assert.deepEqual(fields(table.package['GridFirstThumbnails.end']),
    { outcome: 'complete', generation: '7', visible: '24', shown: '23', failed: '1' });
  assert.deepEqual(fields(table.package.MemoryCacheEviction), { tier: 'detail', bytes: '4096', reason: 'budget' });
  assert.equal(fields(table.app['FolderScan.begin']).generation, '7');
});

test('nearest-rank percentiles on shuffled vectors', () => {
  const shuffled = (n) => Array.from({ length: n }, (_, i) => i + 1).sort((a, b) => ((a * 7919) % n) - ((b * 7919) % n));
  assert.equal(percentile(shuffled(30), 50), 15);
  assert.equal(percentile(shuffled(30), 95), 29);
  assert.equal(percentile(shuffled(31), 50), 16);
  assert.equal(percentile(shuffled(31), 95), 30);
  assert.equal(percentile([42], 95), 42);
  assert.equal(percentile([5, 1, 5, 5, 1], 50), 5);
  assert.equal(percentile([], 50), null);
  assert.deepEqual(summary([3, 1, 2]), { n: 3, p50: 2, p95: 3, min: 1, max: 3 });
});

test('three samples: durations from timestamps, paired by generation not order', () => {
  const t = [BASE, BASE + 10_000_000, BASE + 20_000_000];
  // Generations out of order and lines shuffled across samples.
  const lines = [...sampleLines({ g: 12, t: t[0], scan: 100.25, total: 300.5 }),
    ...sampleLines({ g: 5, t: t[1], scan: 80, total: 250 }), ...sampleLines({ g: 9, t: t[2], scan: 0.4, total: 999.999 })];
  const { events } = parseNdjson(lines.reverse().join('\n'));
  const result = analyze(events, t.map((at, i) => window(i + 1, at)));
  assert.deepEqual(result.samples.map((s) => s.generation), ['12', '5', '9']);
  assert.deepEqual(result.samples.map((s) => s.openToGridMs), [300.5, 250, 999.999]);
  assert.deepEqual(result.samples.map((s) => s.scanMs), [100.25, 80, 0.4]);
  assert.equal(result.samples[2].gridAfterScanMs, 999.599);
  assert.equal(result.samples[0].items, 5000);
  assert.equal(result.valid, 3);
  assert.equal(result.p95Claimable, false, 'p95 claimed from 3 samples');
});

test('another pid in the same window is ignored', () => {
  const lines = [...sampleLines({ g: 1, t: BASE }), ...sampleLines({ g: 1, t: BASE + 5000, pid: 777, total: 5 })];
  const result = analyze(parseNdjson(lines.join('\n')).events, [window(1, BASE)]);
  assert.equal(result.samples[0].openToGridMs, 300);
  assert.deepEqual(result.samples[0].anomalies, []);
});

test('missing, duplicate, non-complete and reversed samples are listed and excluded, never dropped', () => {
  const t = (i) => BASE + i * 10_000_000;
  const lines = [
    ...sampleLines({ g: 1, t: t(0) }),
    ...sampleLines({ g: 2, t: t(1) }).slice(0, 4),                       // no grid end
    ...sampleLines({ g: 3, t: t(2), outcome: 'superseded' }),
    ...sampleLines({ g: 4, t: t(3) }), ...sampleLines({ g: 4, t: t(3) + 900_000 }).slice(3), // duplicate grid begin/end
    // sample 5: nothing recorded
    ...sampleLines({ g: 6, t: t(5), failed: 2 }),                       // valid, with a note
  ];
  const result = analyze(parseNdjson(lines.join('\n')).events, [0, 1, 2, 3, 4, 5].map((i) => window(i + 1, t(i))));
  assert.equal(result.samples.length, 6, 'a requested sample vanished');
  assert.deepEqual(result.samples.map((s) => s.valid), [true, false, false, false, false, true]);
  assert.match(result.samples[1].anomalies.join(), /0 GridFirstThumbnails ends/);
  assert.match(result.samples[2].anomalies.join(), /outcome=superseded/);
  assert.match(result.samples[3].anomalies.join(), /2 GridFirstThumbnails begins/);
  assert.match(result.samples[4].anomalies.join(), /no FolderScan begin/);
  assert.deepEqual(result.samples[5].notes, ['2 visible thumbnail(s) failed']);
  assert.equal(result.excluded, 4);
  assert.deepEqual(result.openToGrid.n, 2);
});

test('a grid end before its scan begin is an anomaly, not a negative duration', () => {
  const lines = sampleLines({ g: 8, t: BASE });
  lines.pop();
  lines.push(line({ type: 'end', name: 'GridFirstThumbnails', id: '81', us: BASE - 500_000,
    msg: message('GridFirstThumbnails.end', { generation: 8 }) }));
  const result = analyze(parseNdjson(lines.join('\n')).events, [{ index: 1, pid: 501, startUs: BASE - 1_000_000, endUs: BASE + 2_000_000 }]);
  assert.equal(result.samples[0].valid, false);
  assert.match(result.samples[0].anomalies.join(), /before FolderScan begin/);
  assert.equal(result.samples[0].openToGridMs, undefined);
});

test('two scans in one window, or a reused generation, are anomalies', () => {
  const lines = [...sampleLines({ g: 1, t: BASE }), ...sampleLines({ g: 2, t: BASE + 500_000 }),
    ...sampleLines({ g: 3, t: BASE + 10_000_000 }), ...sampleLines({ g: 3, t: BASE + 20_000_000, scanID: '42' })];
  const result = analyze(parseNdjson(lines.join('\n')).events,
    [window(1, BASE), window(2, BASE + 10_000_000), window(3, BASE + 20_000_000)]);
  assert.match(result.samples[0].anomalies.join(), /2 FolderScan begins/);
  assert.equal(result.samples[1].valid, true);
  assert.match(result.samples[2].anomalies.join(), /already used/);
});

test('priming is labelled and excluded; claimability needs ≥ 30 valid with none excluded', () => {
  const windows = [];
  const lines = [];
  for (let i = 0; i <= 30; i += 1) {
    const at = BASE + i * 10_000_000;
    lines.push(...sampleLines({ g: i + 1, t: at, total: i === 0 ? 1 : 300 + i }));
    windows.push(window(i, at, { priming: i === 0 }));
  }
  const all = analyze(parseNdjson(lines.join('\n')).events, windows);
  assert.equal(all.priming, 1);
  assert.equal(all.requested, 30);
  assert.equal(all.valid, 30);
  assert.equal(all.p95Claimable, true);
  assert.equal(all.openToGrid.min, 301, 'the priming open was counted');
  assert.equal(all.openToGrid.p95, 329);
  // 30 requested, 2 lost: not claimable even though 28 + 2 = 30.
  const lost = analyze(parseNdjson(lines.filter((l) => !/generation=(5|6)\b/.test(l)).join('\n')).events, windows);
  assert.equal(lost.valid, 28);
  assert.equal(lost.excluded, 2);
  assert.equal(lost.p95Claimable, false);
  // 33 requested with 3 empty windows: 30 valid but still not claimable (exclusions exist).
  const extra = [...windows, ...[31, 32, 33].map((i) => window(i, BASE + i * 10_000_000))];
  const gaps = analyze(parseNdjson(lines.join('\n')).events, extra);
  assert.equal(gaps.valid, 30);
  assert.equal(gaps.excluded, 3);
  assert.equal(gaps.p95Claimable, false);
});

test('work is counted inside the closed interval and outside it, Decode paired by signpost ID', () => {
  const t = BASE;
  const at = (msOffset) => t + Math.round(msOffset * 1000);
  const lines = [
    ...sampleLines({ g: 1, t, scan: 100, total: 300 }),
    line({ type: 'event', name: 'ThumbnailDiskLookup', id: '0', us: at(0), msg: message('ThumbnailDiskLookup.hit') }), // boundary: inside
    line({ type: 'event', name: 'ThumbnailDiskLookup', id: '0', us: at(300), msg: message('ThumbnailDiskLookup.miss') }), // boundary: inside
    line({ type: 'event', name: 'ThumbnailDiskLookup', id: '0', us: at(301), msg: message('ThumbnailDiskLookup.miss') }), // outside
    line({ type: 'event', name: 'MemoryCacheAdmission', id: '0', us: at(150), msg: message('MemoryCacheAdmission') }),
    line({ type: 'event', name: 'MemoryCacheEviction', id: '0', us: at(-0.5), msg: message('MemoryCacheEviction') }),   // outside
    line({ type: 'event', name: 'MemoryCacheEviction', id: '0', us: at(200), msg: message('MemoryCacheEviction', { reason: 'discarded' }) }),
    // Overlapping decodes b1 b2 e2 e1, plus one that starts before the interval and ends inside it.
    line({ type: 'begin', name: 'Decode', id: '11', us: at(110) }), line({ type: 'begin', name: 'Decode', id: '12', us: at(120) }),
    line({ type: 'end', name: 'Decode', id: '12', us: at(130) }), line({ type: 'end', name: 'Decode', id: '11', us: at(400) }),
    line({ type: 'begin', name: 'Decode', id: '13', us: at(-0.8) }), line({ type: 'end', name: 'Decode', id: '13', us: at(50) }),
    line({ type: 'begin', name: 'Decode', id: '14', us: at(500) }), line({ type: 'end', name: 'Decode', id: '14', us: at(600) }),
    line({ type: 'end', name: 'Decode', id: '99', us: at(700) }),
  ];
  const result = analyze(parseNdjson(lines.join('\n')).events, [window(1, t)]);
  const [s] = result.samples;
  assert.deepEqual(s.inside, { diskHit: 1, diskMiss: 1, memoryAdmission: 1, memoryEviction: 0, memoryDiscard: 1, decode: 1, decodeStraddling: 2 });
  assert.deepEqual(s.outside, { diskHit: 0, diskMiss: 1, memoryAdmission: 0, memoryEviction: 1, memoryDiscard: 0, decode: 1, decodeStraddling: 0 });
  assert.equal(result.unmatchedDecodeEnds, 1);
  const paired = pairIntervals(parseNdjson(lines.join('\n')).events, 'Decode').intervals;
  assert.deepEqual(paired.map((d) => [d.id, (d.endUs - d.beginUs) / 1000]).sort(), [['11', 290], ['12', 10], ['13', 50.8], ['14', 100]]);
});

test('the report answers what it can and writes 未知 for the rest; no numbers when there are none', () => {
  const empty = analyze([], [window(1, BASE)]);
  const report = renderReport({ runID: 'p308-test', cacheState: 'cold-app', tier: 'S2' }, empty);
  for (const n of [1, 2, 3, 4, 5, 6, 7]) assert.match(report, new RegExp(`^${n}\\. `, 'm'), `question ${n} missing`);
  assert.match(report, /SHA 未知；签名 未知；配置 未知/);
  assert.match(report, /p95 不可宣称：有效样本 0\/1/);
  assert.match(report, /\| open → grid \| 0 \| — \| —（不可宣称） \| — \| — \|/);
  assert.match(report, /no FolderScan begin/);
  assert.match(report, /\| 待判定 \|$/m);
  assert.ok(!/\d+\.\d{3}/.test(report), 'a duration appeared with no samples');
  assert.ok(report.includes(UNKNOWN));
});

test('the report carries raw values and the checklist row for a claimable run', () => {
  const windows = [];
  const lines = [];
  for (let i = 0; i < 30; i += 1) {
    const at = BASE + i * 10_000_000;
    lines.push(...sampleLines({ g: i + 1, t: at, total: 200 + i }));
    windows.push(window(i + 1, at));
  }
  const result = analyze(parseNdjson(lines.join('\n')).events, windows);
  const report = renderReport({ runID: 'r1', buildSHA: 'abc1234', signing: 'Developer ID', configuration: 'Release',
    machine: 'Mac16,10', macOS: '26.4', scale: 1, storage: 'SSD', tier: 'S2', cacheState: 'warm-disk' }, result);
  assert.match(report, /\| open → grid \| 30 \| 214\.000 \| 228\.000 \| 200\.000 \| 229\.000 \|/);
  assert.match(report, /^\| 30 \| 501 \| 30 \| 否 \| 是 \| 229\.000 \|/m);
  assert.match(report, /abc1234，Developer ID，Release/);
});

test('resource rows: three rounds, high-water configured against observed, growth left to the reader', () => {
  const rounds = [{ round: 1, rssKB: 100, diskBytes: 10, snapshot: 'entries=1' }, { round: 2, rssKB: 110, diskBytes: 30 },
    { round: 3, rssKB: 105, diskBytes: 20 }];
  const known = renderResources({ runID: 'r', diskHighWaterBytes: 25 }, rounds);
  assert.match(known, /配置 25；观测最大 30（高于配置）/);
  assert.match(known, /\| 2 \| 110 \| 30 \| 未知 \|/);
  assert.match(known, /线性增长：未判定/);
  assert.match(renderResources({ runID: 'r' }, rounds), /配置 未知；观测最大 30$/m);
  assert.match(renderResources({ runID: 'r', diskHighWaterBytes: 40 }, rounds), /（不高于配置）/);
});

// Rows cut from a real `log show --signpost --style ndjson` of a Picsee build (FolderScan and Decode only, which
// existed before #146); paths, IDs and timestamps replaced. Guards the field names the parser reads.
test('real log show rows parse with the fields the parser reads', () => {
  const text = readFileSync(fileURLToPath(new URL('./fixtures/log-show-schema.ndjson', import.meta.url)), 'utf8');
  const { events, skipped } = parseNdjson(text);
  assert.equal(skipped, 0);
  assert.deepEqual(events.map((e) => `${e.name}.${e.type}`), ['FolderScan.begin', 'Decode.begin', 'Decode.end', 'FolderScan.end']);
  assert.ok(events.every((e) => e.pid === 4242 && e.category));
  assert.equal(fields(events[0].message).generation, '7');
  assert.equal(fields(events[3].message).outcome, 'complete');
  assert.equal(events[3].us - events[0].us, 750_000);
  const decodes = pairIntervals(events, 'Decode');
  assert.equal(decodes.intervals.length, 1);
  assert.equal(decodes.unmatchedEnds.length + decodes.unfinished.length, 0);
  // The same scan and generation as the shared table's App messages.
  assert.equal(events[0].message, message('FolderScan.begin'));
  assert.equal(events[3].message, message('FolderScan.end'));
});

// warm-memory: one pid, and each sample's log starts before its window, so file 2 repeats the end of sample 1.
test('overlapping sample logs of one process count each event once', () => {
  const t1 = BASE, t2 = BASE + 1_000_000;
  const first = sampleLines({ g: 1, t: t1, total: 400 });
  const second = sampleLines({ g: 2, t: t2, total: 400 });
  const disk = line({ type: 'event', name: 'ThumbnailDiskLookup', id: '0', us: t1 + 200_000, msg: message('ThumbnailDiskLookup.hit'), category: 'performance' });
  const fileOne = [...first, disk].join('\n');
  const fileTwo = [first[3], disk, first[4], ...second].join('\n'); // started before sample 1's grid end
  const windows = [{ index: 1, pid: 501, startUs: t1 - 1000, endUs: t1 + 600_000 }, { index: 2, pid: 501, startUs: t2 - 1000, endUs: t2 + 600_000 }];
  const naive = analyze([fileOne, fileTwo].flatMap((text) => parseNdjson(text).events), windows);
  assert.equal(naive.valid, 1, 'concatenating the files duplicates sample 1 (the defect this guards)');
  const { events, skipped } = mergeSampleLogs([fileOne, fileTwo]);
  assert.equal(skipped, 0);
  assert.equal(events.length, first.length + second.length + 1);
  const result = analyze(events, windows);
  assert.equal(result.valid, 2);
  assert.deepEqual(result.samples.map((s) => s.openToGridMs), [400, 400]);
  assert.equal(result.samples[0].inside.diskHit, 1);
  assert.equal(result.samples[1].inside.diskHit + result.samples[1].outside.diskHit, 0);
});

// Fix round 1 (#146 opus M1): identical rows inside one file are two genuine events (a burst of equal-size evictions
// in the same microsecond); only a re-print of an earlier, overlapping file is dropped.
test('identical events inside one file are all kept; only overlap re-prints are dropped', () => {
  const evict = line({ type: 'event', name: 'MemoryCacheEviction', id: '0', us: BASE + 5, msg: message('MemoryCacheEviction'), category: 'performance' });
  const other = line({ type: 'event', name: 'MemoryCacheAdmission', id: '0', us: BASE + 9, msg: message('MemoryCacheAdmission'), category: 'performance' });
  assert.equal(parseNdjson([evict, evict].join('\n')).events.length, 2);
  assert.equal(mergeSampleLogs([[evict, evict].join('\n')]).events.length, 2, 'one file: both evictions are real');
  // File two overlaps file one: it re-prints both evictions and adds its own event.
  const merged = mergeSampleLogs([[evict, evict].join('\n'), [evict, evict, other].join('\n')]).events;
  assert.deepEqual(merged.map((e) => e.name), ['MemoryCacheEviction', 'MemoryCacheEviction', 'MemoryCacheAdmission']);
  // A later file that saw three (one more than the earlier file printed) keeps three.
  assert.equal(mergeSampleLogs([[evict, evict].join('\n'), [evict, evict, evict].join('\n')]).events.length, 3);
});

// Fix round 1 (#146 opus M4): a pasted report says what the fixture is, not just its tier.
test('reports label the fixture content; S2 says tiny synthetic images, not photos', () => {
  const result = analyze([], []);
  const s2 = renderReport({ tier: 'S2' }, result);
  assert.match(s2, /内容：S2 为很小的合成图（PNG\/TIFF），不是照片/);
  assert.match(s2, /不证明真实照片解码吞吐/);
  assert.match(renderReport({ tier: 'S4', content: 'RAW 照片 200 张' }, result), /内容：RAW 照片 200 张/);
  assert.match(renderReport({ tier: 'S5' }, result), /内容：未知/);
  assert.match(renderResources({ tier: 'S2' }, []), /内容：S2 为很小的合成图/);
  assert.match(renderResources({ tier: 'S5' }, []), /内容：未知/);
});
