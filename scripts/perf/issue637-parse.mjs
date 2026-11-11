// #637 measurement math. Inputs are parsed `log show --signpost --style ndjson` events
// from p308-parse.mjs and process RSS samples. No system calls or fabricated values.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseNdjson } from './p308-parse.mjs';
export const UNKNOWN = 'unknown';

const fields = (message) => Object.fromEntries([...String(message).matchAll(/([A-Za-z_]+)=([^\s]+)/g)]
  .map((match) => [match[1], match[2]]));

const metric = (values) => {
  const ordered = values.filter((value) => Number.isFinite(value) && value >= 0).sort((a, b) => a - b);
  const at = (fraction) => ordered[Math.max(0, Math.ceil(ordered.length * fraction) - 1)] ?? null;
  return { count: ordered.length, values: ordered, min: ordered[0] ?? null,
    p50: at(0.5), p95: at(0.95), max: ordered.at(-1) ?? null };
};

const ticketKey = (event) => {
  const ticket = fields(event.message).ticket;
  return /^\d+$/.test(ticket ?? '') ? `${event.id}:${ticket}` : null;
};

/**
 * Request→present is backdrop lag, not plan §10.2 input→state feedback. Event times
 * come from one machine's unified log; CPU ns comes from the rendering thread.
 */
export function summarizeIssue637(events, memorySamples = []) {
  const sorted = [...events].sort((a, b) => a.us - b.us);
  const requests = new Map();
  const renderBegins = new Map();
  const rendered = new Set();
  const presented = new Set();
  const cpuMs = [], renderWallMs = [], lagMs = [], presentUs = [];
  let invalidPresentations = 0, failedRenders = 0, renderAttempts = 0;
  for (const event of sorted) {
    const key = ticketKey(event);
    if (event.name === 'ChromeBackdropRequest' && event.type === 'event') {
      if (key && !requests.has(key)) requests.set(key, event);
    } else if (event.name === 'ChromeBackdropRender' && event.type === 'begin') {
      renderAttempts += 1;
      if (key) renderBegins.set(key, event);
    } else if (event.name === 'ChromeBackdropRender' && event.type === 'end') {
      const begin = key ? renderBegins.get(key) : null;
      if (key) renderBegins.delete(key);
      const data = fields(event.message);
      if (data.outcome !== 'rendered') failedRenders += 1;
      if (begin && event.us >= begin.us && data.outcome === 'rendered') {
        rendered.add(key);
        renderWallMs.push((event.us - begin.us) / 1000);
        const ns = Number(data.cpu_ns);
        if (/^\d+$/.test(data.cpu_ns ?? '') && Number.isSafeInteger(ns)) cpuMs.push(ns / 1_000_000);
      }
    } else if (event.name === 'ChromeBackdropPresent' && event.type === 'event') {
      const request = key ? requests.get(key) : null;
      if (!request || event.us < request.us || !rendered.has(key) || presented.has(key)) {
        invalidPresentations += 1;
      } else {
        presented.add(key);
        lagMs.push((event.us - request.us) / 1000);
        presentUs.push(event.us);
      }
    }
  }
  const superseded = [...requests.keys()].filter((key) => !presented.has(key)
    && [...requests.keys()].some((other) => other.startsWith(key.split(':')[0] + ':')
      && Number(other.split(':')[1]) > Number(key.split(':')[1]))).length;
  const memory = memorySamples.filter((sample) => Number.isFinite(sample.us)
    && Number.isFinite(sample.rssBytes) && sample.rssBytes >= 0).sort((a, b) => a.us - b.us);
  const presentIntervals = [];
  for (let i = 1; i < presentUs.length; i += 1) presentIntervals.push((presentUs[i] - presentUs[i - 1]) / 1000);
  return {
    requests: requests.size,
    presented: presented.size,
    superseded,
    pending: requests.size - presented.size - superseded,
    invalidPresentations,
    renderAttempts,
    failedRenders,
    renderCpuMs: metric(cpuMs),
    renderWallMs: metric(renderWallMs),
    requestToPresentMs: metric(lagMs),
    interPresentationMs: metric(presentIntervals),
    peakRssBytes: memory.length ? Math.max(...memory.map((sample) => sample.rssBytes)) : UNKNOWN,
    retainedRssBytes: memory.length >= 2 ? memory.at(-1).rssBytes - memory[0].rssBytes : UNKNOWN,
    gpuTimeMs: UNKNOWN,
    allocations: UNKNOWN,
    inputToStateFeedbackP95Ms: UNKNOWN,
    inputFeedbackTargetMet: UNKNOWN,
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const options = {};
    for (let i = 2; i < process.argv.length; i += 2) {
      const flag = process.argv[i];
      if (!['--log', '--rss', '--meta', '--out'].includes(flag) || !process.argv[i + 1]) {
        throw new Error('usage: issue637-parse.mjs --log LOG.ndjson --rss RSS.ndjson --meta META.json --out REPORT.json');
      }
      options[flag.slice(2)] = process.argv[i + 1];
    }
    if (Object.keys(options).length !== 4) throw new Error('all four input/output paths are required');
    const parsed = parseNdjson(readFileSync(options.log, 'utf8'));
    const rss = readFileSync(options.rss, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
    const meta = JSON.parse(readFileSync(options.meta, 'utf8'));
    const metrics = summarizeIssue637(parsed.events, rss);
    const report = { metadata: meta, metrics, diagnostics: { skippedLogLines: parsed.skipped },
      definitions: {
        renderCpuMs: 'CLOCK_THREAD_CPUTIME_ID around synchronous backdrop render; per completed update',
        requestToPresentMs: 'ChromeBackdropRequest signpost to ChromeBackdropPresent at NSView bitmap assignment; not WindowServer display or input feedback',
        retainedRssBytes: 'last observed process RSS minus first observed RSS; process-wide, not a leak proof',
        gpuTimeMs: 'unknown unless an external GPU trace is supplied',
        allocations: 'unknown; RSS does not count allocations',
        inputToStateFeedbackP95Ms: 'unknown; this run does not instrument plan section 10.2 input-to-state feedback',
        frameAndHitchDistribution: 'unknown; inter-presentation intervals are updates, not display frames',
      } };
    writeFileSync(options.out, JSON.stringify(report, null, 2) + '\n');
    if (metrics.presented < 30 || metrics.renderCpuMs.count < 30) {
      throw new Error(`inconclusive: ${metrics.presented} presentations and ${metrics.renderCpuMs.count} CPU samples (<30)`);
    }
    if (metrics.invalidPresentations > 0 || metrics.failedRenders > 0) {
      throw new Error(`inconclusive: ${metrics.invalidPresentations} invalid presentations, ${metrics.failedRenders} failed renders`);
    }
    process.stdout.write(`MEASURED presentations=${metrics.presented} CPU-p95-ms=${metrics.renderCpuMs.p95} lag-p95-ms=${metrics.requestToPresentMs.p95}\n`);
  } catch (error) {
    process.stderr.write(`INCONCLUSIVE issue637 perf: ${error.message}\n`);
    process.exitCode = 1;
  }
}
