#!/usr/bin/env node
// #898 tdd-separation lane (owner 2026-11-25). Evidence that each RED was recorded on a clean committed tree: no
// production file differed from the receipt's head_sha, head_sha is a strict ancestor of the WI's implementation commit,
// and every production commit lies in a RED window (or is a Stub-For stub before its RED). It is not proof of test-first
// (the plugin itself says receipts are self-reported); replay (below) is the discriminating evidence.
//
//   tdd-separation.mjs gate --worktree <wt> --base <sha> --head <sha> [--out <json>] [--archive <dir>] [--waivers <dir>]
//                           [--receipts <receipts.json>]… [--rebased-from <old-base>..<old-head>]
//                           [--issue <n>] [--accept-waiver <id>@<sha256>]… [--replay <replay.json>]…
//                           [--accept-replay <receipt>@<sha256 of the replay file>]…
//   tdd-separation.mjs evaluate <same options>          (prints the JSON result)
//   tdd-separation.mjs replay --worktree <wt> --head <sha> --receipt <id> --kind node|swift --filter <f> [--archive <dir>]
//                             [--out <wt>/.build/mado-verify/replay/<id>.json]
//
// gate prints one summary line and exits 0 in report-only mode whatever the verdict (gate-policy.mjs TDD_SEPARATION_MODE).
// In mandatory mode (the constant, or --mandatory for one run: there is no option that downgrades) an error exits 1, and a
// refused or unknown verdict exits 1 only when the diff needs the lane (tddSeparationRequired: product code), so the
// switch does not refuse tooling-only tickets (fix1, gpt F2 / opus M6). The line ends with required=yes|no.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { TDD_SEPARATION_MODE, isTestPath, isDocPath, isProductionPath, listDiffPaths, partyKey, tddSeparationRequired } from './gate-policy.mjs';

export { isTestPath, isDocPath, isProductionPath };
export const LANE_VERSION = 1;
// tdd-guardian 0.10.2 lib/verification.js stores dirty_source.slice(0, 50) of a sorted list: 50 entries may be truncated.
export const DIRTY_SOURCE_CAP = 50;
export const defaultArchiveDir = () => process.env.MADO_RECEIPT_ARCHIVE_ROOT || path.join(os.homedir(), '.mado/archive/tdd-guardian/receipts');
export const defaultWaiverDir = () => path.join(os.homedir(), '.mado/herdr/delegator/tdd-waivers');
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const WAIVER_ISSUERS = new Set(['delegator', 'owner']);

// Inherited GIT_* variables (hooks, a caller's GIT_DIR) must not change which repository is read.
// A replay run must not inherit a parent node:test runner's context (it would skip the files) or git's GIT_* state.
const runEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_') && key !== 'NODE_TEST_CONTEXT'));
const gitEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
function git(cwd, args, input, extraEnv = {}) {
  return spawnSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, env: { ...gitEnv, LC_ALL: 'C', ...extraEnv }, input });
}
function gitOut(cwd, args) {
  const r = git(cwd, args);
  if (r.status !== 0) throw new Error(`git ${args[0]} failed: ${(r.stderr || '').trim().split('\n')[0]}`);
  return r.stdout;
}
const resolveCommit = (cwd, rev) => typeof rev === 'string' && rev && !rev.startsWith('-')
  ? (git(cwd, ['rev-parse', '--verify', '--quiet', `${rev}^{commit}`]).stdout || '').trim() || null : null;
const isAncestor = (cwd, a, b) => git(cwd, ['merge-base', '--is-ancestor', a, b]).status === 0;
const nul = text => text.split('\0').filter(Boolean);

// fix1 (L2): trailers are read from the trailer block only: the trailing paragraphs (never the subject) whose every line
// is `Key: value` or `Refs #n`. A prose line that starts with `Refactor:` or `Red-Receipt:` in the body does not count.
const TRAILER_LINE = /^[A-Za-z][A-Za-z0-9-]*(?::\s|\s+#\d)/;
function trailerLines(body) {
  const paragraphs = body.replace(/\s+$/, '').split(/\n[ \t]*\n/), lines = [];
  for (let i = paragraphs.length - 1; i >= 1; i--) {
    const para = paragraphs[i].split('\n').filter(line => line.trim());
    if (!para.length || !para.every(line => TRAILER_LINE.test(line))) break;
    lines.unshift(...para);
  }
  return lines;
}
function trailers(body) {
  const lines = trailerLines(body);
  const pick = re => lines.map(line => re.exec(line)?.[1]).filter(Boolean);
  return { red: [...new Set(pick(/^Red-Receipt:\s+(\S+)/))], stubFor: [...new Set(pick(/^Stub-For:\s+(\S+)/))], refactor: pick(/^Refactor:\s+(.+)$/),
    refs: [...new Set(pick(/^Refs\s+#(\d+)\b/).map(Number))] };
}
function listCommits(cwd, base, head) {
  return gitOut(cwd, ['rev-list', '--reverse', '--topo-order', `${base}..${head}`]).split('\n').filter(Boolean).map(sha => {
    const body = gitOut(cwd, ['log', '-1', '--format=%B', sha]);
    // fix1 (opus M5): a merge commit (main merged into the branch) counts only its own changes: --remerge-diff shows what
    // the merge commit changed beyond Git's automatic merge (a conflict resolution, an evil edit), not main's commits.
    const parents = gitOut(cwd, ['rev-list', '--parents', '-n', '1', sha]).trim().split(' ').length - 1;
    const paths = nul(gitOut(cwd, parents > 1
      ? ['diff-tree', '--remerge-diff', '-r', '--no-commit-id', '--name-only', '-z', '--no-renames', sha]
      : ['diff-tree', '--root', '-r', '--no-commit-id', '--name-only', '-z', '--no-renames', sha]));
    return { sha, subject: body.split('\n')[0], body, paths, merge: parents > 1, ...trailers(body) };
  });
}

function readJson(file) {
  let stat;
  try { stat = fs.lstatSync(file); } catch { return undefined; }
  if (!stat.isFile()) return undefined;
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return undefined; }
}
function localReceipts(files) {
  const found = [];
  for (const file of files) {
    const store = readJson(file);
    if (store?.schemaVersion === 2 && Array.isArray(store.receipts))
      for (const receipt of store.receipts) if (receipt && typeof receipt.id === 'string') found.push({ receipt, source: 'worktree', file });
  }
  return found;
}
function archiveReceipts(dir, id) {
  if (!SAFE_ID.test(id)) return [];
  let names;
  try { names = fs.readdirSync(dir); } catch { return []; }
  return names.filter(name => name === `${id}.json` || (name.startsWith(`${id}.`) && name.endsWith('.json')))
    .map(name => ({ envelope: readJson(path.join(dir, name)), name }))
    .filter(({ envelope }) => envelope?.schemaVersion === 1 && envelope.receipt?.id === id)
    .map(({ envelope, name }) => ({ receipt: envelope.receipt, source: 'archive', file: name }));
}
// Worktree receipts first, then the archive (archive-receipts.mjs envelopes). Several candidates: keep those whose
// head_sha is in this history; still several distinct ones is ambiguous.
function findReceipt(ctx, id) {
  let candidates = ctx.local.filter(c => c.receipt.id === id);
  if (!candidates.length) candidates = archiveReceipts(ctx.archiveDir, id);
  const distinct = list => [...new Map(list.map(c => [JSON.stringify(c.receipt), c])).values()];
  candidates = distinct(candidates);
  if (candidates.length > 1) {
    const inHistory = candidates.filter(c => { const sha = resolveCommit(ctx.cwd, c.receipt.head_sha); return sha && isAncestor(ctx.cwd, sha, ctx.head); });
    if (inHistory.length === 1) return { found: inHistory[0] };
    return { problem: `receipt ${id} is ambiguous: ${candidates.length} different receipts carry this id` };
  }
  return candidates.length ? { found: candidates[0] } : { problem: `receipt ${id} not found in receipts.json or the archive` };
}

// Waivers (fix1, gpt F1 / opus M3): a JSON file in ~/.mado/herdr/delegator/tdd-waivers/ is only a CLAIM:
// {"waivers":[{"id","issue","receipt"|"commit","paths"?,"reason","issuedBy","ref","expires":"YYYY-MM-DD"}]}.
// Any process running as this user can write that directory (every pane is the same user), so no file, owner or mode check
// can tell who wrote it. Trust comes from the invocation instead: a claim becomes WAIVED only when the caller names it with
// --accept-waiver <id>@<sha256 of the waiver entry> (a prefix of at least 12 hex). Only the delegator's own runs (its
// owner-gates run, its evidence.mjs check before merge) are binding, and an implementer cannot put arguments into them.
// The digest binds the accepted content: an edit after acceptance (wider paths, another receipt) no longer matches.
// A claim must be for this ticket's issue and not expired; the directory itself must not be a symlink.
const canonical = v => Array.isArray(v) ? `[${v.map(canonical).join(',')}]`
  : v && typeof v === 'object' ? `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}` : JSON.stringify(v);
export const waiverDigest = w => crypto.createHash('sha256').update(canonical(w)).digest('hex');
const today = () => new Date().toISOString().slice(0, 10);
export function waiverProblems(w, now = today()) {
  const problems = [];
  if (!w || typeof w !== 'object') return ['not an object'];
  if (typeof w.id !== 'string' || !SAFE_ID.test(w.id)) problems.push('id');
  if (!Number.isSafeInteger(w.issue) || w.issue < 1) problems.push('issue');
  const hasReceipt = typeof w.receipt === 'string' && SAFE_ID.test(w.receipt), hasCommit = typeof w.commit === 'string' && /^[0-9a-f]{40}$/.test(w.commit);
  if (hasReceipt === hasCommit) problems.push('exactly one of receipt or commit (full sha)');
  if (w.paths !== undefined && (!Array.isArray(w.paths) || !w.paths.length || w.paths.some(p => typeof p !== 'string' || !p.trim()))) problems.push('paths');
  if (typeof w.reason !== 'string' || !w.reason.trim()) problems.push('reason');
  if (!WAIVER_ISSUERS.has(partyKey(w.issuedBy))) problems.push('issuedBy must be the delegator or the owner');
  if (typeof w.ref !== 'string' || !w.ref.trim()) problems.push('ref (the brief or note that issued it)');
  const date = typeof w.expires === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(w.expires) && new Date(`${w.expires}T00:00:00Z`);
  if (!date || Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== w.expires) problems.push('expires (YYYY-MM-DD)');
  else if (w.expires < now) problems.push(`expired on ${w.expires}`);
  return problems;
}
function loadWaivers(dir) {
  const valid = [], invalid = [];
  let names = [];
  let dirStat;
  try { dirStat = fs.lstatSync(dir); } catch { /* no waiver directory */ }
  if (dirStat?.isDirectory()) {
    try { names = fs.readdirSync(dir).filter(name => name.endsWith('.json')).sort(); } catch { /* unreadable */ }
  }
  for (const name of names) {
    const file = readJson(path.join(dir, name));
    for (const w of Array.isArray(file?.waivers) ? file.waivers : []) {
      const problems = waiverProblems(w);
      if (problems.length) invalid.push({ id: w?.id ?? null, issue: w?.issue, receipt: w?.receipt, commit: w?.commit, file: name, reason: `invalid waiver: ${problems.join(', ')}` });
      else valid.push({ ...w, digest: waiverDigest(w) });
    }
  }
  return { valid, invalid };
}
function parseAccepted(tokens, flag = '--accept-waiver') {
  return (tokens ?? []).map(token => { const m = /^([A-Za-z0-9][A-Za-z0-9._-]{0,127})@([0-9a-f]{12,64})$/.exec(String(token)); return m ? { token, id: m[1], digest: m[2] } : { token, problem: `${flag} ${token} is not <id>@<sha256>` }; });
}

// fix2 (opus N1, gpt F3): a replay file is a claim, like a waiver file: anyone who can write the worktree can write it.
// Its digest is the sha256 of the file's bytes; it binds only when the invocation names it with
// --accept-replay <receipt>@<digest> (the delegator's own lane, evidence check or owner-gates run).
const defaultReplayFiles = cwd => {
  const dir = path.join(cwd, '.build/mado-verify/replay');
  try { return fs.readdirSync(dir).filter(n => n.endsWith('.json')).sort().map(n => path.join(dir, n)); } catch { return []; }
};
export const replayFileDigest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const loadReplays = files => files.flatMap(file => {
  let digest; try { digest = replayFileDigest(file); } catch { return []; }
  const r = readJson(file);
  return r && typeof r.receipt === 'string' && typeof r.verdict === 'string' ? [{ ...r, file: path.basename(file), digest }] : [];
});
const replayKey = r => `${r.verdict}:${r.red?.assertion === true}`;

const ignoredPaths = (cwd, paths) => paths.length ? new Set(nul(git(cwd, ['check-ignore', '-z', '--stdin'], paths.join('\0') + '\0').stdout || '')) : new Set();

export function evaluateSeparation({ worktree, base, head, archiveDir = defaultArchiveDir(), waiverDir = defaultWaiverDir(),
  receiptFiles = [], rebasedFrom, mode = TDD_SEPARATION_MODE, issue, acceptedWaivers = [], replayFiles, acceptedReplays = [] } = {}) {
  const cwd = worktree;
  const baseSha = resolveCommit(cwd, base), headSha = resolveCommit(cwd, head);
  if (!baseSha) throw new Error(`base ${base} is not a commit in ${cwd}`);
  if (!headSha) throw new Error(`head ${head} is not a commit in ${cwd}`);
  if (rebasedFrom) return carryOver({ cwd, baseSha, headSha, archiveDir, waiverDir, receiptFiles, rebasedFrom, mode, issue, acceptedWaivers, replayFiles, acceptedReplays });
  const result = { lane: 'tdd-separation', version: LANE_VERSION, mode, base: baseSha, head: headSha, verdict: 'pass',
    counts: { receipts: 0, held: 0, refused: 0, unknown: 0, waived: 0, exceptions: 0 },
    receipts: [], outside: [], exceptions: [], waivers: [], claims: [], acceptProblems: [], invalidWaivers: [], replayNeeded: [], replayClaims: [] };
  const commits = listCommits(cwd, baseSha, headSha);
  for (const c of commits) c.production = c.paths.filter(isProductionPath);
  const ids = [...new Set(commits.flatMap(c => c.red))];
  if (!ids.length && !commits.some(c => c.production.length)) {
    result.verdict = 'skipped'; result.reason = 'no Red-Receipt trailer and no production change in base..head';
    return result;
  }
  const ctx = { cwd, head: headSha, archiveDir, local: localReceipts([path.join(cwd, '.claude/tdd-guardian/receipts.json'), ...receiptFiles]) };
  const inTree = new Set(nul(gitOut(cwd, ['ls-tree', '-r', '-z', '--name-only', headSha])));
  const touched = new Set(commits.flatMap(c => c.paths));
  const waivers = loadWaivers(waiverDir);
  const windows = new Map();
  for (const id of ids) {
    const carriers = commits.filter(c => c.red.includes(id));
    const entry = { id, impl: carriers[0].sha, status: 'held', problems: [], production: [] };
    const refuse = text => { entry.problems.push(text); entry.status = 'refused'; };
    const unknown = text => { entry.problems.push(text); if (entry.status === 'held') entry.status = 'unknown'; };
    const { found, problem } = findReceipt(ctx, id);
    if (!found) unknown(problem);
    else {
      const r = found.receipt;
      entry.source = found.source;
      entry.headSha = r.head_sha;
      if (r.verdict === 'SEPARATION-BROKEN') refuse('plugin verdict SEPARATION-BROKEN');
      else if (r.verdict !== 'SEPARATION-HELD') unknown(`receipt is not verified (verdict ${r.verdict ?? 'none'})`);
      const dirty = Array.isArray(r.dirty_source) ? r.dirty_source.filter(p => typeof p === 'string') : null;
      if (!dirty) unknown('receipt has no dirty_source list');
      else {
        if (dirty.length >= DIRTY_SOURCE_CAP)
          unknown(`dirty_source has ${dirty.length} entries; the plugin keeps only the first ${DIRTY_SOURCE_CAP} (truncated), so production paths may be missing`);
        const candidates = dirty.filter(p => isProductionPath(p) && (inTree.has(p) || touched.has(p)));
        const ignored = ignoredPaths(cwd, candidates);
        entry.production = candidates.filter(p => !ignored.has(p)).sort();
        if (entry.production.length) refuse(`production file(s) differed from head_sha when the RED was recorded: ${entry.production.join(', ')}`);
      }
      const red = resolveCommit(cwd, r.head_sha);
      if (!red) unknown(`head_sha ${r.head_sha} is not a commit in this repository (rebased? rerun with --rebased-from <old-base>..<old-head>)`);
      else if (red === entry.impl) refuse(`head_sha equals the implementation commit ${red.slice(0, 7)}; the RED must be recorded on a strict ancestor`);
      else if (!isAncestor(cwd, red, entry.impl)) {
        if (!isAncestor(cwd, red, headSha)) unknown(`head_sha ${red.slice(0, 7)} is not in this history (rebased? rerun with --rebased-from <old-base>..<old-head>)`);
        else refuse(`head_sha ${red.slice(0, 7)} is not a strict ancestor of the implementation commit ${entry.impl.slice(0, 7)}`);
      } else windows.set(id, { from: red, to: carriers.at(-1).sha });
    }
    result.receipts.push(entry);
  }
  // fix1 (gpt M1, opus M1): a Stub-For commit that changed production while its receipt's RED window changes none may hold
  // the whole implementation (the RED then came from a wrong test fixed later). Not refused by itself: a replay decides.
  for (const entry of result.receipts) {
    const w = windows.get(entry.id);
    if (!w || entry.status !== 'held') continue;
    const stubbed = commits.some(c => c.stubFor.includes(entry.id) && c.production.length);
    const windowProduction = commits.some(c => c.production.length && c.sha !== w.from && isAncestor(cwd, w.from, c.sha) && isAncestor(cwd, c.sha, w.to));
    if (stubbed && !windowProduction) {
      entry.flag = 'stub-only-window';
      entry.status = 'unknown';
      entry.problems.push('its Stub-For commit changed production but its RED window changes none: the stub may hold the implementation; replay required');
    }
  }
  // fix1 (gpt F3, opus M4): replay is required for a receipt that is not held (refused/unknown: a waiver can only cover it
  // with a replay), a stub-only window, and a held receipt whose implementation commit is a bug fix (`fix(...)`). A replay
  // binds when its JSON (replay --out, read from <wt>/.build/mado-verify/replay/ or --replay) names this receipt, its
  // head_sha and this head, AND the invocation accepted its file digest (--accept-replay, fix2). Missing: unknown (a waived
  // receipt stays waived but the verdict is not pass). no-red, no-green or rejected: refused; accepted results that
  // disagree: refused. An unaccepted file is shown as CLAIMED-REPLAY and decides nothing.
  const replays = loadReplays(replayFiles ?? defaultReplayFiles(cwd));
  const acceptedR = parseAccepted(acceptedReplays, '--accept-replay');
  const isAcceptedReplay = r => acceptedR.some(a => a.id === r.receipt && r.digest.startsWith(a.digest));
  for (const r of replays) if (ids.includes(r.receipt)) result.replayClaims.push({ receipt: r.receipt, file: r.file, digest: r.digest, verdict: r.verdict, head: r.head, accepted: isAcceptedReplay(r) });
  for (const a of acceptedR) {
    if (a.problem) { result.acceptProblems.push(a.problem); continue; }
    const hit = replays.filter(r => r.receipt === a.id && r.digest.startsWith(a.digest));
    if (!hit.length) result.acceptProblems.push(`accepted replay ${a.id}@${a.digest.slice(0, 12)} matches no replay file for that receipt (changed after acceptance?)`);
    else if (!hit.some(r => r.head === headSha)) result.acceptProblems.push(`accepted replay ${a.id}@${a.digest.slice(0, 12)} (${hit[0].file}) is for head ${sha7(hit[0].head)}, not ${sha7(headSha)}`);
  }
  for (const entry of result.receipts) {
    const bugFix = commits.some(c => c.sha === entry.impl && /^fix(\([^)]*\))?!?:/.test(c.subject));
    const why = entry.flag ?? (entry.status !== 'held' ? entry.status : bugFix ? 'bug fix' : null);
    if (!why) continue;
    entry.replayRequired = why;
    const red = resolveCommit(cwd, entry.headSha ?? '');
    const bound = replays.filter(r => r.receipt === entry.id && r.head === headSha && r.headSha && r.headSha === red && isAcceptedReplay(r));
    if (!bound.length) {
      entry.replayMissing = true;
      if (entry.status === 'held') { entry.status = 'unknown'; entry.problems.push(`replay required (${why}): none accepted for this receipt and head`); }
      else if (!entry.problems.some(p => /replay required/.test(p))) entry.problems.push(`replay required (${why}): none accepted for this receipt and head`);
      continue;
    }
    if (new Set(bound.map(replayKey)).size > 1) {
      entry.replay = { verdict: 'disagree', files: bound.map(r => r.file), digest: bound[0].digest, file: bound.map(r => r.file).join('+') };
      entry.status = 'refused'; entry.problems.push(`accepted replays disagree: ${bound.map(r => `${r.file} ${r.verdict}`).join(', ')}`);
      continue;
    }
    const [first] = bound;
    entry.replay = { verdict: first.verdict, file: first.file, digest: first.digest };
    if (first.verdict === 'discriminates' && first.red?.assertion === true) { if (entry.flag) entry.status = 'held'; }
    else { entry.status = 'refused'; entry.problems.push(`replay ${first.verdict}${first.reason ? ` (${first.reason})` : ''}`); }
  }
  const unknownIds = new Set(result.receipts.filter(e => e.status === 'unknown' && !e.flag).map(e => e.id));
  const held = new Map(result.receipts.filter(e => windows.has(e.id) && (e.status === 'held' || e.flag)).map(e => [e.id, e]));
  for (const c of commits) {
    if (c.production.length) {
      // fix1 (opus F1): `Refactor: <receipt-id> <why>` is an exception only after that receipt's implementation commit, for a
      // receipt in this range whose RED window holds. Otherwise the commit is judged like any other production commit, so
      // implementation-first + a Refactor: line + no RED is OUTSIDE (refused), never pass.
      const anchored = c.refactor.map(note => ({ note, id: note.split(/\s+/)[0] }))
        .find(({ id }) => held.has(id) && held.get(id).impl !== c.sha && isAncestor(cwd, held.get(id).impl, c.sha));
      if (anchored) { result.exceptions.push({ kind: 'refactor', commit: c.sha, subject: c.subject, receipt: anchored.id, note: anchored.note }); continue; }
      const stub = c.stubFor.some(id => windows.has(id) && isAncestor(cwd, c.sha, windows.get(id).from));
      const inWindow = [...windows.values()].some(w => w.from !== c.sha && isAncestor(cwd, w.from, c.sha) && isAncestor(cwd, c.sha, w.to));
      // A commit tied to a receipt that cannot be judged is part of that unknown, not a separate refusal.
      const unjudged = [...c.red, ...c.stubFor].some(id => unknownIds.has(id));
      if (!stub && !inWindow && !unjudged) result.outside.push({ commit: c.sha, subject: c.subject, paths: c.production });
    } else if (!c.red.length && !c.stubFor.length && c.paths.some(isTestPath)) {
      result.exceptions.push({ kind: 'test-after-green', commit: c.sha, subject: c.subject, note: 'test change without a RED: review it with a manual mutant' });
    }
  }
  // Waiver claims for this ticket (a receipt waiver, optionally limited to paths, or a commit waiver); applied only when accepted.
  const refs = [...new Set(commits.flatMap(c => c.refs))];
  const ticket = Number.isSafeInteger(Number(issue)) && Number(issue) > 0 ? Number(issue) : refs.length === 1 ? refs[0] : null;
  result.issue = ticket;
  const scoped = waivers.valid.filter(w => w.issue === ticket);
  const rangeShas = new Set(commits.map(c => c.sha));
  result.invalidWaivers = waivers.invalid.filter(w => ids.includes(w.receipt) || rangeShas.has(w.commit)).filter(w => !Number.isSafeInteger(w.issue) || w.issue === ticket);
  const claim = (w, target) => { if (!result.claims.some(c => c.id === w.id)) result.claims.push({ id: w.id, digest: w.digest, issue: w.issue, ...target }); return w; };
  const receiptClaims = new Map(), outsideClaims = new Map();
  for (const entry of result.receipts) {
    if (entry.status === 'held') continue;
    const w = scoped.find(x => x.receipt === entry.id && (!x.paths ||
      (entry.status === 'refused' && entry.problems.filter(p => !/^replay required/.test(p)).length === 1 && entry.production.length && entry.production.every(p => x.paths.includes(p)))));
    if (w) receiptClaims.set(entry, claim(w, { receipt: entry.id }));
  }
  for (const o of result.outside) {
    const w = scoped.find(x => x.commit === o.commit);
    if (w) outsideClaims.set(o, claim(w, { commit: o.commit }));
  }
  const rawStatus = s => result.receipts.filter(e => e.status === s).length;
  result.raw = { verdict: rawStatus('refused') || result.outside.length ? 'refused' : rawStatus('unknown') || result.receipts.some(e => e.replayMissing) ? 'unknown' : 'pass',
    counts: { receipts: result.receipts.length, held: rawStatus('held'), refused: rawStatus('refused'), unknown: rawStatus('unknown'), waived: 0, exceptions: result.exceptions.length } };
  const accepted = parseAccepted(acceptedWaivers);
  const isAccepted = w => accepted.some(a => a.id === w.id && w.digest.startsWith(a.digest));
  for (const a of accepted) {
    if (a.problem) { result.acceptProblems.push(a.problem); continue; }
    const c = result.claims.find(x => x.id === a.id);
    if (!c) result.acceptProblems.push(`accepted waiver ${a.id} is not a claim on this range (wrong issue, expired, invalid or out of scope)`);
    else if (!c.digest.startsWith(a.digest)) result.acceptProblems.push(`accepted waiver ${a.id}: digest ${a.digest.slice(0, 12)} does not match the file's ${c.digest.slice(0, 12)} (changed after acceptance?)`);
  }
  // A replay that ran and did not discriminate is a refusal no waiver covers.
  for (const [entry, w] of receiptClaims) if (isAccepted(w) && !(entry.replay && entry.replay.verdict !== 'discriminates')) { entry.rawStatus = entry.status; entry.status = 'waived'; entry.waiver = w.id; result.waivers.push(w.id); }
  for (const [o, w] of outsideClaims) if (isAccepted(w)) { o.waiver = w.id; result.waivers.push(w.id); }
  for (const c of result.claims) c.accepted = result.waivers.includes(c.id);
  const status = s => result.receipts.filter(e => e.status === s).length;
  result.counts = { receipts: result.receipts.length, held: status('held'), refused: status('refused'), unknown: status('unknown'),
    waived: status('waived') + result.outside.filter(o => o.waiver).length, exceptions: result.exceptions.length };
  result.verdict = result.counts.refused || result.outside.some(o => !o.waiver) ? 'refused'
    : result.counts.unknown || result.receipts.some(e => e.replayMissing) ? 'unknown' : 'pass';
  result.replayNeeded = result.receipts.filter(e => e.replayRequired && !(e.replay?.verdict === 'discriminates')).map(e => e.id);
  // fix2: the raw view is the run without any acceptance (no waiver, no replay), so an implementer's stored result still
  // matches the delegator's accepted recomputation (gate-policy.mjs sameResult).
  if (acceptedReplays.length) {
    const bare = evaluateSeparation({ worktree, base: baseSha, head: headSha, archiveDir, waiverDir, receiptFiles, mode, issue, replayFiles });
    result.raw = { ...bare.raw, outside: bare.outside.map(o => o.commit), claims: bare.claims.map(c => `${c.id}@${c.digest}`) };
    for (const e of result.receipts) e.rawStatus = bare.receipts.find(x => x.id === e.id)?.status ?? e.status;
  }
  return result;
}

// #898 AC 7: after a rebase the receipts' head_sha are out of the new history. Evaluate the old range (its commits still
// exist in the worktree) and carry the result only when every new commit is the old one replayed byte for byte: the old
// commit's binary diff applied (no whitespace fixing) to the new commit's parent gives exactly the new commit's tree, and
// the message is the same (fix1, gpt F5: git patch-id --stable ignores whitespace, so it is not CODE same). Merge commits
// do not map. Anything else is unknown. After a squash merge nothing can be re-checked on main.
function replaysExactly(cwd, oldSha, newSha) {
  const parents = sha => gitOut(cwd, ['rev-list', '--parents', '-n', '1', sha]).trim().split(' ').slice(1);
  const [oldParent, ...oldMore] = parents(oldSha), [newParent, ...newMore] = parents(newSha);
  if (!oldParent || !newParent || oldMore.length || newMore.length) return false;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tdd-carry-'));
  try {
    const env = { GIT_INDEX_FILE: path.join(dir, 'index') };
    if (git(cwd, ['read-tree', newParent], undefined, env).status !== 0) return false;
    const diff = git(cwd, ['diff', '--binary', '--full-index', '--no-renames', '--no-ext-diff', '--no-textconv', '--no-color', oldParent, oldSha]);
    if (diff.status !== 0) return false;
    if (diff.stdout && git(cwd, ['apply', '--cached', '--whitespace=nowarn'], diff.stdout, env).status !== 0) return false;
    const tree = git(cwd, ['write-tree'], undefined, env);
    return tree.status === 0 && tree.stdout.trim() === gitOut(cwd, ['rev-parse', `${newSha}^{tree}`]).trim();
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
function carryOver({ cwd, baseSha, headSha, archiveDir, waiverDir, receiptFiles, rebasedFrom, mode, issue, acceptedWaivers, replayFiles, acceptedReplays }) {
  const oldBase = resolveCommit(cwd, rebasedFrom.base), oldHead = resolveCommit(cwd, rebasedFrom.head);
  if (!oldBase || !oldHead) throw new Error(`--rebased-from ${rebasedFrom.base}..${rebasedFrom.head} is not two commits in ${cwd}`);
  const old = evaluateSeparation({ worktree: cwd, base: oldBase, head: oldHead, archiveDir, waiverDir, receiptFiles, mode, issue, acceptedWaivers, replayFiles, acceptedReplays });
  const before = listCommits(cwd, oldBase, oldHead), after = listCommits(cwd, baseSha, headSha);
  const mismatch = before.length !== after.length ? `the old range has ${before.length} commits, the new ${after.length}`
    : before.map((c, i) => c.body !== after[i].body || !replaysExactly(cwd, c.sha, after[i].sha) ? i : -1).find(i => i >= 0);
  const carried = { ...old, base: baseSha, head: headSha, rebasedFrom: { base: oldBase, head: oldHead } };
  if (mismatch === undefined) return { ...carried, carriedFrom: oldHead };
  const reason = typeof mismatch === 'string' ? `rebase: ${mismatch}; the old result does not map`
    : `rebase: commit ${mismatch + 1} of ${oldBase.slice(0, 7)}..${oldHead.slice(0, 7)} does not map to ${baseSha.slice(0, 7)}..${headSha.slice(0, 7)} (its replayed tree or its message differs)`;
  return { ...carried, verdict: 'unknown', reason, oldVerdict: old.verdict };
}

const sha7 = sha => String(sha).slice(0, 7);
export function summaryLine(r) {
  const mode = r?.mode ?? TDD_SEPARATION_MODE;
  if (!r || r.verdict === 'error') return `tdd-separation=error (${r?.reason ?? 'no result'}) mode=${mode}`;
  if (r.verdict === 'skipped') return `tdd-separation=skipped (${r.reason}) mode=${mode}`;
  const c = r.counts ?? {};
  const parts = [`tdd-separation=${r.verdict} mode=${mode} receipts=${c.receipts} held=${c.held} refused=${c.refused} unknown=${c.unknown} waived=${c.waived} exceptions=${c.exceptions}`];
  if (r.carriedFrom) parts.push(`carried-from=${sha7(r.carriedFrom)}`);
  if (r.reason) parts.push(`(${r.reason})`);
  const ids = s => (r.receipts ?? []).filter(e => e.status === s).map(e => e.id);
  if (ids('refused').length) parts.push(`REFUSED ${ids('refused').join(',')}`);
  if (ids('unknown').length) parts.push(`UNKNOWN ${ids('unknown').join(',')}`);
  const outside = (r.outside ?? []).filter(o => !o.waiver);
  if (outside.length) parts.push(`OUTSIDE ${outside.map(o => sha7(o.commit)).join(',')}`);
  if (r.waivers?.length) parts.push(`WAIVED ${r.waivers.join(',')}`);
  const claimed = (r.claims ?? []).filter(c => !c.accepted);
  if (claimed.length) parts.push(`CLAIMED-WAIVER ${claimed.map(c => `${c.id}@${String(c.digest).slice(0, 12)}`).join(',')}`);
  if (r.acceptProblems?.length) parts.push(`ACCEPT-PROBLEM ${r.acceptProblems.length}`);
  const decided = (r.receipts ?? []).filter(e => e.replay);
  if (decided.length) parts.push(`REPLAY ${decided.map(e => `${e.id}@${String(e.replay.digest).slice(0, 12)}=${e.replay.verdict}:${e.replay.file}`).join(',')}`);
  const claimedReplays = (r.replayClaims ?? []).filter(c => !c.accepted);
  if (claimedReplays.length) parts.push(`CLAIMED-REPLAY ${claimedReplays.map(c => `${c.receipt}@${String(c.digest).slice(0, 12)}`).join(',')}`);
  if (r.invalidWaivers?.length) parts.push(`INVALID-WAIVER ${r.invalidWaivers.map(w => w.id ?? '?').join(',')}`);
  if (r.exceptions?.length) parts.push(`EXCEPTIONS ${r.exceptions.map(e => `${e.kind}:${sha7(e.commit)}`).join(',')}`);
  if (typeof r.required === 'boolean') parts.push(`required=${r.required ? 'yes' : 'no'}`);
  return parts.join(' ');
}
export const gateExitCode = (r, mode = TDD_SEPARATION_MODE, required = true) => mode !== 'mandatory' ? 0
  : r?.verdict === 'error' || (required && ['refused', 'unknown'].includes(r?.verdict)) ? 1 : 0;

// Replay (#898 AC 4): the production tree at the receipt's head_sha plus the receipt's test files from HEAD must fail by
// assertion, and HEAD must pass, with the same filter. Zero selected tests, a crash or an environment exit is rejected.
// node: node --test with --test-name-pattern (under the worktree's scripts/heavy-lock.sh when it has one);
// swift: scripts/tdd/swift-lane.mjs <filter> (it takes the heavy lock itself; exit 1 assertion, 0 pass, 70 rejected).
function laneCommand(dir, kind, filter, tests) {
  if (kind === 'node') {
    const cmd = [process.execPath, '--test', '--test-reporter=tap', '--test-concurrency=1', `--test-name-pattern=${filter}`, ...tests];
    return fs.existsSync(path.join(dir, 'scripts/heavy-lock.sh')) ? ['scripts/heavy-lock.sh', ...cmd] : cmd;
  }
  if (kind === 'swift') return [process.execPath, 'scripts/tdd/swift-lane.mjs', filter];
  throw new Error(`replay kind ${kind} is not supported (node or swift; App tests need build-for-testing in the replay tree first)`);
}
function runPhase(dir, cmd, kind) {
  const r = spawnSync(cmd[0], cmd.slice(1), { cwd: dir, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 30 * 60_000, env: runEnv });
  const out = `${r.stdout ?? ''}\n${r.stderr ?? ''}`;
  const count = name => Number(new RegExp(`^# ${name} (\\d+)$`, 'm').exec(out)?.[1] ?? NaN);
  const swift = /Test run with (\d+) tests?/.exec(out);
  // node 22 reports a file whose filter selected nothing as one passing test point named after the file; not a test.
  const emptyFiles = kind === 'node' && /^1\.\.0$/m.test(out) ? (out.match(/^ok \d+ - \S+\.(?:test|spec)\.[cm]?[jt]s\s*$/gm) ?? []).length : 0;
  const tests = kind === 'node' ? count('tests') - emptyFiles : swift ? Number(swift[1]) : NaN;
  const failed = kind === 'node' ? count('fail') : r.status === 1 ? 1 : 0;
  // fix1 (opus M4): a RED must fail by assertion. node: every failing test point (a parent that failed only because of its
  // subtests aside) carries code ERR_ASSERTION; a file that fails to load or a thrown non-assertion error does not.
  // swift: scripts/tdd/swift-lane.mjs exits 1 only for assertion failures (70 for compile errors, zero tests or crashes).
  let assertion = r.status === 1;
  if (kind === 'node') {
    const blocks = [...out.matchAll(/^\s*not ok \d+ - .*\n((?:\s+.*\n)*?)\s+\.\.\.$/gm)].map(m => m[1]);
    const leaves = blocks.filter(b => !/failureType: 'subtestsFailed'/.test(b));
    assertion = leaves.length > 0 && leaves.every(b => /^\s+code: 'ERR_ASSERTION'$/m.test(b));
  }
  return { command: cmd.map(a => a === process.execPath ? 'node' : a).join(' '), exitCode: r.status ?? -1, signal: r.signal ?? null,
    tests, failed, assertion, tail: out.trim().split('\n').slice(-8).join('\n') };
}
// fix1 (gpt F4): a test file is copied into the RED tree only as a regular blob at HEAD, to a path inside the temporary
// worktree with no symlink on the way (a tracked symlink at head_sha would otherwise redirect the write outside it).
function safeDestination(root, file) {
  const parts = file.split('/');
  if (path.isAbsolute(file) || parts.some(p => !p || p === '.' || p === '..')) return { problem: `test path ${file} is not a plain repository path` };
  let at = root;
  for (const part of parts) {
    at = path.join(at, part);
    let stat; try { stat = fs.lstatSync(at); } catch { break; }
    if (stat.isSymbolicLink()) return { problem: `test path ${file} goes through a symlink in the head_sha tree (${path.relative(root, at)})` };
  }
  const dest = path.join(root, file);
  if (!dest.startsWith(root + path.sep)) return { problem: `test path ${file} resolves outside the replay tree` };
  return { dest };
}
export function replay({ worktree, head, receiptId, kind, filter, archiveDir = defaultArchiveDir(), receiptFiles = [], out }) {
  const cwd = worktree, headSha = resolveCommit(cwd, head);
  if (!headSha) throw new Error(`head ${head} is not a commit`);
  if (typeof filter !== 'string' || !filter) throw new Error('replay needs the WI filter (the one the receipt was recorded with)');
  const ctx = { cwd, head: headSha, archiveDir, local: localReceipts([path.join(cwd, '.claude/tdd-guardian/receipts.json'), ...receiptFiles]) };
  const { found, problem } = findReceipt(ctx, receiptId);
  if (!found) throw new Error(problem);
  const redSha = resolveCommit(cwd, found.receipt.head_sha);
  if (!redSha) throw new Error(`head_sha ${found.receipt.head_sha} is not a commit here`);
  const tests = Object.keys(found.receipt.test_files ?? {});
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'tdd-replay-')));
  const redDir = path.join(root, 'red'), greenDir = path.join(root, 'green');
  const result = { lane: 'tdd-separation-replay', receipt: receiptId, headSha: redSha, head: headSha, kind, filter, tests };
  const added = [];
  // fix1 (gpt M3, opus L5): remove only the two worktrees this replay added, report a failed removal, never prune globally;
  // SIGINT/SIGTERM between phases run the same cleanup before exiting.
  const cleanup = () => {
    const problems = [];
    for (const dir of added.splice(0)) {
      const r = git(cwd, ['worktree', 'remove', '--force', dir]);
      if (r.status !== 0) problems.push(`git worktree remove ${dir}: ${(r.stderr || '').trim().split('\n')[0]}`);
    }
    if (!problems.length) fs.rmSync(root, { recursive: true, force: true });
    return problems;
  };
  const onSignal = signal => { cleanup(); process.exit(signal === 'SIGINT' ? 130 : 143); };
  process.once('SIGINT', onSignal); process.once('SIGTERM', onSignal);
  try {
    for (const [dir, sha] of [[redDir, redSha], [greenDir, headSha]]) { gitOut(cwd, ['worktree', 'add', '--detach', '--quiet', dir, sha]); added.push(dir); }
    for (const file of tests) {
      const entry = nul(gitOut(cwd, ['ls-tree', '-z', headSha, '--', file]))[0] ?? '';
      if (!/^100(644|755) blob [0-9a-f]+\t/.test(entry)) { result.verdict = 'rejected'; result.reason = `test file ${file} is not a regular file in HEAD`; return result; }
      const { dest, problem: bad } = safeDestination(redDir, file);
      if (bad) { result.verdict = 'rejected'; result.reason = bad; return result; }
      const show = git(cwd, ['show', `${headSha}:${file}`]);
      if (show.status !== 0) { result.verdict = 'rejected'; result.reason = `test file ${file} is not in HEAD`; return result; }
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, show.stdout);
    }
    result.red = runPhase(redDir, laneCommand(redDir, kind, filter, tests), kind);
    result.green = runPhase(greenDir, laneCommand(greenDir, kind, filter, tests), kind);
    const bad = p => p.signal || ![0, 1].includes(p.exitCode) || !(p.tests > 0);
    if (bad(result.red) || bad(result.green)) result.verdict = 'rejected';
    else if (result.red.exitCode === 0) result.verdict = 'no-red';
    else if (!result.red.assertion) { result.verdict = 'rejected'; result.reason = 'the RED side did not fail by assertion (a load, import or thrown non-assertion error is not a RED)'; }
    else result.verdict = result.green.exitCode !== 0 ? 'no-green' : 'discriminates';
    return result;
  } finally {
    process.removeListener('SIGINT', onSignal); process.removeListener('SIGTERM', onSignal);
    result.cleanupProblems = cleanup();
    if (out) {
      fs.mkdirSync(path.dirname(out), { recursive: true }); fs.writeFileSync(out, JSON.stringify(result, null, 2) + '\n');
      // fix2: the file is a claim until accepted; print the token that binds exactly these bytes.
      process.stderr.write(`tdd-separation replay: ${out} verdict=${result.verdict ?? 'none'}; bind it with --accept-replay ${receiptId}@${replayFileDigest(out)}\n`);
    }
  }
}

function parseArgs(args) {
  const o = { receiptFiles: [], acceptedWaivers: [] };
  const flags = { '--worktree': 'worktree', '--base': 'base', '--head': 'head', '--out': 'out', '--archive': 'archiveDir', '--waivers': 'waiverDir',
    '--receipt': 'receiptId', '--kind': 'kind', '--filter': 'filter', '--issue': 'issue' };
  const lists = { '--receipts': 'receiptFiles', '--accept-waiver': 'acceptedWaivers', '--replay': 'replayFiles', '--accept-replay': 'acceptedReplays' };
  while (args.length) {
    const flag = args.shift();
    if (flag === '--mandatory') { o.mode = 'mandatory'; continue; }
    const value = args.shift();
    if (value === undefined) throw new Error(`${flag} needs a value`);
    if (lists[flag]) (o[lists[flag]] ??= []).push(value);
    else if (flag === '--rebased-from') {
      const m = /^([^.]+)\.\.([^.]+)$/.exec(value);
      if (!m) throw new Error('--rebased-from needs <old-base>..<old-head>');
      o.rebasedFrom = { base: m[1], head: m[2] };
    } else if (flags[flag]) o[flags[flag]] = value;
    else throw new Error(`unknown option ${flag}`);
  }
  o.worktree ??= process.cwd();
  return o;
}
function main() {
  const [mode, ...rest] = process.argv.slice(2);
  if (mode === 'gate') {
    let result, out, mode = rest.includes('--mandatory') ? 'mandatory' : TDD_SEPARATION_MODE;
    try {
      const o = parseArgs(rest); out = o.out; mode = o.mode ?? TDD_SEPARATION_MODE;
      result = evaluateSeparation(o);
      const files = listDiffPaths(o.worktree, result.base, result.head);
      result.required = files === null ? true : tddSeparationRequired(files);
    } catch (error) {
      result = { lane: 'tdd-separation', version: LANE_VERSION, mode, verdict: 'error', reason: String(error.message).replace(/\s+/g, ' ').replace(/[()]/g, '') };
    }
    if (out) { try { fs.writeFileSync(out, JSON.stringify(result, null, 2) + '\n'); } catch (error) { result = { ...result, verdict: 'error', reason: `cannot write ${out}` }; } }
    console.log(summaryLine(result));
    return gateExitCode(result, mode, result.required ?? true);
  }
  if (mode === 'evaluate') { console.log(JSON.stringify(evaluateSeparation(parseArgs(rest)), null, 2)); return 0; }
  if (mode === 'replay') {
    const r = replay(parseArgs(rest));
    console.log(JSON.stringify(r, null, 2));
    return r.verdict === 'discriminates' ? 0 : 1;
  }
  throw new Error('usage: tdd-separation.mjs gate|evaluate|replay --worktree <wt> --base <sha> --head <sha> … (see the file header)');
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { process.exitCode = main(); } catch (error) { console.error(`tdd-separation: ${error.message}`); process.exitCode = 2; }
}
