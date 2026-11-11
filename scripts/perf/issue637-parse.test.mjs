import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { summarizeIssue637 } from './issue637-parse.mjs';

const event = (name, type, us, id, message = '') => ({
  name, type, us, id: String(id), pid: 42, message,
});

test('pairs real presentations to the newest request and reports CPU and lag without inventing other metrics', () => {
  const events = [
    event('ChromeBackdropRequest', 'event', 1000, 10, 'ticket=1 frame=5'),
    event('ChromeBackdropRequest', 'event', 2000, 10, 'ticket=2 frame=6'),
    event('ChromeBackdropRender', 'begin', 3000, 10, 'ticket=2'),
    event('ChromeBackdropRender', 'end', 5000, 10, 'ticket=2 cpu_ns=1200000 outcome=rendered'),
    event('ChromeBackdropPresent', 'event', 7000, 10, 'ticket=2 frame=6'),
    event('ChromeBackdropRequest', 'event', 8000, 11, 'ticket=1 frame=6'),
    event('ChromeBackdropRender', 'begin', 9000, 11, 'ticket=1'),
    event('ChromeBackdropRender', 'end', 12000, 11, 'ticket=1 cpu_ns=2300000 outcome=rendered'),
    event('ChromeBackdropPresent', 'event', 14000, 11, 'ticket=1 frame=6'),
  ];
  const report = summarizeIssue637(events, [
    { us: 0, rssBytes: 100_000_000 }, { us: 15_000, rssBytes: 101_000_000 },
  ]);
  assert.equal(report.requests, 3);
  assert.equal(report.presented, 2);
  assert.equal(report.superseded, 1);
  assert.deepEqual(report.renderCpuMs.values, [1.2, 2.3]);
  assert.deepEqual(report.requestToPresentMs.values, [5, 6]);
  assert.equal(report.renderCpuMs.p95, 2.3);
  assert.equal(report.requestToPresentMs.p95, 6);
  assert.equal(report.retainedRssBytes, 1_000_000);
  assert.equal(report.gpuTimeMs, 'unknown');
  assert.equal(report.allocations, 'unknown');
  assert.equal(report.inputToStateFeedbackP95Ms, 'unknown');
  assert.equal(report.inputFeedbackTargetMet, 'unknown');
});

test('missing completion and malformed CPU fields cannot become a successful measurement', () => {
  const events = [
    event('ChromeBackdropRequest', 'event', 1000, 10, 'ticket=1 frame=1'),
    event('ChromeBackdropRender', 'begin', 1100, 10, 'ticket=1'),
    event('ChromeBackdropRender', 'end', 1800, 10, 'ticket=1 cpu_ns=unknown outcome=failed'),
    event('ChromeBackdropRequest', 'event', 2000, 10, 'ticket=2 frame=2'),
    event('ChromeBackdropPresent', 'event', 1900, 10, 'ticket=2 frame=2'),
    event('ChromeBackdropRequest', 'event', 3000, 11, 'ticket=1 frame=2'),
    event('ChromeBackdropPresent', 'event', 4000, 11, 'ticket=1 frame=2'),
  ];
  const report = summarizeIssue637(events, []);
  assert.equal(report.presented, 0);
  assert.equal(report.invalidPresentations, 2);
  assert.equal(report.failedRenders, 1);
  assert.equal(report.retainedRssBytes, 'unknown');
  assert.equal(report.renderCpuMs.count, 0);
  assert.equal(report.requestToPresentMs.count, 0);
});

test('nearest-rank p95 uses all valid samples and never claims input-feedback p95 from backdrop lag', () => {
  const events = [];
  for (let i = 1; i <= 40; i += 1) {
    const start = i * 100_000;
    events.push(event('ChromeBackdropRequest', 'event', start, 10, `ticket=${i} frame=${i}`));
    events.push(event('ChromeBackdropRender', 'begin', start + 100, 10, `ticket=${i}`));
    events.push(event('ChromeBackdropRender', 'end', start + i * 1000, 10,
      `ticket=${i} cpu_ns=${i * 100_000} outcome=rendered`));
    events.push(event('ChromeBackdropPresent', 'event', start + i * 1000 + 100, 10,
      `ticket=${i} frame=${i}`));
  }
  const report = summarizeIssue637(events, []);
  assert.equal(report.requestToPresentMs.count, 40);
  assert.equal(report.requestToPresentMs.p95, 38.1);
  assert.equal(report.inputToStateFeedbackP95Ms, 'unknown');
  assert.equal(report.inputFeedbackTargetMet, 'unknown');
});

test('offline CLI writes an honest inconclusive report for absent signposts', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'issue637-parse-'));
  const log = path.join(dir, 'log.ndjson');
  const rss = path.join(dir, 'rss.ndjson');
  const meta = path.join(dir, 'meta.json');
  const out = path.join(dir, 'report.json');
  writeFileSync(log, '');
  writeFileSync(rss, '');
  writeFileSync(meta, JSON.stringify({ configuration: 'Release' }));
  const result = spawnSync(process.execPath, ['scripts/perf/issue637-parse.mjs', '--log', log,
    '--rss', rss, '--meta', meta, '--out', out], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /inconclusive: 0 presentations/);
  const report = JSON.parse(readFileSync(out, 'utf8'));
  assert.equal(report.metrics.presented, 0);
  assert.equal(report.metrics.inputToStateFeedbackP95Ms, 'unknown');
  assert.equal(report.definitions.frameAndHitchDistribution.startsWith('unknown'), true);
});
