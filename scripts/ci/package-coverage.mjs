#!/usr/bin/env node
// Validate and merge two independent SwiftPM LCOV exports before evaluating exact coverage.
import { createHash } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { coverageAtomicSwiftArgs, coverageAtomicScratchPath, ATOMIC_COVERAGE_FLAG_ID } from './coverage-atomic.mjs';

const modules = ['MadoCore', 'MadoApplication', 'MadoInfrastructure', 'MadoMacUI'];
const prefix = 'Packages/MadoKit/Sources/';
// Reviewed identity from i631-fn-astra.md B; #637 retired the stale ViewerChrome pin.
// The manifest supplies readable symbols and provenance; these pins prevent
// replacing the approved symbol or source by editing only the manifest.
const approvedFunctionIdentities = new Map([
  [`${prefix}MadoMacUI/Inspector/InspectorPanel.swift:191`, { symbolSha256: 'e55dd121048c133d38dd7d11d9ec25d52df5048ba7b5bf3dd2bd91718532ff6f', sourceSha256: '5ca22be215ecad2f711546e1569c959e5f41eacc0dd632332788e8d085b41477', decision: 'i631-fn-astra.md B' }],
]);
// The review decision freezes all 17 declaration-only paths. The canonical
// manifest digest also pins each whole-source SHA, rationale, toolchain and
// portable decision reference.
const approvedFileExceptionPaths = new Set([
  'Packages/MadoKit/Sources/MadoApplication/Access/ViewerSessionNavigationHost.swift',
  'Packages/MadoKit/Sources/MadoApplication/MadoApplication.swift',
  'Packages/MadoKit/Sources/MadoApplication/Viewer/FirstPreviewTracing.swift',
  'Packages/MadoKit/Sources/MadoApplication/Viewer/ViewerChromeScheduler.swift',
  'Packages/MadoKit/Sources/MadoApplication/Viewer/ViewerImageHost.swift',
  'Packages/MadoKit/Sources/MadoApplication/Viewer/ViewerSingleImageReturnHost.swift',
  'Packages/MadoKit/Sources/MadoCore/Canvas/CanvasZoomMode.swift',
  'Packages/MadoKit/Sources/MadoCore/Commands/FocusContext.swift',
  'Packages/MadoKit/Sources/MadoCore/MadoCore.swift',
  'Packages/MadoKit/Sources/MadoCore/Ports/CacheMaintenance.swift',
  'Packages/MadoKit/Sources/MadoCore/Ports/FolderMetadataReading.swift',
  'Packages/MadoKit/Sources/MadoCore/Ports/FolderWatching.swift',
  'Packages/MadoKit/Sources/MadoCore/Ports/ImagePresentationPinning.swift',
  'Packages/MadoKit/Sources/MadoCore/Ports/PrefetchResuming.swift',
  'Packages/MadoKit/Sources/MadoInfrastructure/MadoInfrastructure.swift',
  'Packages/MadoKit/Sources/MadoMacUI/DesignSystem/Tokens/DesignRegistry.swift',
  'Packages/MadoKit/Sources/MadoMacUI/MadoMacUI.swift',
]);
const approvedFileExceptionManifestDigest = '3e41c20a0907264134a384b00b0d6f731b2a13ad8bc0946e64710ab5979d24c7';
const wrappedCounterFloor = 1n << 63n;
const fatal = message => { throw new Error(message); };
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const object = (value, label) => value && typeof value === 'object' && !Array.isArray(value) ? value : fatal(`${label}: expected object`);
const nonempty = (value, label) => typeof value === 'string' && value.trim() ? value : fatal(`${label}: missing string`);
const number = (value, label, positive = false) => {
  if (!/^(0|[1-9][0-9]*)$/.test(String(value)) || !Number.isSafeInteger(Number(value)) || (positive && Number(value) === 0)) fatal(`${label}: invalid integer`);
  return Number(value);
};
const hits = (value, label) => /^(0|[1-9][0-9]*)$/.test(String(value)) && BigInt(value) <= 18446744073709551615n
  ? BigInt(value) : fatal(`${label}: invalid hit count`);
const hash = (value, label) => /^[0-9a-f]{64}$/.test(value ?? '') ? value : fatal(`${label}: malformed sha256`);
function sourcePath(root, raw) {
  nonempty(raw, 'SF');
  // Shards are produced on macOS and merged on Linux, so the checkout roots differ.
  const marker = '/' + prefix;
  const rawRelative = path.isAbsolute(raw) && raw.includes(marker) ? raw.slice(raw.indexOf(marker) + 1) : raw;
  const name = path.relative(root, path.resolve(root, rawRelative)).split(path.sep).join('/');
  if (!name.startsWith(prefix) || !name.endsWith('.swift') || !modules.includes(name.slice(prefix.length).split('/')[0])) fatal(`SF outside production source: ${raw}`);
  return name;
}

export function parseLCOV(text, root) {
  if (!text?.trim()) fatal('LCOV missing or empty');
  const result = new Map(); let current = null;
  for (const line of text.split(/\r?\n/)) {
    if (!line) continue;
    if (line.startsWith('TN:') && !current) continue;
    if (line.startsWith('SF:')) {
      if (current) fatal('LCOV record missing end_of_record');
      const name = sourcePath(root, line.slice(3));
      if (result.has(name)) fatal(`duplicate source record ${name}`);
      current = { name, lines: new Map(), functions: new Map(), functionHits: new Map(), summary: {} }; continue;
    }
    if (!current) fatal(`LCOV field outside record: ${line}`);
    const file = current.name;
    if (line === 'end_of_record') {
      for (const key of ['LF', 'LH', 'FNF', 'FNH']) if (!(key in current.summary)) fatal(`${file}: missing ${key}`);
      if (!current.lines.size || !current.functions.size) fatal(`${file}: zero executable line or function denominator in source record`);
      // llvm-cov's LF/LH count code regions; DA contains one record per source line.
      // They are not equal on real Swift LCOV, so DA is the line gate's denominator.
      if (current.summary.LF < current.summary.LH || current.summary.LF < current.lines.size ||
          current.summary.LH < [...current.lines.values()].filter(x => x.hits > 0n).length ||
          current.summary.FNF > current.functions.size || current.summary.FNH > [...current.functionHits.values()].filter(x => x > 0n).length ||
          current.summary.FNH > current.summary.FNF) fatal(`${file}: summary mismatch`);
      if (current.functions.size !== current.functionHits.size || [...current.functions.keys()].some(x => !current.functionHits.has(x))) fatal(`${file}: FN/FNDA mapping mismatch`);
      result.set(file, current); current = null; continue;
    }
    const colon = line.indexOf(':'); if (colon < 0) fatal(`${file}: malformed field ${line}`);
    const tag = line.slice(0, colon), value = line.slice(colon + 1);
    if (['LF', 'LH', 'FNF', 'FNH'].includes(tag)) {
      if (tag in current.summary) fatal(`${file}: duplicate ${tag}`);
      current.summary[tag] = number(value, `${file} ${tag}`);
    } else if (tag === 'DA') {
      const parts = value.split(',');
      if (parts.length < 2 || parts.length > 3) fatal(`${file}: malformed DA`);
      const n = number(parts[0], `${file} DA line`, true), count = hits(parts[1], `${file} DA hits`);
      if (current.lines.has(n)) fatal(`${file}: duplicate DA ${n}`);
      current.lines.set(n, { hits: count, checksum: parts[2] ?? null });
    } else if (tag === 'FN') {
      const parts = value.split(',');
      if (![2, 3].includes(parts.length)) fatal(`${file}: malformed FN`);
      const start = number(parts[0], `${file} FN start`, true), end = parts.length === 3 ? number(parts[1], `${file} FN end`, true) : null;
      const name = parts.at(-1);
      if (!name || (end !== null && end < start) || current.functions.has(name)) fatal(`${file}: duplicate or invalid FN ${name}`);
      current.functions.set(name, { start, end });
    } else if (tag === 'FNDA') {
      const comma = value.indexOf(','); if (comma < 1) fatal(`${file}: malformed FNDA`);
      const count = hits(value.slice(0, comma), `${file} FNDA hits`), name = value.slice(comma + 1);
      if (!name || current.functionHits.has(name)) fatal(`${file}: duplicate or invalid FNDA ${name}`);
      current.functionHits.set(name, count);
    } else if (!['BRDA', 'BRF', 'BRH'].includes(tag)) fatal(`${file}: unknown LCOV field ${tag}`);
  }
  if (current) fatal(`${current.name}: missing end_of_record`);
  if (!result.size) fatal('LCOV has no source records');
  return result;
}

function inventory(root) {
  const values = {};
  function visit(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(absolute);
      else if (entry.isFile() && entry.name.endsWith('.swift')) values[path.relative(root, absolute).split(path.sep).join('/')] = digest(readFileSync(absolute));
    }
  }
  for (const module of modules) visit(path.join(root, prefix, module));
  if (!Object.keys(values).length) fatal('production source inventory empty');
  return values;
}
function exceptions(root, sources) {
  let list;
  try { list = JSON.parse(readFileSync(path.join(root, 'scripts/ci/package-coverage-exceptions.json'), 'utf8')); }
  catch (error) { fatal(`exception list missing or malformed: ${error.message}`); }
  if (!Array.isArray(list)) fatal('exception list must be array');
  const presentApproved = [...approvedFileExceptionPaths].filter(name => name in sources);
  if (presentApproved.length && presentApproved.length !== approvedFileExceptionPaths.size) fatal('reviewed file exception source set incomplete');
  if (list.length !== presentApproved.length) fatal('file exception count drift from reviewed source set');
  if (list.length && digest(JSON.stringify(list)) !== approvedFileExceptionManifestDigest) fatal('file exception manifest pin drift');
  const result = new Map();
  for (const entry of list) {
    object(entry, 'exception');
    if (JSON.stringify(Object.keys(entry).sort()) !== JSON.stringify(['path', 'reason', 'sourceSha256', 'toolchain', 'decision'].sort())) fatal('file exception has missing or unexpected fields');
    const name = sourcePath(root, entry.path);
    if (entry.path !== name || !approvedFileExceptionPaths.has(name)) fatal(`unapproved file exception ${entry.path}`);
    if (hash(entry.sourceSha256, `${name} source digest`) !== sources[name]) fatal(`${name}: file exception source digest drift`);
    if (entry.decision !== 'i631-audit-astra.md 2') fatal(`${name}: file exception decision drift`);
    object(entry.toolchain, `${name} file exception toolchain`);
    nonempty(entry.reason, `${name} reason`);
    if (result.has(name)) fatal(`duplicate exception ${name}`);
    result.set(name, entry);
  }
  return result;
}
function functionExceptions(root, sources, toolchain) {
  let list;
  try { list = JSON.parse(readFileSync(path.join(root, 'scripts/ci/package-coverage-function-exceptions.json'), 'utf8')); }
  catch (error) { fatal(`function exception manifest missing or malformed: ${error.message}`); }
  if (!Array.isArray(list)) fatal('function exception manifest must be array');
  const result = new Map();
  const locations = new Set();
  for (const entry of list) {
    object(entry, 'function exception');
    if (JSON.stringify(Object.keys(entry).sort()) !== JSON.stringify(['decision', 'path', 'reason', 'sourceSha256', 'start', 'symbol', 'toolchain'].sort())) fatal('function exception has missing or unexpected fields');
    if (entry.path !== sourcePath(root, entry.path)) fatal(`function exception path is not exact: ${entry.path}`);
    if (!(entry.path in sources)) fatal(`function exception source missing: ${entry.path}`);
    if (hash(entry.sourceSha256, `${entry.path} source digest`) !== sources[entry.path]) fatal(`${entry.path}: function exception source digest drift`);
    if (JSON.stringify(entry.toolchain) !== JSON.stringify(toolchain)) fatal(`${entry.path}: function exception toolchain drift`);
    const symbol = nonempty(entry.symbol, `${entry.path} symbol`);
    if (symbol.includes('*') || symbol.includes('?')) fatal(`${entry.path}: function exception wildcard symbol`);
    number(entry.start, `${entry.path} function exception start`, true);
    const location = `${entry.path}:${entry.start}`;
    if (!approvedFunctionIdentities.has(location)) fatal(`unapproved function exception location ${location}`);
    const approved = approvedFunctionIdentities.get(location);
    if (digest(symbol) !== approved.symbolSha256) fatal(`unapproved function exception symbol ${location}`);
    if (entry.sourceSha256 !== approved.sourceSha256) fatal(`unapproved function exception source pin ${location}`);
    if (locations.has(location)) fatal(`duplicate function exception location ${location}`);
    locations.add(location);
    nonempty(entry.reason, `${entry.path} reason`);
    if (entry.decision !== approved.decision) fatal(`${entry.path}: function exception decision reference drift`);
    const key = `${entry.path}\u0000${symbol}`;
    if (result.has(key)) fatal(`duplicate function exception ${entry.path}:${symbol}`);
    result.set(key, entry);
  }
  return result;
}
// #788: "Re-run failed jobs" keeps a successful shard job and its artifact from an earlier attempt of the same run. Such a
// shard is accepted only when the run's job records (fetched by --fetch-attempt-jobs) prove that its job succeeded in that
// attempt at this head SHA and was carried forward unchanged to every later attempt (same start, end and runner). Commit,
// run, toolchain, instrumentation and source checks stay as they are, so both shards are still one commit's inputs.
// The records carry the run's head_sha: on pull_request that is the PR head, while --sha (github.sha, kept by every
// re-run of the run) is the refs/pull/N/merge commit the artifacts record, so the head is passed as --head-sha (i788a-fix1).
export const SHARD_JOBS = Object.freeze({ 'non-ui': 'Package tests (non-UI)', macui: 'Package tests (MacUI)' });
const RERUN_ALL = 'rerun all jobs of this run';
function attemptProvenance(shard, produced, expected) {
  if (!Number.isInteger(produced) || produced < 1) fatal(`${shard} attempt provenance mismatch: artifact attempt ${JSON.stringify(produced)} is not a positive integer`);
  if (produced === expected.attempt) return null;
  const refuse = reason => fatal(`${shard} attempt provenance mismatch: artifact from attempt ${produced}, this is attempt ${expected.attempt}; ${reason}; ${RERUN_ALL}`);
  if (produced > expected.attempt) fatal(`${shard} attempt provenance mismatch: artifact from attempt ${produced} is later than this attempt ${expected.attempt}; ${RERUN_ALL}`);
  const proof = expected.attemptJobs;
  if (!proof) refuse('no job records for the earlier attempts');
  if (proof.runId !== expected.runId) refuse(`job records are for run ${proof.runId}`);
  if (proof.attempt !== expected.attempt) refuse(`job records are for attempt ${proof.attempt}`);
  const name = SHARD_JOBS[shard];
  const records = [];
  for (let attempt = produced; attempt <= expected.attempt; attempt++) {
    const record = proof.attempts[String(attempt)];
    if (!record) refuse(`no job records for attempt ${attempt}`);
    if (record.headSha !== expected.headSha) refuse(`attempt ${attempt} head SHA ${record.headSha} is not ${expected.headSha}`);
    const jobs = record.jobs.filter(job => job.name === name);
    if (jobs.length !== 1) refuse(jobs.length ? `${jobs.length} jobs ${name} in attempt ${attempt}` : `no job ${name} in attempt ${attempt}`);
    const [job] = jobs;
    if (job.runAttempt !== attempt) refuse(`job record attempt ${job.runAttempt} listed under attempt ${attempt}`);
    if (job.headSha !== expected.headSha) refuse(`job ${name} head SHA ${job.headSha} in attempt ${attempt} is not ${expected.headSha}`);
    if (job.conclusion !== 'success') refuse(`job ${name} did not succeed in attempt ${attempt} (${job.conclusion})`);
    // Other jobs may be skipped (no runner, no times); the shard's own job must carry all three to compare attempts.
    if (![job.startedAt, job.completedAt, job.runnerName].every(value => typeof value === 'string' && value))
      refuse(`job ${name} in attempt ${attempt} has no start, end or runner to compare`);
    records.push(job);
  }
  const [first, ...later] = records;
  for (const [index, job] of later.entries())
    if (job.startedAt !== first.startedAt || job.completedAt !== first.completedAt || job.runnerName !== first.runnerName)
      refuse(`job ${name} ran again in attempt ${produced + index + 1}, so its artifact must come from that attempt`);
  return `${shard} shard from attempt ${produced} of run ${expected.runId} (job ${name} succeeded there and was not re-run; checked against the run's job records)`;
}
function readAttemptJobs(file) {
  if (file === undefined || !existsSync(file)) return null;
  let proof;
  try { proof = JSON.parse(readFileSync(file, 'utf8')); } catch (error) { fatal(`attempt job records malformed: ${error.message}; ${RERUN_ALL}`); }
  const text = value => typeof value === 'string' && value.length > 0;
  const valid = proof && proof.version === 1 && text(proof.runId) && Number.isInteger(proof.attempt) && proof.attempts && typeof proof.attempts === 'object' &&
    Object.values(proof.attempts).every(record => record && text(record.headSha) && Array.isArray(record.jobs) &&
      record.jobs.every(job => job && text(job.name)));
  if (!valid) fatal(`attempt job records malformed; ${RERUN_ALL}`);
  return proof;
}

function artifact(root, input, shard, expected, sources) {
  let raw, meta;
  try { raw = readFileSync(path.join(input, shard, 'coverage.lcov')); meta = JSON.parse(readFileSync(path.join(input, shard, 'metadata.json'), 'utf8')); }
  catch (error) { fatal(`${shard} artifact missing or malformed: ${error.message}`); }
  object(meta, `${shard} metadata`);
  if (meta.version !== 1 || meta.shard !== shard) fatal(`${shard} shard/version mismatch`);
  if (meta.commit !== expected.sha) fatal(`${shard} commit provenance mismatch`);
  if (String(meta.runId) !== expected.runId) fatal(`${shard} run provenance mismatch`);
  const carried = attemptProvenance(shard, meta.runAttempt, expected);
  const tc = object(meta.toolchain, `${shard} toolchain`);
  for (const key of ['xcode', 'swift', 'llvmCov']) nonempty(tc[key], `${shard} toolchain.${key}`);
  const expectedInstrumentation = { swiftArgs: coverageAtomicSwiftArgs, scratchPath: coverageAtomicScratchPath, flagId: ATOMIC_COVERAGE_FLAG_ID };
  if (JSON.stringify(meta.instrumentation) !== JSON.stringify(expectedInstrumentation)) fatal(`${shard} coverage instrumentation mismatch`);
  for (const key of ['binary', 'profile']) {
    const item = object(meta[key], `${shard} ${key}`);
    nonempty(item.path, `${shard} ${key} path`); hash(item.sha256, `${shard} ${key}`);
  }
  if (hash(meta.lcovSha256, `${shard} LCOV`) !== digest(raw)) fatal(`${shard} LCOV sha256 mismatch`);
  const listed = object(meta.sourceInventory, `${shard} source inventory`);
  if (JSON.stringify(Object.keys(listed).sort()) !== JSON.stringify(Object.keys(sources).sort())) fatal(`${shard} source inventory missing or unexpected file`);
  for (const [name, value] of Object.entries(sources)) if (listed[name] !== value) fatal(`${shard} source digest mismatch: ${name}`);
  return { meta, carried, files: parseLCOV(raw.toString('utf8'), root) };
}
function mapping(record) {
  return JSON.stringify({ lines: [...record.lines].map(([n, v]) => [n, v.checksum]).sort((a, b) => a[0] - b[0]),
    functions: [...record.functions].sort(([a], [b]) => a.localeCompare(b)) });
}
function invalidCounters(artifact) {
  const invalid = [];
  const { meta, files } = artifact;
  const provenance = `commit=${meta.commit} run=${meta.runId} attempt=${meta.runAttempt} binary=${meta.binary.sha256} profile=${meta.profile.sha256} lcov=${meta.lcovSha256}`;
  for (const [name, record] of files) {
    for (const [line, data] of record.lines) if (data.hits >= wrappedCounterFloor)
      invalid.push(`- shard=${meta.shard} path=${name}:${line} kind=DA raw=${data.hits}; ${provenance}; reason=count >= 2^63, possible wrapped counter`);
    for (const [symbol, count] of record.functionHits) if (count >= wrappedCounterFloor)
      invalid.push(`- shard=${meta.shard} path=${name}:${record.functions.get(symbol).start} function=${symbol} kind=FNDA raw=${count}; ${provenance}; reason=count >= 2^63, possible wrapped counter`);
  }
  return invalid;
}
function loopExit(root, merged) {
  const name = prefix + 'MadoInfrastructure/Images/ImageSourceHeader.swift';
  if (!merged.has(name)) return 'ImageSourceHeader.swift loop-exit throw: source absent';
  const lines = readFileSync(path.join(root, name), 'utf8').split(/\r?\n/);
  const start = lines.findIndex(line => /\bwhile\b/.test(line));
  const next = lines.findIndex((line, n) => n > start && /\bstatic func read\b/.test(line));
  const limit = next < 0 ? lines.length : next;
  const locations = lines.map((line, n) => ({ line, n })).filter(x => x.n > start && x.n < limit && /\bthrow ImageDecodeError\.unreadableImage\b/.test(x.line));
  if (start < 0 || !locations.length) fatal(`${name}: cannot locate loop-exit throw`);
  const n = locations.at(-1).n + 1;
  const hit = merged.get(name).lines.get(n);
  if (!hit) fatal(`${name}:${n}: loop-exit throw absent from mapping`);
  return `ImageSourceHeader.swift:${n} loop-exit throw hit count ${hit.hits}`;
}

export function evaluateCoverage({ root, input, out, eligibleOut, sha, headSha = sha, runId, attempt, formal, shards = ['non-ui', 'macui'], attemptJobs }) {
  if (![root, input, out].every(x => typeof x === 'string' && path.isAbsolute(x))) fatal('root/input/out must be absolute');
  if (eligibleOut !== undefined && (typeof eligibleOut !== 'string' || !path.isAbsolute(eligibleOut))) fatal('eligibleOut must be absolute');
  if (existsSync(out)) unlinkSync(out);
  if (eligibleOut !== undefined && existsSync(eligibleOut)) unlinkSync(eligibleOut);
  if (!/^[0-9a-f]{40}$/.test(sha ?? '')) fatal('expected commit SHA malformed');
  if (!/^[0-9a-f]{40}$/.test(headSha ?? '')) fatal('expected head SHA malformed');
  if (!/^[1-9][0-9]*$/.test(String(runId))) fatal('expected run ID malformed');
  if (typeof formal !== 'boolean') fatal('formal must be boolean');
  if (JSON.stringify(shards) !== JSON.stringify(['non-ui', 'macui']) && JSON.stringify(shards) !== JSON.stringify(['non-ui'])) fatal('invalid shard selection');
  if (formal && shards.length !== 2) fatal('formal coverage requires two shards');
  const expected = { sha, headSha, runId: String(runId), attempt: number(attempt, 'expected attempt', true), attemptJobs: readAttemptJobs(attemptJobs) };
  const sources = inventory(root), exempt = exceptions(root, sources);
  for (const name of exempt.keys()) if (!(name in sources)) fatal(`exception source missing: ${name}`);
  const [left, right] = shards.map(shard => artifact(root, input, shard, expected, sources));
  if (right && JSON.stringify(left.meta.toolchain) !== JSON.stringify(right.meta.toolchain)) fatal('toolchain mismatch');
  for (const [name, entry] of exempt) if (JSON.stringify(entry.toolchain) !== JSON.stringify(left.meta.toolchain)) fatal(`${name}: file exception toolchain drift`);
  const invalid = [left, right].filter(Boolean).flatMap(invalidCounters);
  if (invalid.length) {
    const report = ['# MadoKit Package coverage', '', `Commit ${sha}; run ${runId}; attempt ${expected.attempt}; invalid evidence`,
      `Toolchain: ${JSON.stringify(left.meta.toolchain)}`, `Coverage instrumentation: ${JSON.stringify(left.meta.instrumentation)}`,
      ...[left, right].filter(shard => shard?.carried).map(shard => shard.carried), 'Invalid coverage evidence:', ...invalid,
      'Uncovered locations: not evaluated because evidence is invalid',
      'Coverage gate: FAIL (invalid counter evidence; no eligible artifact)'].join('\n') + '\n';
    writeFileSync(out, report);
    return { pass: false, report, total: null, invalid };
  }
  const functionExempt = functionExceptions(root, sources, left.meta.toolchain);
  const names = [...left.files.keys()].sort();
  if (right && JSON.stringify(names) !== JSON.stringify([...right.files.keys()].sort())) fatal('shard mapping inventory mismatch');
  const required = Object.keys(sources).filter(name => !exempt.has(name)).sort();
  if (JSON.stringify(names) !== JSON.stringify(required)) fatal(`production source mapping missing or unexpected: ${required.filter(x => !left.files.has(x)).join(', ')}`);
  const merged = new Map();
  for (const name of names) {
    const a = left.files.get(name), b = right?.files.get(name);
    if (b && mapping(a) !== mapping(b)) fatal(`${name}: incompatible mapping`);
    const lines = new Map([...a.lines].map(([n, data]) => [n, { hits: data.hits + (b?.lines.get(n).hits ?? 0n) }]));
    const functionHits = new Map([...a.functionHits].map(([fn, count]) => [fn, count + (b?.functionHits.get(fn) ?? 0n)]));
    merged.set(name, { lines, functions: a.functions, functionHits });
  }
  for (const entry of functionExempt.values()) {
    const file = merged.get(entry.path);
    const location = file?.functions.get(entry.symbol);
    if (!location) fatal(`unmatched function exception ${entry.path}:${entry.symbol}`);
    if (location.start !== entry.start) fatal(`stale function exception location ${entry.path}:${entry.symbol}`);
    if (file.functionHits.get(entry.symbol) > 0n) fatal(`covered function exception ${entry.path}:${entry.symbol}`);
  }
  // Guardian consumes LCOV, so derive a second LCOV view from the exact DA and
  // FNDA mappings already validated here. Its summaries are now the strict
  // eligible counts, never LLVM's different FNF/FNH summary population.
  const eligibleRecords = [];
  for (const [name, data] of merged) {
    const functions = [...data.functions].filter(([symbol]) => !functionExempt.has(`${name}\u0000${symbol}`));
    const lines = [...data.lines];
    eligibleRecords.push(`SF:${name}`);
    for (const [symbol, location] of functions) eligibleRecords.push(`FN:${location.start},${symbol}`);
    for (const [symbol] of functions) eligibleRecords.push(`FNDA:${data.functionHits.get(symbol)},${symbol}`);
    eligibleRecords.push(`FNF:${functions.length}`, `FNH:${functions.filter(([symbol]) => data.functionHits.get(symbol) > 0n).length}`);
    for (const [line, hit] of lines) eligibleRecords.push(`DA:${line},${hit.hits}`);
    eligibleRecords.push(`LF:${lines.length}`, `LH:${lines.filter(([, hit]) => hit.hits > 0n).length}`, 'end_of_record');
  }
  const eligibleLCOV = eligibleRecords.join('\n') + '\n';
  const report = ['# MadoKit Package coverage', '', `Commit ${sha}; run ${runId}; attempt ${expected.attempt}; ${formal ? 'formal full-package evidence' : 'diagnostic, not formal full-package evidence'}`,
    `Toolchain: ${JSON.stringify(left.meta.toolchain)}`, `Coverage instrumentation: ${JSON.stringify(left.meta.instrumentation)}`, 'Statements: statement proxy = LCOV executable lines; independent Swift statements unmeasured.',
    'LCOV LF/LH summaries may count regions; unique DA rows are the executable-line denominator.',
    'branches unmeasured', 'App/ excluded', ...[left, right].filter(shard => shard?.carried).map(shard => shard.carried), ''];
  const total = { lines: 0, coveredLines: 0, functions: 0, coveredFunctions: 0, exceptions: 0 };
  const uncovered = [];
  for (const module of modules) {
    const entries = [...merged].filter(([name]) => name.startsWith(prefix + module + '/'));
    const lines = entries.reduce((n, [, data]) => n + data.lines.size, 0);
    const coveredLines = entries.reduce((n, [, data]) => n + [...data.lines.values()].filter(x => x.hits > 0n).length, 0);
    const functions = entries.reduce((n, [, data]) => n + data.functions.size, 0);
    const coveredFunctions = entries.reduce((n, [, data]) => n + [...data.functionHits.values()].filter(x => x > 0n).length, 0);
    const exceptionCount = [...functionExempt.values()].filter(entry => entry.path.startsWith(prefix + module + '/')).length;
    if (!lines || !functions) fatal(`${module}: zero denominator`);
    total.lines += lines; total.coveredLines += coveredLines; total.functions += functions; total.coveredFunctions += coveredFunctions; total.exceptions += exceptionCount;
    report.push(`${module}: lines ${coveredLines}/${lines}; functions ${coveredFunctions}/${functions}; raw functions ${coveredFunctions}/${functions}; exceptions ${exceptionCount}; eligible functions ${coveredFunctions}/${functions - exceptionCount}`);
    for (const [name, data] of entries) {
      for (const [n, hit] of data.lines) if (!hit.hits) uncovered.push(`${name}:${n} line`);
      for (const [fn, hit] of data.functionHits) if (!hit && !functionExempt.has(`${name}\u0000${fn}`)) uncovered.push(`${name}:${data.functions.get(fn).start} function ${fn}`);
    }
  }
  report.push(`Package: lines ${total.coveredLines}/${total.lines}; functions ${total.coveredFunctions}/${total.functions}; raw functions ${total.coveredFunctions}/${total.functions}; exceptions ${total.exceptions}; eligible functions ${total.coveredFunctions}/${total.functions - total.exceptions}`);
  report.push(loopExit(root, merged));
  report.push('Reviewed no-executable-code exclusions:');
  report.push(...([...exempt].map(([name, entry]) => `- ${name}: ${entry.reason}; source sha256 ${entry.sourceSha256}; toolchain ${JSON.stringify(entry.toolchain)}; decision ${entry.decision}`)));
  if (!exempt.size) report.push('- none');
  report.push('Reviewed function exceptions (uncovered, excluded only from eligible denominator):');
  report.push(...[...functionExempt.values()].map(entry => `- ${entry.path}:${entry.start} function ${entry.symbol}; source sha256 ${entry.sourceSha256}; toolchain ${JSON.stringify(entry.toolchain)}; ${entry.reason}; decision ${entry.decision}`));
  if (!functionExempt.size) report.push('- none');
  report.push('Uncovered locations:', ...(uncovered.length ? uncovered.map(x => `- ${x}`) : ['- none']));
  const unusual = [];
  for (const [name, data] of merged) {
    for (const [n, value] of data.lines) if (value.hits > BigInt(Number.MAX_SAFE_INTEGER)) unusual.push(`${name}:${n} hit count ${value.hits}`);
    for (const [fn, value] of data.functionHits) if (value > BigInt(Number.MAX_SAFE_INTEGER)) unusual.push(`${name} function ${fn} hit count ${value}`);
  }
  report.push('Large LLVM counters (raw, not clamped):', ...(unusual.length ? unusual.map(x => `- ${x}`) : ['- none']));
  for (const { meta } of [left, right].filter(Boolean)) {
    report.push(`${meta.shard} binary ${meta.binary.path} sha256 ${meta.binary.sha256}`);
    report.push(`${meta.shard} profile ${meta.profile.path} sha256 ${meta.profile.sha256}`);
    report.push(`${meta.shard} LCOV sha256 ${meta.lcovSha256}`);
  }
  const pass = total.coveredLines === total.lines && total.coveredFunctions === total.functions - total.exceptions;
  report.push(`Coverage gate: ${pass ? 'PASS' : 'FAIL'} (exact 100% executable lines and functions per module and Package)`);
  const output = report.join('\n') + '\n'; writeFileSync(out, output);
  if (eligibleOut !== undefined) writeFileSync(eligibleOut, eligibleLCOV);
  return { pass, report: output, total, eligibleLCOV };
}

function cli(args) {
  const values = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!/^--(root|input|out|eligible-out|sha|head-sha|run-id|attempt|formal|shards|attempt-jobs)$/.test(args[i] ?? '') || !args[i + 1] || args[i] in values) fatal(`invalid argument ${args[i]}`);
    values[args[i]] = args[i + 1];
  }
  for (const key of ['--root', '--input', '--out', '--sha', '--run-id', '--attempt', '--formal']) if (!(key in values)) fatal(`missing ${key}`);
  if (!['true', 'false'].includes(values['--formal'])) fatal('invalid --formal');
  return { root: path.resolve(values['--root']), input: path.resolve(values['--input']), out: path.resolve(values['--out']),
    eligibleOut: values['--eligible-out'] === undefined ? undefined : path.resolve(values['--eligible-out']), sha: values['--sha'],
    headSha: values['--head-sha'] ?? values['--sha'], runId: values['--run-id'],
    attempt: values['--attempt'], formal: values['--formal'] === 'true', shards: values['--shards'] === undefined ? ['non-ui', 'macui'] : values['--shards'].split(','),
    attemptJobs: values['--attempt-jobs'] === undefined ? undefined : path.resolve(values['--attempt-jobs']) };
}

// --fetch-attempt-jobs <out> --repo <owner/name> --run-id <id> --attempt <n>: write the job records of attempts 1..n
// (GITHUB_API_URL, GH_TOKEN or GITHUB_TOKEN). Any failed or incomplete read writes no file and only warns: the gate then
// refuses a shard from an earlier attempt, so a missing record can never let one through.
export async function fetchAttemptJobs({ api, repo, runId, attempt, token, fetchImpl = fetch }) {
  const get = async route => {
    const response = await fetchImpl(`${api}/repos/${repo}/actions/runs/${runId}${route}`,
      { headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${token}`, 'x-github-api-version': '2022-11-28' } });
    if (!response.ok) throw new Error(`GET ${route}: HTTP ${response.status}`);
    return response.json();
  };
  const attempts = {};
  for (let n = 1; n < attempt + 1; n++) {
    const run = await get(`/attempts/${n}`);
    if (run.run_attempt !== n || typeof run.head_sha !== 'string') throw new Error(`attempt ${n} record malformed`);
    const jobs = [];
    for (let page = 1; page <= 10; page++) {
      const listed = await get(`/attempts/${n}/jobs?per_page=100&page=${page}`);
      if (!Array.isArray(listed.jobs) || !Number.isInteger(listed.total_count)) throw new Error(`attempt ${n} job list malformed`);
      jobs.push(...listed.jobs);
      if (listed.jobs.length < 100 || jobs.length >= listed.total_count) {
        if (jobs.length !== listed.total_count) throw new Error(`attempt ${n} job list incomplete: ${jobs.length} of ${listed.total_count}`);
        break;
      }
      if (page === 10) throw new Error(`attempt ${n} job list incomplete after 10 pages`);
    }
    attempts[n] = { headSha: run.head_sha, jobs: jobs.map(job => ({ name: job.name, conclusion: job.conclusion, runAttempt: job.run_attempt, headSha: job.head_sha,
      startedAt: job.started_at, completedAt: job.completed_at, runnerName: job.runner_name })) };
  }
  return { version: 1, runId: String(runId), attempt, attempts };
}
async function fetchCli(args) {
  const values = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!/^--(fetch-attempt-jobs|repo|run-id|attempt)$/.test(args[i] ?? '') || !args[i + 1] || args[i] in values) fatal(`invalid argument ${args[i]}`);
    values[args[i]] = args[i + 1];
  }
  for (const key of ['--fetch-attempt-jobs', '--repo', '--run-id', '--attempt']) if (!(key in values)) fatal(`missing ${key}`);
  if (!/^[1-9][0-9]*$/.test(values['--run-id']) || !/^[1-9][0-9]*$/.test(values['--attempt']) || !/^[\w.-]+\/[\w.-]+$/.test(values['--repo'])) fatal('invalid fetch arguments');
  const out = path.resolve(values['--fetch-attempt-jobs']), attempt = Number(values['--attempt']);
  if (existsSync(out)) unlinkSync(out);
  if (attempt === 1) { process.stdout.write('package-coverage: attempt 1 has no earlier attempt; no job records needed\n'); return; }
  try {
    const proof = await fetchAttemptJobs({ api: process.env.GITHUB_API_URL || 'https://api.github.com', repo: values['--repo'], runId: values['--run-id'],
      attempt, token: process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '' });
    writeFileSync(`${out}.tmp`, JSON.stringify(proof, null, 1) + '\n');
    renameSync(`${out}.tmp`, out);
    process.stdout.write(`package-coverage: job records of attempts 1..${attempt} written to ${out}\n`);
  } catch (error) {
    process.stderr.write(`package-coverage: cannot read the job records of earlier attempts (${error.message}); a shard from an earlier attempt will be refused\n`);
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url) && process.argv[2] === '--fetch-attempt-jobs') {
  try { await fetchCli(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`package-coverage: ${error.message}\n`); process.exitCode = 1; }
} else if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = evaluateCoverage(cli(process.argv.slice(2)));
    process.stdout.write(result.report);
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, result.report + '\n');
    process.exitCode = result.pass ? 0 : 1;
  } catch (error) {
    const message = `package-coverage: ${error.message}\n`;
    process.stderr.write(message);
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `## Package coverage validation failed\n\n${message}\n`);
    process.exitCode = 1;
  }
}
