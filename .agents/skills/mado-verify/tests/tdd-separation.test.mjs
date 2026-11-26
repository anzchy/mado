// #898: the tdd-separation lane. Evidence that each RED was recorded on a clean committed tree (not proof of test-first).
// Every case is a real Git fixture: commits, trailers, receipts.json, an archive and a delegator waiver directory.
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as sep from '../scripts/tdd-separation.mjs';
import * as policy from '../scripts/gate-policy.mjs';

const skill = fileURLToPath(new URL('../', import.meta.url));
const lane = path.join(skill, 'scripts', 'tdd-separation.mjs');
const evidence = path.join(skill, 'scripts', 'evidence.mjs');
const run = (cmd, args, cwd, env) => spawnSync(cmd, args, { cwd, encoding: 'utf8', env: env ?? process.env });
const fileDigest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const tmp = (t, prefix) => { const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix)); t.after(() => fs.rmSync(d, { recursive: true, force: true })); return d; };

function repo(t) {
  const dir = tmp(t, 'tdd-sep-'), home = tmp(t, 'tdd-sep-home-');
  const git = (...args) => { const r = run('git', args, dir); assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`); return r.stdout.trim(); };
  git('init', '-q', '-b', 'main'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'Fixture');
  git('config', 'commit.gpgsign', 'false');
  const write = (rel, text) => { const p = path.join(dir, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, text); };
  write('App/Foo.swift', 'struct Foo {}\n');
  write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() {}\n');
  write('docs/a.md', 'doc\n');
  write('.gitignore', 'App/Build/\n.build/\n.claude/tdd-guardian/receipts.json\n');
  git('add', '-A'); git('commit', '-qm', 'base');
  const base = git('rev-parse', 'HEAD');
  git('update-ref', 'refs/remotes/origin/main', base);
  git('switch', '-q', '-c', 'topic');
  const commit = (subject, trailers = []) => {
    git('add', '-A');
    git('commit', '-q', '--allow-empty', '-m', subject + (trailers.length ? `\n\nRefs #1\n${trailers.join('\n')}` : ''));
    return git('rev-parse', 'HEAD');
  };
  // The lane's defaults under HOME, so evidence.mjs (run with HOME=home) reads the same directories.
  const archive = path.join(home, '.mado/archive/tdd-guardian/receipts'), waivers = path.join(home, '.mado/herdr/delegator/tdd-waivers');
  fs.mkdirSync(archive, { recursive: true }); fs.mkdirSync(waivers, { recursive: true });
  const receipts = list => write('.claude/tdd-guardian/receipts.json', JSON.stringify({ schemaVersion: 2, receipts: list }));
  const evaluate = (extra = {}) => sep.evaluateSeparation({ worktree: dir, base, head: git('rev-parse', 'HEAD'), archiveDir: archive, waiverDir: waivers, ...extra });
  return { dir, home, base, git, write, commit, receipts, archive, waivers, evaluate, head: () => git('rev-parse', 'HEAD') };
}
const receipt = (id, head_sha, dirty = [], extra = {}) => ({ id, lane: 'swift-red', head_sha, dirty_source: dirty,
  red: { red: true, kind: 'assertion-failure' }, test_files: { 'Packages/MadoKit/Tests/CoreTests/FooTests.swift': { state: 'ok', lines: [] } },
  verdict: 'SEPARATION-HELD', verified_at: '2026-11-25T00:00:00.000Z', recorded_at: '2026-11-25T00:00:00.000Z', ...extra });
const trailer = id => `Red-Receipt: ${id} swift-red assertion-failure spec-files=1 SEPARATION-HELD`;

// The compliant flow: a signatures-only stub commit, the RED recorded on that clean tree, the implementation commit.
function compliant(f, dirty = ['.tokenize/ledger/1.ndjson']) {
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { fatalError() } }\n');
  const stub = f.commit('stub', ['Stub-For: R1']);
  f.receipts([receipt('R1', stub, dirty)]);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 } }\n');
  f.write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() { #expect(Foo().bar() == 1) }\n');
  const impl = f.commit('impl', [trailer('R1')]);
  return { stub, impl };
}

test('898 WI-1 stub commit, then a clean RED, then the implementation commit is accepted', t => {
  const f = repo(t); compliant(f);
  const r = f.evaluate();
  assert.equal(r.verdict, 'pass', JSON.stringify(r));
  assert.deepEqual(r.receipts.map(x => [x.id, x.status]), [['R1', 'held']]);
  assert.equal(r.counts.held, 1); assert.equal(r.counts.refused, 0); assert.equal(r.counts.unknown, 0);
  assert.match(sep.summaryLine(r), /^tdd-separation=pass mode=report-only receipts=1 held=1 refused=0 unknown=0 waived=0 exceptions=0\b/);
});

test('898 WI-1 a tracked production file in dirty_source is refused and named', t => {
  const f = repo(t); compliant(f, ['.tokenize/a.ndjson', 'App/Foo.swift']);
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused');
  assert.equal(r.receipts[0].status, 'refused');
  assert.deepEqual(r.receipts[0].production, ['App/Foo.swift']);
});

test('898 WI-1 a new untracked production file at RED (added later in the range) is refused', t => {
  const f = repo(t);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { fatalError() } }\n');
  const stub = f.commit('stub', ['Stub-For: R1']);
  f.receipts([receipt('R1', stub, ['App/New.swift'])]);
  f.write('App/New.swift', 'let impl = 1\n');
  f.commit('impl', [trailer('R1')]);
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused');
  assert.deepEqual(r.receipts[0].production, ['App/New.swift']);
});

test('898 WI-1 noise, ignored, test and documentation paths in dirty_source are accepted', t => {
  const f = repo(t);
  compliant(f, ['.tokenize/ledger/9.ndjson', 'App/Build/gen.swift', 'AppTests/Support/Helper.swift', 'docs/a.md', 'App/README.md', 'scratch/notes.txt']);
  const r = f.evaluate();
  assert.equal(r.verdict, 'pass', JSON.stringify(r.receipts));
  assert.deepEqual(r.receipts[0].production, []);
});

test('898 WI-1 path classes: tests, docs and production', () => {
  for (const p of ['Packages/MadoKit/Tests/CoreTests/FooTests.swift', 'AppTests/Support/Helper.swift', 'UITests/X.swift', 'TestAssets/a.png',
    'scripts/tdd/x.test.mjs', '.agents/skills/mado-verify/tests/a.mjs', 'scripts/foo/fixtures/a.json'])
    assert.equal(sep.isTestPath(p), true, p);
  for (const p of ['App/Foo.swift', 'Packages/MadoKit/Sources/MadoCore/Foo.swift', 'scripts/tdd/app-lane.mjs', 'project.yml'])
    assert.equal(sep.isTestPath(p), false, p);
  for (const p of ['docs/a.md', 'App/README.md', '.agents/skills/mado-verify/SKILL.md']) assert.equal(sep.isDocPath(p), true, p);
  assert.equal(sep.isProductionPath('App/Foo.swift'), true);
  assert.equal(sep.isProductionPath('docs/a.md'), false);
  assert.equal(sep.isProductionPath('AppTests/Support/Helper.swift'), false);
});

test('898 WI-1 a 50-entry dirty_source is truncated by the plugin and fails closed as unknown', t => {
  const f = repo(t);
  compliant(f, Array.from({ length: 50 }, (_, i) => `.tokenize/ledger/${String(i).padStart(3, '0')}.ndjson`));
  const r = f.evaluate();
  assert.equal(r.verdict, 'unknown');
  assert.equal(r.receipts[0].status, 'unknown');
  assert.match(r.receipts[0].problems.join(' '), /50 entries|truncated/);
});

test('898 WI-1 a RED recorded at the implementation commit itself (equality) is refused', t => {
  const f = repo(t);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 } }\n');
  const impl = f.commit('impl', [trailer('R1')]);
  f.receipts([receipt('R1', impl)]);
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused');
  assert.match(r.receipts[0].problems.join(' '), /strict ancestor|equal/);
});

test('898 WI-1 an implementation committed before its RED is refused (pre-committed implementation)', t => {
  const f = repo(t);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 } }\n');
  const early = f.commit('implementation first');
  f.receipts([receipt('R1', early)]);
  f.write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() { #expect(Foo().bar() == 1) }\n');
  f.commit('tests', [trailer('R1')]);
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused');
  assert.deepEqual(r.outside.map(x => x.commit), [early]);
  assert.deepEqual(r.outside[0].paths, ['App/Foo.swift']);
});

test('898 WI-1 a trailer whose receipt is in neither receipts.json nor the archive is unknown', t => {
  const f = repo(t); compliant(f);
  f.receipts([]);
  const r = f.evaluate();
  assert.equal(r.verdict, 'unknown');
  assert.match(r.receipts[0].problems.join(' '), /not found/);
});

test('898 WI-1 the archive envelope is read when the worktree has no receipts.json', t => {
  const f = repo(t); const { stub } = compliant(f);
  fs.rmSync(path.join(f.dir, '.claude/tdd-guardian/receipts.json'));
  fs.writeFileSync(path.join(f.archive, 'R1.json'), JSON.stringify({ schemaVersion: 1, worktree: 'w', receipt: receipt('R1', stub) }));
  const r = f.evaluate();
  assert.equal(r.verdict, 'pass', JSON.stringify(r.receipts));
  assert.equal(r.receipts[0].source, 'archive');
});

test('898 WI-1 a SEPARATION-BROKEN receipt is refused', t => {
  const f = repo(t); const { stub } = compliant(f);
  f.receipts([receipt('R1', stub, [], { verdict: 'SEPARATION-BROKEN' })]);
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused');
  assert.match(r.receipts[0].problems.join(' '), /SEPARATION-BROKEN/);
});

test('898 WI-1 a behaviour-preserving refactor commit is a named exception, not a refusal', t => {
  const f = repo(t); compliant(f);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { return 1 } }\n');
  const refactor = f.commit('refactor', ['Refactor: R1 inline return, behaviour unchanged']);
  const r = f.evaluate();
  assert.equal(r.verdict, 'pass', JSON.stringify(r));
  assert.deepEqual(r.exceptions.map(x => [x.kind, x.commit]), [['refactor', refactor]]);
  assert.equal(r.counts.exceptions, 1);
});

// fix1 WI-1 (opus F1, gpt M1, opus M1, L2): exceptions are anchored, not self-asserted.
test('898 fix1 WI-1 implementation first with a Refactor: line and no RED at all is refused, not pass', t => {
  const f = repo(t);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 } }\n');
  const impl = f.commit('implementation', ['Refactor: WI-1 tidy']);
  f.write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() { #expect(Foo().bar() == 1) }\n');
  f.commit('tests');
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused', JSON.stringify(r));
  assert.deepEqual(r.outside.map(x => x.commit), [impl]);
  assert.equal(r.exceptions.filter(x => x.kind === 'refactor').length, 0);
});

test('898 fix1 WI-1 a Refactor: commit before its receipt\'s implementation commit, or naming a receipt not in the range, is outside', t => {
  const f = repo(t);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { fatalError() } }\n');
  const stub = f.commit('stub', ['Stub-For: R1']);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 } }\n');
  const early = f.commit('early', ['Refactor: R1 claimed refactor']);
  f.receipts([receipt('R1', early)]);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 }; func baz() {} }\n');
  f.write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() { #expect(Foo().bar() == 1) }\n');
  f.commit('impl', [trailer('R1')]);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { return 1 }; func baz() {} }\n');
  const late = f.commit('refactor', ['Refactor: R2 names a receipt that is not in the range']);
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused', JSON.stringify(r));
  assert.deepEqual(r.outside.map(x => x.commit).sort(), [early, late].sort());
  assert.equal(stub.length, 40);
});

test('898 fix1 WI-1 trailers count only in the trailer block, not in prose', t => {
  const f = repo(t); compliant(f);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { return 1 } }\n');
  f.git('add', 'App/Foo.swift');
  f.git('commit', '-q', '-m', 'tidy', '-m', 'Refactor: R1 this line is prose in the body', '-m', 'More prose after it.', '-m', 'Refs #1');
  const prose = f.head();
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused', JSON.stringify(r));
  assert.deepEqual(r.outside.map(x => x.commit), [prose]);
  // The same trailer in the final paragraph (with a separate Co-Authored-By paragraph after it) counts.
  f.git('commit', '-q', '--amend', '-m', 'tidy', '-m', 'Why: prose.', '-m', 'Refs #1\nRefactor: R1 inline return', '-m', 'Co-Authored-By: X <x@example.invalid>');
  const ok = f.evaluate();
  assert.equal(ok.verdict, 'pass', JSON.stringify(ok));
  assert.deepEqual(ok.exceptions.map(x => x.kind), ['refactor']);
});

test('898 fix1 WI-1 a Stub-For commit whose RED window changes no production file needs a replay (unknown, replay required)', t => {
  const f = repo(t);
  // The "stub" holds the full implementation; the carrier only fixes a deliberately wrong test.
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 } }\n');
  const stub = f.commit('stub', ['Stub-For: R1']);
  f.receipts([receipt('R1', stub)]);
  f.write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() { #expect(Foo().bar() == 1) }\n');
  f.commit('test fix', [trailer('R1')]);
  const r = f.evaluate();
  assert.equal(r.verdict, 'unknown', JSON.stringify(r));
  assert.equal(r.receipts[0].status, 'unknown');
  assert.equal(r.receipts[0].flag, 'stub-only-window');
  assert.match(r.receipts[0].problems.join(' '), /replay/);
  assert.deepEqual(r.replayNeeded, ['R1']);
});

test('898 WI-1 a test-only commit after green without a RED trailer is a named exception', t => {
  const f = repo(t); compliant(f);
  f.write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() { #expect(Foo().bar() == 1); #expect(Foo().bar() > 0) }\n');
  const late = f.commit('more assertions');
  const r = f.evaluate();
  assert.equal(r.verdict, 'pass');
  assert.deepEqual(r.exceptions.map(x => [x.kind, x.commit]), [['test-after-green', late]]);
});

const waiver = (f, w, name = 'i1.json') => fs.writeFileSync(path.join(f.waivers, name), JSON.stringify({ waivers: [w] }));
const goodWaiver = { id: 'W1-1', issue: 1, receipt: 'R1', paths: ['App/Foo.swift'], reason: 'stub predates the rule; replay recorded in the handoff',
  issuedBy: 'delegator', ref: '~/.mado/herdr/opus-imple-1/i1-brief.md', expires: '2099-12-31' };
// fix1 WI-2: a waiver file is a claim; the delegator accepts it by id and content digest in its own invocation.
const claimsOf = r => { assert.ok(Array.isArray(r.claims), `no claims list: ${JSON.stringify(r)}`); return r.claims; };
const accept = (f, extra = {}) => claimsOf(f.evaluate(extra)).map(c => `${c.id}@${c.digest}`);

test('898 WI-1 a delegator waiver turns a refusal into WAIVED, counted and shown', t => {
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  waiver(f, goodWaiver);
  const r = f.evaluate({ acceptedWaivers: accept(f) });
  assert.equal(r.verdict, 'unknown', JSON.stringify(r)); // fix1 WI-4: a waived receipt still needs its replay
  assert.equal(r.receipts[0].status, 'waived');
  assert.equal(r.receipts[0].waiver, 'W1-1');
  assert.equal(r.counts.waived, 1);
  assert.deepEqual(r.waivers, ['W1-1']);
  assert.deepEqual(r.replayNeeded, ['R1']);
  assert.match(sep.summaryLine(r), /waived=1\b.*WAIVED W1-1/);
});

test('898 WI-1 an implementer-written, unreasoned or out-of-scope waiver does not count', t => {
  for (const bad of [{ ...goodWaiver, issuedBy: 'opus-imple-1' }, { ...goodWaiver, reason: ' ' }, { ...goodWaiver, paths: ['App/Other.swift'] },
    { ...goodWaiver, ref: '' }]) {
    const f = repo(t); compliant(f, ['App/Foo.swift']);
    waiver(f, bad);
    const r = f.evaluate();
    assert.equal(r.verdict, 'refused', JSON.stringify(bad));
    assert.equal(r.counts.waived, 0);
    assert.equal(r.invalidWaivers.length, bad.paths?.[0] === 'App/Other.swift' ? 0 : 1, JSON.stringify(r.invalidWaivers));
  }
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  const real = path.join(f.home, 'w.json'); fs.writeFileSync(real, JSON.stringify({ waivers: [goodWaiver] }));
  fs.symlinkSync(real, path.join(f.waivers, 'link.json'));
  assert.equal(f.evaluate().verdict, 'refused', 'a symlinked waiver file is not read');
});

test('898 fix1 WI-2 a well-formed waiver file nobody accepted is only a claim: refused, CLAIMED-WAIVER with its digest', t => {
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  waiver(f, goodWaiver); // written by whoever can write the directory, e.g. an implementer pane
  const r = f.evaluate();
  assert.equal(r.verdict, 'refused', JSON.stringify(r));
  assert.equal(r.counts.waived, 0);
  assert.deepEqual(r.waivers, []);
  assert.deepEqual(r.claims.map(c => c.id), ['W1-1']);
  assert.match(r.claims[0].digest, /^[0-9a-f]{64}$/);
  assert.match(sep.summaryLine(r), /CLAIMED-WAIVER W1-1@[0-9a-f]{12}/);
  assert.doesNotMatch(sep.summaryLine(r), /\bWAIVED\b/);
});

test('898 fix1 WI-2 an accepted waiver whose file changed after acceptance (digest differs) is not applied', t => {
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  waiver(f, goodWaiver);
  const accepted = accept(f);
  waiver(f, { ...goodWaiver, paths: ['App/Foo.swift', 'App/Other.swift'] });
  const r = f.evaluate({ acceptedWaivers: accepted });
  assert.equal(r.verdict, 'refused', JSON.stringify(r));
  assert.equal(r.counts.waived, 0);
  assert.match(String(r.acceptProblems), /W1-1.*digest/);
});

test('898 fix1 WI-2 a waiver for another issue, an expired one or one without expiry never applies', t => {
  for (const [bad, re] of [[{ ...goodWaiver, issue: 850 }, null], [{ ...goodWaiver, expires: '2020-01-01' }, /expired/], [{ ...goodWaiver, expires: undefined }, /expires/]]) {
    const f = repo(t); compliant(f, ['App/Foo.swift']);
    waiver(f, bad);
    const all = accept(f);
    const r = f.evaluate({ acceptedWaivers: all });
    assert.equal(r.verdict, 'refused', JSON.stringify(bad));
    assert.equal(r.counts.waived, 0);
    assert.deepEqual(r.claims, []);
    if (re) assert.match(r.invalidWaivers.map(w => w.reason).join(' '), re);
  }
  // The ticket is the --issue given, else the single `Refs #n` of the range's trailer blocks.
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  waiver(f, { ...goodWaiver, issue: 2 });
  assert.equal(claimsOf(f.evaluate()).length, 0);
  assert.equal(claimsOf(f.evaluate({ issue: 2 })).length, 1);
});

test('898 fix1 WI-2 a symlinked waiver directory is not read', t => {
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  const real = path.join(f.home, 'elsewhere'); fs.mkdirSync(real);
  fs.writeFileSync(path.join(real, 'i1.json'), JSON.stringify({ waivers: [goodWaiver] }));
  const linked = path.join(f.home, 'linked-waivers'); fs.symlinkSync(real, linked);
  const r = f.evaluate({ waiverDir: linked });
  assert.deepEqual(claimsOf(r), []);
  assert.equal(claimsOf(f.evaluate({ waiverDir: real })).length, 1);
});

test('898 fix1 WI-2 gate CLI and evidence check take --accept-waiver; the stored raw result still matches', t => {
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  fs.writeFileSync(path.join(f.waivers, 'i1.json'), JSON.stringify({ waivers: [goodWaiver] }));
  const [token] = accept(f);
  // fix1 WI-4: a waived receipt also needs its bound replay. fix2 WI-1: the replay file is a claim until the delegator
  // accepts it by file digest (--accept-replay), like the waiver.
  const stubSha = JSON.parse(fs.readFileSync(path.join(f.dir, '.claude/tdd-guardian/receipts.json'), 'utf8')).receipts[0].head_sha;
  f.write('.build/mado-verify/replay/R1.json', JSON.stringify({ receipt: 'R1', headSha: stubSha, head: f.head(), verdict: 'discriminates', red: { assertion: true } }));
  const replayToken = `R1@${fileDigest(path.join(f.dir, '.build/mado-verify/replay/R1.json'))}`;
  const gate = extra => run('node', [lane, 'gate', '--worktree', f.dir, '--base', f.base, '--head', f.head(), '--archive', f.archive, '--waivers', f.waivers, ...extra], f.dir);
  assert.match(gate([]).stdout, /^tdd-separation=refused .*CLAIMED-WAIVER W1-1@/);
  assert.match(gate(['--accept-waiver', token, '--issue', '1']).stdout, /^tdd-separation=unknown .*waived=1 .*WAIVED W1-1.*CLAIMED-REPLAY R1@/);
  assert.match(gate(['--accept-waiver', token, '--accept-replay', replayToken, '--issue', '1']).stdout, /^tdd-separation=pass .*waived=1 .*WAIVED W1-1.*REPLAY R1@[0-9a-f]{12}=discriminates:R1\.json/);
  recordFor(f, { tddSeparation: f.evaluate() });
  const plain = check(f);
  assert.equal(plain.status, 0, plain.stderr);
  assert.match(plain.stdout, /WARNING tdd-separation \(report-only\): verdict refused/);
  const waivedOnly = run('node', [evidence, 'check', '--head', f.head(), '--issue', '1', '--accept-waiver', token], f.dir, { ...process.env, HOME: f.home });
  assert.match(waivedOnly.stdout, /WARNING tdd-separation \(report-only\): verdict unknown/);
  const accepted = run('node', [evidence, 'check', '--head', f.head(), '--issue', '1', '--accept-waiver', token, '--accept-replay', replayToken], f.dir, { ...process.env, HOME: f.home });
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.doesNotMatch(accepted.stdout, /WARNING tdd-separation/);
});

test('898 WI-1 a commit waiver covers a production commit outside any RED window', t => {
  const f = repo(t);
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 1 } }\n');
  const early = f.commit('implementation first');
  f.receipts([receipt('R1', early)]);
  f.write('Packages/MadoKit/Tests/CoreTests/FooTests.swift', '@Test func a() {}\n');
  f.commit('tests', [trailer('R1')]);
  waiver(f, { id: 'W1-2', issue: 1, commit: early, reason: 'hotfix agreed before the RED; replay attached', issuedBy: 'Delegator', ref: 'https://github.com/anzchy/mado/issues/1#issuecomment-1', expires: '2099-12-31' });
  const r = f.evaluate({ acceptedWaivers: accept(f) });
  assert.equal(r.verdict, 'pass', JSON.stringify(r));
  assert.deepEqual(r.outside.map(x => [x.commit, x.waiver]), [[early, 'W1-2']]);
  assert.equal(r.counts.waived, 1);
});

test('898 WI-1 a docs-only range with no RED trailers is skipped; product code without trailers is refused', t => {
  const f = repo(t);
  f.write('docs/a.md', 'changed\n'); f.commit('docs');
  const r = f.evaluate();
  assert.equal(r.verdict, 'skipped');
  assert.match(sep.summaryLine(r), /^tdd-separation=skipped \(/);
  f.write('App/Foo.swift', 'struct Foo { let x = 1 }\n'); const c = f.commit('code');
  const s = f.evaluate();
  assert.equal(s.verdict, 'refused');
  assert.deepEqual(s.outside.map(x => x.commit), [c]);
});

test('898 WI-1 gate CLI: report-only prints the line, writes the JSON and exits 0 even when refused', t => {
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  const out = path.join(f.home, 'sep.json');
  const r = run('node', [lane, 'gate', '--worktree', f.dir, '--base', f.base, '--head', f.head(), '--out', out, '--archive', f.archive, '--waivers', f.waivers], f.dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout.trim(), /^tdd-separation=refused mode=report-only receipts=1 held=0 refused=1 unknown=0 waived=0 exceptions=0/);
  const saved = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(saved.verdict, 'refused'); assert.equal(saved.head, f.head()); assert.equal(saved.base, f.base);
  assert.equal(sep.gateExitCode(saved, 'report-only'), 0);
  assert.equal(sep.gateExitCode(saved, 'mandatory'), 1);
  assert.equal(sep.gateExitCode({ ...saved, verdict: 'unknown' }, 'mandatory'), 1);
  assert.equal(sep.gateExitCode({ ...saved, verdict: 'pass' }, 'mandatory'), 0);
  assert.equal(sep.gateExitCode({ ...saved, verdict: 'skipped' }, 'mandatory'), 0);
});

// fix1 WI-3 (gpt F2, opus M6): the mandatory exit honours the selection; --mandatory flips the mode for one run (upgrade only).
test('898 fix1 WI-3 mandatory mode exits 1 only when the diff needs the lane: tooling-only refusals exit 0', t => {
  const gate = (f, extra = []) => run('node', [lane, 'gate', '--worktree', f.dir, '--base', f.base, '--head', f.head(), '--archive', f.archive, '--waivers', f.waivers, ...extra], f.dir);
  const tooling = repo(t);
  tooling.write('scripts/x.mjs', 'export const x = 1;\n'); tooling.commit('tooling without a RED');
  const tr = gate(tooling, ['--mandatory']);
  assert.match(tr.stdout, /^tdd-separation=refused mode=mandatory .*required=no/);
  assert.equal(tr.status, 0, 'a tooling-only refusal does not fail the mandatory gate');
  const product = repo(t); compliant(product, ['App/Foo.swift']);
  const pr = gate(product, ['--mandatory']);
  assert.match(pr.stdout, /^tdd-separation=refused mode=mandatory .*required=yes/);
  assert.equal(pr.status, 1);
  assert.equal(gate(product).status, 0, 'report-only still exits 0');
  const r = { verdict: 'refused' };
  assert.equal(sep.gateExitCode(r, 'mandatory', false), 0);
  assert.equal(sep.gateExitCode(r, 'mandatory', true), 1);
  assert.equal(sep.gateExitCode({ verdict: 'error' }, 'mandatory', false), 1, 'an error is never exempt');
  assert.match(gate(product, ['--mode', 'report-only']).stdout, /^tdd-separation=error \(unknown option --mode\)/, 'no option downgrades the mode');
});

test('898 WI-1 gate CLI: a broken invocation prints an error line instead of a verdict', t => {
  const f = repo(t);
  const r = run('node', [lane, 'gate', '--worktree', f.dir, '--base', 'nope', '--head', f.head(), '--archive', f.archive, '--waivers', f.waivers], f.dir);
  assert.equal(r.status, 0, 'report-only never fails the run');
  assert.match(r.stdout.trim(), /^tdd-separation=error \(.+\) mode=report-only$/);
});

// WI-2: history changes and replay.
test('898 WI-2 after a rebase the old range is evaluated and carried over only when every commit maps', t => {
  const f = repo(t); compliant(f);
  const oldBase = f.base, oldHead = f.head();
  f.git('switch', '-q', 'main'); f.write('docs/b.md', 'main moved\n'); f.git('add', '-A'); f.git('commit', '-qm', 'main moves');
  const newBase = f.git('rev-parse', 'HEAD');
  f.git('switch', '-q', 'topic'); f.git('rebase', '-q', 'main');
  const plain = f.evaluate({ base: newBase });
  assert.equal(plain.verdict, 'unknown');
  assert.match(plain.receipts[0].problems.join(' '), /not in this history|rebased/);
  const carried = f.evaluate({ base: newBase, rebasedFrom: { base: oldBase, head: oldHead } });
  assert.equal(carried.verdict, 'pass', JSON.stringify(carried));
  assert.equal(carried.carriedFrom, oldHead);
  assert.equal(carried.head, f.head());
  // A changed implementation commit does not map: no carry-over.
  f.write('App/Foo.swift', 'struct Foo { func bar() -> Int { 2 } }\n'); f.git('add', '-A'); f.git('commit', '-q', '--amend', '--no-edit');
  const changed = f.evaluate({ base: newBase, rebasedFrom: { base: oldBase, head: oldHead } });
  assert.equal(changed.verdict, 'unknown');
  assert.match(changed.reason ?? '', /map/);
});

// fix1 WI-5 (gpt F5, opus M5): carry only a byte-identical replay of every commit; a merge of main counts only its own changes.
test('898 fix1 WI-5 a whitespace-only change during the rebase is not carried (patch-id ignores whitespace, the tree does not)', t => {
  const f = repo(t); compliant(f);
  const oldBase = f.base, oldHead = f.head();
  f.git('switch', '-q', 'main'); f.write('docs/b.md', 'main moved\n'); f.git('add', 'docs/b.md'); f.git('commit', '-qm', 'main moves');
  const newBase = f.git('rev-parse', 'HEAD');
  f.git('switch', '-q', 'topic'); f.git('rebase', '-q', 'main');
  assert.equal(f.evaluate({ base: newBase, rebasedFrom: { base: oldBase, head: oldHead } }).verdict, 'pass');
  f.write('App/Foo.swift', 'struct Foo {  func bar() -> Int { 1 } }\n'); f.git('add', 'App/Foo.swift'); f.git('commit', '-q', '--amend', '--no-edit');
  const changed = f.evaluate({ base: newBase, rebasedFrom: { base: oldBase, head: oldHead } });
  assert.equal(changed.verdict, 'unknown', JSON.stringify(changed));
  assert.match(changed.reason ?? '', /tree|map/);
});

test('898 fix1 WI-5 merging main into the branch does not attribute main\'s changes to the branch; an evil merge does count', t => {
  const f = repo(t); compliant(f);
  f.git('switch', '-q', 'main'); f.write('App/Bar.swift', 'struct Bar {}\n'); f.git('add', 'App/Bar.swift'); f.git('commit', '-qm', 'main adds Bar');
  const mainTip = f.git('rev-parse', 'HEAD');
  f.git('switch', '-q', 'topic'); f.git('merge', '-q', '--no-edit', 'main');
  const merged = f.evaluate({ base: mainTip });
  assert.equal(merged.verdict, 'pass', JSON.stringify(merged));
  assert.deepEqual(merged.outside, []);
  f.write('App/Baz.swift', 'struct Baz {}\n'); f.git('add', 'App/Baz.swift'); f.git('commit', '-q', '--amend', '--no-edit');
  const evil = f.evaluate({ base: mainTip });
  assert.equal(evil.verdict, 'refused', JSON.stringify(evil));
  assert.deepEqual(evil.outside.map(o => o.paths), [['App/Baz.swift']]);
});

function nodeRepo(t, fixedAtRed) {
  const f = repo(t);
  f.write('lib.mjs', `export const add = (a, b) => a ${fixedAtRed ? '+' : '-'} b;\n`);
  const red = f.commit('stub or old code', ['Stub-For: B1']);
  f.receipts([{ ...receipt('B1', red), lane: 'node', test_files: { 'lib.test.mjs': { state: 'ok', lines: [] } } }]);
  f.write('lib.mjs', 'export const add = (a, b) => a + b;\n');
  f.write('lib.test.mjs', "import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport { add } from './lib.mjs';\ntest('adds', () => assert.equal(add(2, 2), 4));\n");
  f.commit('fix', [trailer('B1')]);
  return f;
}

test('898 WI-2 replay: tests from HEAD fail by assertion on the production tree at head_sha and pass at HEAD', t => {
  const f = nodeRepo(t, false);
  const r = sep.replay({ worktree: f.dir, head: f.head(), receiptId: 'B1', kind: 'node', filter: 'adds', archiveDir: f.archive });
  assert.equal(r.verdict, 'discriminates', JSON.stringify(r));
  assert.equal(r.red.exitCode, 1); assert.equal(r.green.exitCode, 0);
  assert.ok(r.red.failed > 0 && r.green.tests > 0);
  assert.match(r.red.command, /--test-name-pattern/);
  assert.equal(run('git', ['worktree', 'list', '--porcelain'], f.dir).stdout.split('\nworktree ').length, 1, 'replay worktrees are removed');
});

test('898 WI-2 replay: an implementation already present at head_sha gives no RED', t => {
  const f = nodeRepo(t, true);
  const r = sep.replay({ worktree: f.dir, head: f.head(), receiptId: 'B1', kind: 'node', filter: 'adds', archiveDir: f.archive });
  assert.equal(r.verdict, 'no-red', JSON.stringify(r));
});

test('898 WI-2 replay: zero selected tests is rejected, not a RED', t => {
  const f = nodeRepo(t, false);
  const r = sep.replay({ worktree: f.dir, head: f.head(), receiptId: 'B1', kind: 'node', filter: 'no-such-test', archiveDir: f.archive });
  assert.equal(r.verdict, 'rejected', JSON.stringify(r));
});

// fix1 WI-4 (gpt F3/F4, opus M4, gpt M3): replay RED must fail by assertion; no write through a symlink; required replays.
function nodeFixture(t, { redLib, subject = 'feat(x): add', test: body = "test('adds', () => assert.equal(add(2, 2), 4));" }) {
  const f = repo(t);
  f.write('lib.mjs', redLib);
  const red = f.commit('stub', ['Stub-For: B1']);
  f.receipts([{ ...receipt('B1', red), lane: 'node', test_files: { 'lib.test.mjs': { state: 'ok', lines: [] } } }]);
  f.write('lib.mjs', 'export const add = (a, b) => a + b;\n');
  f.write('lib.test.mjs', `import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport { add } from './lib.mjs';\n${body}\n`);
  f.commit(subject, [trailer('B1')]);
  return f;
}
const replayOf = (f, extra = {}) => sep.replay({ worktree: f.dir, head: f.head(), receiptId: 'B1', kind: 'node', filter: 'adds', archiveDir: f.archive, ...extra });

test('898 fix1 WI-4 replay: a test file that fails to import at head_sha (missing export) is not a RED', t => {
  const f = nodeFixture(t, { redLib: 'export const other = 1;\n' });
  const r = replayOf(f);
  assert.equal(r.verdict, 'rejected', JSON.stringify(r));
  assert.match(r.reason ?? '', /assertion/);
  assert.equal(r.red.assertion, false);
});

test('898 fix1 WI-4 replay: a throwing stub (no assertion failure) is not a RED; an assertion failure is', t => {
  const thrown = nodeFixture(t, { redLib: "export const add = () => { throw new Error('not implemented'); };\n" });
  assert.equal(replayOf(thrown).verdict, 'rejected');
  const ok = nodeFixture(t, { redLib: 'export const add = (a, b) => a - b;\n' });
  const r = replayOf(ok);
  assert.equal(r.verdict, 'discriminates', JSON.stringify(r));
  assert.equal(r.red.assertion, true);
});

test('898 fix1 WI-4 replay: a tracked symlink at a test path in the head_sha tree is refused and nothing outside is written', t => {
  const f = repo(t);
  const outside = path.join(f.home, 'victim.txt'); fs.writeFileSync(outside, 'keep\n');
  f.write('lib.mjs', 'export const add = (a, b) => a - b;\n');
  fs.symlinkSync(outside, path.join(f.dir, 'lib.test.mjs'));
  f.git('add', 'lib.mjs', 'lib.test.mjs');
  const red = f.commit('stub', ['Stub-For: B1']);
  f.receipts([{ ...receipt('B1', red), lane: 'node', test_files: { 'lib.test.mjs': { state: 'ok', lines: [] } } }]);
  fs.rmSync(path.join(f.dir, 'lib.test.mjs'));
  f.write('lib.mjs', 'export const add = (a, b) => a + b;\n');
  f.write('lib.test.mjs', "import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport { add } from './lib.mjs';\ntest('adds', () => assert.equal(add(2, 2), 4));\n");
  f.git('add', 'lib.mjs', 'lib.test.mjs');
  f.commit('impl', [trailer('B1')]);
  const r = replayOf(f);
  assert.equal(r.verdict, 'rejected', JSON.stringify(r));
  assert.match(r.reason ?? '', /symlink/);
  assert.equal(fs.readFileSync(outside, 'utf8'), 'keep\n');
});

test('898 fix1 WI-4 replay removes only its own worktrees: an unrelated stale registration is not pruned', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a - b;\n' });
  const stale = path.join(f.home, 'stale-wt');
  f.git('worktree', 'add', '--detach', '--quiet', stale, 'HEAD');
  fs.rmSync(stale, { recursive: true, force: true });
  const r = replayOf(f);
  assert.equal(r.verdict, 'discriminates', JSON.stringify(r));
  assert.deepEqual(r.cleanupProblems ?? [], []);
  const list = run('git', ['worktree', 'list', '--porcelain'], f.dir).stdout;
  assert.ok(list.includes(fs.realpathSync(f.home) + '/stale-wt') || list.includes(stale), list);
  assert.doesNotMatch(list, /tdd-replay-/);
});

test('898 fix1 WI-4 a bug-fix receipt needs a bound replay: unknown without one, pass with a discriminating one', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a - b;\n', subject: 'fix(x): add adds' });
  const before = f.evaluate();
  assert.equal(before.verdict, 'unknown', JSON.stringify(before));
  assert.match(before.receipts[0].problems.join(' '), /replay required/);
  assert.deepEqual(before.replayNeeded, ['B1']);
  const out = path.join(f.dir, '.build/mado-verify/replay/B1.json');
  const cli = run('node', [lane, 'replay', '--worktree', f.dir, '--head', f.head(), '--receipt', 'B1', '--kind', 'node', '--filter', 'adds', '--archive', f.archive, '--out', out], f.dir);
  assert.equal(cli.status, 0, cli.stdout + cli.stderr);
  // fix2 WI-1: the replay prints the token that binds its file; the file binds only when the invocation accepts it.
  const token = `B1@${fileDigest(out)}`;
  assert.match(cli.stderr, new RegExp(`--accept-replay ${token}`));
  assert.equal(f.evaluate().verdict, 'unknown');
  const after = f.evaluate({ acceptedReplays: [token] });
  assert.equal(after.verdict, 'pass', JSON.stringify(after));
  assert.equal(after.receipts[0].replay?.verdict, 'discriminates');
  // A replay result for another head does not bind.
  f.write('docs/a.md', 'moved\n'); f.commit('docs');
  assert.equal(f.evaluate({ acceptedReplays: [token] }).verdict, 'unknown');
});

test('898 fix1 WI-4 a stub-only window is refused when its replay shows no RED; a waived receipt without a replay is not pass', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a + b;\n', test: "test('adds', () => assert.equal(add(2, 2), 4));" });
  assert.equal(f.evaluate().receipts[0].flag, 'stub-only-window');
  const r = replayOf(f, { out: path.join(f.dir, '.build/mado-verify/replay/B1.json') });
  assert.equal(r.verdict, 'no-red');
  assert.equal(f.evaluate().verdict, 'unknown'); // fix2 WI-1: not accepted, so it does not bind
  const e = f.evaluate({ acceptedReplays: [`B1@${fileDigest(path.join(f.dir, '.build/mado-verify/replay/B1.json'))}`] });
  assert.equal(e.verdict, 'refused', JSON.stringify(e));
  assert.match(e.receipts[0].problems.join(' '), /no-red/);
  const w = repo(t); compliant(w, ['App/Foo.swift']);
  waiver(w, goodWaiver);
  const waived = w.evaluate({ acceptedWaivers: accept(w) });
  assert.equal(waived.receipts[0].status, 'waived');
  assert.equal(waived.verdict, 'unknown', JSON.stringify(waived));
});

// fix2 WI-1 (opus N1, gpt F3): a replay file is a claim; it binds only when the invocation names it by file digest
// (--accept-replay <receipt>@<sha256>), and accepted results for one receipt that disagree are refused.
const replayDir = f => path.join(f.dir, '.build/mado-verify/replay');
const forge = (f, name, verdict = 'discriminates') => {
  const red = JSON.parse(fs.readFileSync(path.join(f.dir, '.claude/tdd-guardian/receipts.json'), 'utf8')).receipts[0].head_sha;
  const file = path.join(replayDir(f), name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ receipt: 'B1', headSha: red, head: f.head(), verdict, red: { assertion: verdict !== 'no-red' } }));
  return file;
};

test('898 fix2 WI-1 a hand-written replay file nobody accepted does not bind: unknown, CLAIMED-REPLAY with its digest', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a - b;\n', subject: 'fix(x): add adds' });
  const file = forge(f, '0.json');
  const r = f.evaluate();
  assert.equal(r.verdict, 'unknown', JSON.stringify(r));
  assert.equal(r.receipts[0].replay, undefined);
  assert.deepEqual(r.replayNeeded, ['B1']);
  assert.deepEqual(r.replayClaims.map(c => [c.receipt, c.file, c.digest, c.accepted]), [['B1', '0.json', fileDigest(file), false]]);
  assert.match(sep.summaryLine(r), new RegExp(`CLAIMED-REPLAY B1@${fileDigest(file).slice(0, 12)}`));
  assert.doesNotMatch(sep.summaryLine(r), / REPLAY B1@/);
});

test('898 fix2 WI-1 an accepted replay digest binds and the line names its file; a file changed after acceptance does not bind', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a - b;\n', subject: 'fix(x): add adds' });
  const out = path.join(replayDir(f), 'B1.json');
  assert.equal(replayOf(f, { out }).verdict, 'discriminates');
  const token = `B1@${fileDigest(out).slice(0, 16)}`;
  const r = f.evaluate({ acceptedReplays: [token] });
  assert.equal(r.verdict, 'pass', JSON.stringify(r));
  assert.deepEqual([r.receipts[0].replay.file, r.receipts[0].replay.digest], ['B1.json', fileDigest(out)]);
  assert.match(sep.summaryLine(r), new RegExp(`REPLAY B1@${fileDigest(out).slice(0, 12)}=discriminates:B1\\.json`));
  assert.doesNotMatch(sep.summaryLine(r), /CLAIMED-REPLAY/);
  fs.writeFileSync(out, fs.readFileSync(out, 'utf8').replace('"tests"', '"tests" '));
  const changed = f.evaluate({ acceptedReplays: [token] });
  assert.equal(changed.verdict, 'unknown', JSON.stringify(changed));
  assert.match(changed.acceptProblems.join(' '), /accepted replay B1@/);
  assert.equal(f.evaluate({ acceptedReplays: ['B1@zz'] }).acceptProblems.length, 1);
});

test('898 fix2 WI-1 two accepted replay results for one receipt that disagree are refused', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a - b;\n', subject: 'fix(x): add adds' });
  const good = forge(f, 'a.json'), bad = forge(f, 'b.json', 'no-red');
  const r = f.evaluate({ acceptedReplays: [`B1@${fileDigest(good)}`, `B1@${fileDigest(bad)}`] });
  assert.equal(r.verdict, 'refused', JSON.stringify(r));
  assert.match(r.receipts[0].problems.join(' '), /accepted replays disagree.*a\.json.*b\.json/);
  // Two accepted results that agree bind.
  const twin = forge(f, 'c.json');
  assert.equal(f.evaluate({ acceptedReplays: [`B1@${fileDigest(good)}`, `B1@${fileDigest(twin)}`] }).verdict, 'pass');
});

test('898 fix2 WI-1 opus S3-forged: implementation in the stub, forged 0.json beside the honest no-red rerun ends refused or unknown, never pass', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a + b;\n' });
  assert.equal(f.evaluate().receipts[0].flag, 'stub-only-window');
  forge(f, '0.json');
  const honest = path.join(replayDir(f), 'R1.json');
  assert.equal(replayOf(f, { out: honest }).verdict, 'no-red');
  const none = f.evaluate();
  assert.equal(none.verdict, 'unknown', JSON.stringify(none));
  const delegator = f.evaluate({ acceptedReplays: [`B1@${fileDigest(honest)}`] });
  assert.equal(delegator.verdict, 'refused', JSON.stringify(delegator));
  assert.equal(delegator.receipts[0].replay.file, 'R1.json');
  assert.match(sep.summaryLine(delegator), /CLAIMED-REPLAY B1@/);
  const both = f.evaluate({ acceptedReplays: [`B1@${fileDigest(honest)}`, `B1@${fileDigest(path.join(replayDir(f), '0.json'))}`] });
  assert.equal(both.verdict, 'refused', JSON.stringify(both));
});

test('898 fix2 WI-1 evidence check takes --accept-replay; the implementer-stored result (no acceptance) still matches', t => {
  const f = nodeFixture(t, { redLib: 'export const add = (a, b) => a - b;\n', subject: 'fix(x): add adds' });
  const out = path.join(replayDir(f), 'B1.json');
  replayOf(f, { out });
  recordFor(f, { tddSeparation: f.evaluate() });
  const plain = check(f);
  assert.match(plain.stdout, /WARNING tdd-separation \(report-only\): verdict unknown/);
  assert.doesNotMatch(plain.stdout, /differs/);
  const accepted = run('node', [evidence, 'check', '--head', f.head(), '--issue', '1', '--accept-replay', `B1@${fileDigest(out)}`], f.dir, { ...process.env, HOME: f.home });
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.doesNotMatch(accepted.stdout, /WARNING tdd-separation/);
});

// fix2 WI-3 (opus L-new-2): ERR_ASSERTION counts only at the failing leaf's own level, not inside a nested cause block.
test('898 fix2 WI-3 a leaf whose ERR_ASSERTION appears only in a nested cause is not a RED by assertion', () => {
  assert.equal(typeof sep.redByAssertion, 'function', 'redByAssertion(tap) is exported');
  const nested = ['TAP version 13', 'not ok 1 - adds', '  ---', '  duration_ms: 1', "  failureType: 'testCodeFailure'", "  error: 'wrapped'",
    "  code: 'ERR_TEST_FAILURE'", '  cause:', "    code: 'ERR_ASSERTION'", '  ...', '1..1', ''].join('\n');
  assert.equal(sep.redByAssertion(nested), false);
  const subtest = ['TAP version 13', '    not ok 1 - inner', '      ---', "      failureType: 'testCodeFailure'", "      code: 'ERR_ASSERTION'", '      ...',
    'not ok 1 - outer', '  ---', "  failureType: 'subtestsFailed'", '  ...', '1..1', ''].join('\n');
  assert.equal(sep.redByAssertion(subtest), true);
  assert.equal(sep.redByAssertion(['not ok 1 - a', '  ---', "  code: 'ERR_ASSERTION'", '  ...', 'not ok 2 - b', '  ---', "  code: 'ERR_TEST_FAILURE'", '  ...', ''].join('\n')), false);
  assert.equal(sep.redByAssertion('ok 1 - a\n'), false);
});

// WI-3: gate policy and evidence wiring.
test('898 WI-3 selection: product code needs the lane; tests, docs and tooling do not', () => {
  assert.equal(policy.tddSeparationRequired(['App/X.swift']), true);
  assert.equal(policy.tddSeparationRequired(['docs/a.md', 'Packages/MadoKit/Sources/MadoCore/A.swift']), true);
  assert.equal(policy.tddSeparationRequired(['project.yml']), true);
  assert.equal(policy.tddSeparationRequired(['docs/a.md', 'scripts/x.mjs', '.agents/skills/a/SKILL.md']), false);
  assert.equal(policy.tddSeparationRequired(['Packages/MadoKit/Tests/CoreTests/FooTests.swift', 'App/README.md']), false);
  assert.equal(policy.tddSeparationRequired([]), false);
  assert.equal(policy.TDD_SEPARATION_MODE, 'report-only');
});

test('898 WI-3 findings: mandatory refuses, report-only warns, tooling without a result is fine', () => {
  const pass = { lane: 'tdd-separation', verdict: 'pass', counts: { receipts: 1, held: 1, refused: 0, unknown: 0, waived: 0, exceptions: 0 } };
  const refused = { ...pass, verdict: 'refused', counts: { ...pass.counts, held: 0, refused: 1 } };
  const f = (o) => policy.tddSeparationFindings(o);
  assert.deepEqual(f({ stored: pass, recomputed: pass, required: true, mode: 'mandatory' }), { problems: [], warnings: [] });
  assert.equal(f({ stored: undefined, recomputed: pass, required: false, mode: 'mandatory' }).problems.length, 0);
  for (const [o, re] of [[{ stored: undefined, recomputed: pass, required: true }, /missing/], [{ stored: refused, recomputed: refused, required: true }, /refused/],
    [{ stored: pass, recomputed: refused, required: true }, /differs/], [{ stored: { verdict: 'pass' }, recomputed: pass, required: true }, /malformed|differs/]]) {
    const m = f({ ...o, mode: 'mandatory' }), r = f({ ...o, mode: 'report-only' });
    assert.match(m.problems.join(' '), re); assert.equal(m.warnings.length, 0);
    assert.equal(r.problems.length, 0); assert.match(r.warnings.join(' '), re);
  }
});

const mandatoryNames = ['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'apptests', 'node', 'ledger', 'design'];
function recordFor(f, data) {
  const source = path.join(f.home, 'input.json');
  fs.writeFileSync(source, JSON.stringify({ issue: 1, task: 'i1', branch: 'topic', head: f.head(), integrity: 'none', byType: [], notVerified: ['none'],
    commentUrl: 'https://github.com/anzchy/mado/issues/1#issuecomment-9', gates: mandatoryNames.map(name => ({ name, command: name, exitCode: 0 })), ...data }));
  const env = { ...process.env, HOME: f.home };
  return { record: run('node', [evidence, 'record', source], f.dir, env), render: run('node', [evidence, 'render', source], f.dir, env) };
}
const check = f => run('node', [evidence, 'check', '--head', f.head(), '--issue', '1'], f.dir, { ...process.env, HOME: f.home });

test('898 WI-3 evidence: record stores the lane result, render shows it, check recomputes it', t => {
  const f = repo(t); compliant(f);
  const result = f.evaluate();
  const { record, render } = recordFor(f, { tddSeparation: result });
  assert.equal(record.status, 0, record.stderr);
  assert.match(render.stdout, /tdd-separation=pass mode=report-only/);
  const saved = JSON.parse(fs.readFileSync(path.join(f.dir, '.build/mado-verify', `${f.head()}.json`), 'utf8'));
  assert.equal(saved.tddSeparation.verdict, 'pass');
  const ok = check(f);
  assert.equal(ok.status, 0, ok.stderr);
  assert.doesNotMatch(ok.stdout, /WARNING tdd-separation/);
});

test('898 WI-3 evidence: report-only check warns on a product record without the lane result or with a refusal', t => {
  const f = repo(t); compliant(f, ['App/Foo.swift']);
  recordFor(f, {});
  const missing = check(f);
  assert.equal(missing.status, 0, missing.stderr);
  assert.match(missing.stdout, /WARNING tdd-separation \(report-only\): .*missing/);
  const refused = f.evaluate();
  recordFor(f, { tddSeparation: refused });
  const r = check(f);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /WARNING tdd-separation \(report-only\): .*refused/);
  // A stored result that differs from the recomputation is reported too.
  recordFor(f, { tddSeparation: { ...refused, verdict: 'pass', counts: { ...refused.counts, held: 1, refused: 0 } } });
  assert.match(check(f).stdout, /WARNING tdd-separation \(report-only\): .*differs/);
});

test('898 WI-3 evidence: a tooling-only record needs no lane result and gets no warning', t => {
  const f = repo(t);
  f.write('scripts/x.mjs', 'export {}\n'); f.commit('tooling');
  recordFor(f, {});
  const r = check(f);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stdout, /WARNING tdd-separation/);
});
