import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, unlinkSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkGates, checkUIParity } from './ui-parity-pr-body-lint.mjs';

const uiFiles = ['App/UI/InspectorPlaceholder.swift', 'App/Commands/CommandMenu.swift', 'Packages/PicseeKit/Sources/PicseeMacUI/States/ViewerStateHost.swift'];
const table = '## UI-Parity\n\n| State | Design | Assertion | Status |\n|---|---|---|---|\n| Empty | abc | test | AUTO-PASS |\n';
const head = '3de39c6012345678901234567890123456789012';
const oldHead = 'a'.repeat(40);
const codeSame = 'b'.repeat(40);
const gatesTable = rows => `## Gates\n\n| Lane | Status | SHA | Source |\n|---|---|---|---|\n${rows.join('\n')}\n`;
const completeGates = (currentHead = head) => {
  const sha = currentHead.slice(0, 8);
  return gatesTable([
    `| package-tests | PASS | ${sha} | owner-gates swift=0 |`,
    `| package-coverage | PASS | ${sha} | owner-gates lcov=0 |`,
    `| app-tests | PASS | ${sha} | CI App tests |`,
    `| unsigned-build | PASS | ${sha} | CI Walking skeleton |`,
    `| node-tooling | PASS | ${sha} | owner-gates node=0 |`,
    `| ledger | PASS | ${sha} | owner-gates ledger=0 |`,
    `| diff-check | PASS | ${sha} | owner-gates diffcheck=0 |`,
    `| design-check | PASS | ${sha} | owner-gates design=0 |`,
    '| audit | N/A | — | tooling-only change |',
    '| device-smoke | N/A | — | no user-visible change |',
  ]);
};

test('PR template Gates rows satisfy checkGates and follow the emitted lane order', () => {
  const template = readFileSync(new URL('../../.agents/skills/pr/SKILL.md', import.meta.url), 'utf8');
  const gates = template.match(/## Gates\n([\s\S]*?)\nDevice-Smoke:/)?.[1];
  assert.ok(gates, 'missing template Gates table');
  const body = `## Gates\n${gates}`.replaceAll('<head-sha>', head);
  assert.deepEqual(checkGates(body, head), { ok: true });
  const lanes = text => [...text.matchAll(/^\| ([a-z-]+) \|/gm)].map(match => match[1]);
  assert.deepEqual(lanes(body), lanes(completeGates()));
});

test('UI parity contract lists every fixed Gates lane', () => {
  const contract = readFileSync(new URL('../../docs/agents/ui-parity-contract.md', import.meta.url), 'utf8');
  const fixed = contract.match(/固定 lanes 为 (.*?)，各出现一次/)?.[1];
  assert.ok(fixed, 'missing fixed lane list');
  const lanes = [...completeGates().matchAll(/^\| ([a-z-]+) \|/gm)].map(match => match[1]);
  assert.deepEqual([...fixed.matchAll(/`([^`]+)`/g)].map(match => match[1]), lanes);
});

function assertGatesRejectedByAPIAndCLI(t, fixture, reason) {
  const direct = checkGates(fixture(head), head);
  const repo = mkdtempSync(join(tmpdir(), 'picsee-gates-layout-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' });
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'test@example.invalid');
  git('config', 'user.name', 'Test');
  mkdirSync(join(repo, 'scripts'), { recursive: true });
  writeFileSync(join(repo, 'scripts/check.py'), 'print("base")\n');
  git('add', 'scripts/check.py');
  git('commit', '-qm', 'base');
  git('branch', 'base');
  writeFileSync(join(repo, 'scripts/check.py'), 'print("head")\n');
  git('add', 'scripts/check.py');
  git('commit', '-qm', 'head');
  const body = join(repo, 'body.md');
  writeFileSync(body, fixture(git('rev-parse', 'HEAD').trim()));
  const script = fileURLToPath(new URL('./ui-parity-pr-body-lint.mjs', import.meta.url));
  const cli = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body], { cwd: repo, encoding: 'utf8' });
  assert.equal(direct.ok, false, 'checkGates accepted contradictory evidence');
  assert.match(direct.reason, reason);
  assert.equal(cli.status, 1, cli.stdout + cli.stderr);
  assert.match(cli.stderr, reason);
}

function assertGatesAcceptedByAPIAndCLI(t, fixture) {
  const direct = checkGates(fixture(head), head);
  const repo = mkdtempSync(join(tmpdir(), 'picsee-gates-layout-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' });
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'test@example.invalid');
  git('config', 'user.name', 'Test');
  mkdirSync(join(repo, 'scripts'), { recursive: true });
  writeFileSync(join(repo, 'scripts/check.py'), 'print("base")\n');
  git('add', 'scripts/check.py');
  git('commit', '-qm', 'base');
  git('branch', 'base');
  writeFileSync(join(repo, 'scripts/check.py'), 'print("head")\n');
  git('add', 'scripts/check.py');
  git('commit', '-qm', 'head');
  const body = join(repo, 'body.md');
  writeFileSync(body, fixture(git('rev-parse', 'HEAD').trim()));
  const script = fileURLToPath(new URL('./ui-parity-pr-body-lint.mjs', import.meta.url));
  const cli = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body], { cwd: repo, encoding: 'utf8' });
  assert.equal(direct.ok, true, direct.reason);
  assert.equal(cli.status, 0, cli.stdout + cli.stderr);
  assert.match(cli.stdout, /UI-Parity PR body: PASS/);
}

test('Gates rejects a second Gates section through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    + `\n## Gates\n\n| Lane | Status | SHA | Source |\n|---|---|---|---|\n| package-tests | FAIL | ${currentHead} | failed rerun |\n`,
  /duplicate ## Gates section/);
});

test('Gates rejects a Gates rerun heading through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    + `\n## Gates rerun\n\n| package-tests | FAIL | ${currentHead} | failed rerun |\n`,
  /ambiguous Gates heading: ## Gates rerun/);
});

test('Gates rejects a level-three Gates heading through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    + `\n### Gates\n\n| package-tests | FAIL | ${currentHead} | failed rerun |\n`,
  /ambiguous Gates heading: ### Gates/);
});

test('Gates rejects a lowercase gates heading through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead).replace('## Gates', '## gates'),
    /ambiguous Gates heading: ## gates/);
});

test('Gates rejects a setext Gates section after Summary through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    + `\n## Summary\n\nGates\n---\n\n| package-tests | FAIL | ${currentHead} | failed rerun |\n`,
  /ambiguous Gates heading: Gates/);
});

test('Gates rejects an equals-underlined setext Gates section through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    + `\n## Summary\n\nGates\n===\n\n| package-tests | FAIL | ${currentHead} | failed rerun |\n`,
  /ambiguous Gates heading: Gates/);
});

test('Gates accepts an ordinary setext section after the table through API and CLI', t => {
  assertGatesAcceptedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    + '\nSummary\n---\n\nTooling-only change.\n');
});

test('Gates does not mistake its table separator for a setext underline through API and CLI', t => {
  assertGatesAcceptedByAPIAndCLI(t, currentHead => completeGates(currentHead));
});

test('Gates rejects a prose-separated FAIL row through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    + `Rerun results:\n\n| package-tests | FAIL | ${currentHead} | failed rerun |\n`,
  /unconsumed Gates row/);
});

test('Gates rejects a complete table only inside a fence through API and CLI', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => `\`\`\`markdown\n${completeGates(currentHead)}\`\`\`\n`, /missing ## Gates table/);
});

test('Gates rejects lowercase code same as stale-head evidence', () => {
  const stale = completeGates().replace(`| package-tests | PASS | ${head.slice(0, 8)} |`, `| package-tests | PASS | ${oldHead} |`);
  const result = checkGates(stale.replace('owner-gates swift=0', `owner-gates swift=0; code same ${codeSame}`), head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /stale head/);
});

test('Gates accepts a complete table', () => {
  assert.equal(checkGates(completeGates(), head).ok, true);
});

test('Gates rejects a missing table', () => {
  const result = checkGates('## Summary\n\nNo gate evidence.\n', head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /missing ## Gates table/);
});

test('Gates rejects a missing app-tests lane', () => {
  const body = completeGates().split('\n').filter(line => !line.startsWith('| app-tests |')).join('\n');
  const result = checkGates(body, head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /missing app-tests/);
});

test('Gates requires design-check even in a legacy body', t => {
  assertGatesRejectedByAPIAndCLI(t, currentHead => completeGates(currentHead)
    .split('\n').filter(line => !line.startsWith('| design-check |')).join('\n'),
  /missing design-check lane/);
});

test('Gates rejects a duplicate lane', () => {
  const result = checkGates(completeGates() + '| ledger | N/A | — | duplicate |\n', head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /duplicate ledger/);
});

test('Gates rejects an invalid status', () => {
  const result = checkGates(completeGates().replace('| package-tests | PASS |', '| package-tests | UNKNOWN |'), head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /invalid status/);
});

test('Gates rejects PASS without a SHA', () => {
  const result = checkGates(completeGates().replace(`| package-tests | PASS | ${head.slice(0, 8)} |`, '| package-tests | PASS | — |'), head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /package-tests.*SHA/);
});

test('Gates rejects N/A without a reason', () => {
  const result = checkGates(completeGates().replace('| audit | N/A | — | tooling-only change |', '| audit | N/A | — | — |'), head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /audit.*reason/);
});

test('Gates rejects stale-head PASS without CODE same and accepts exact rebase evidence', () => {
  const stale = completeGates().replace(`| package-tests | PASS | ${head.slice(0, 8)} |`, `| package-tests | PASS | ${oldHead} |`);
  const rejected = checkGates(stale, head);
  assert.equal(rejected.ok, false);
  assert.match(rejected.reason, /stale head/);
  assert.equal(checkGates(stale.replace('owner-gates swift=0', `owner-gates swift=0; CODE same ${codeSame}`), head).ok, true);
});

test('Gates rejects any FAIL row', () => {
  const result = checkGates(completeGates().replace('| node-tooling | PASS |', '| node-tooling | FAIL |'), head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /FAIL row/);
});

test('Gates accepts app-tests NOT RUN with a reason', () => {
  const body = completeGates().replace(`| app-tests | PASS | ${head.slice(0, 8)} | CI App tests |`, '| app-tests | NOT RUN | — | manual CI run with app_tests=false |');
  assert.equal(checkGates(body, head).ok, true);
});

test('Gates rejects Device-Smoke PASS when its row is N/A', () => {
  const body = completeGates() + `\nDevice-Smoke: PASS ${head.slice(0, 8)} run=device — changed path\n`;
  const result = checkGates(body, head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /Device-Smoke/);
});

test('Gates rejects a Device-Smoke SHA mismatch', () => {
  const body = completeGates()
    .replace('| device-smoke | N/A | — | no user-visible change |', `| device-smoke | PASS | ${head.slice(0, 8)} | device run |`)
    + `\nDevice-Smoke: PASS ${head.slice(0, 7)} run=device — changed path\n`;
  const result = checkGates(body, head);
  assert.equal(result.ok, false);
  assert.match(result.reason, /Device-Smoke.*SHA/);
});

test('Gates rejects PR 307 historical prose and accepts its fail-closed transcription', () => {
  const original = readFileSync(new URL('./fixtures/pr-307-body.md', import.meta.url), 'utf8');
  const historicalHead = '7ac5e013e7946afc4a563893e08223066375b4f1';
  const missing = checkGates(original, historicalHead);
  assert.equal(missing.ok, false);
  assert.match(missing.reason, /ambiguous Gates heading: ## Gates \(delegator,/);
  const transcribed = gatesTable([
    '| package-tests | NOT VERIFIED | 639588e7 | original reports 1319 tests on an older head; no CODE same evidence |',
    '| package-coverage | NOT VERIFIED | 639588e7 | original reports 14550/14550 lines on an older head; no CODE same evidence |',
    '| app-tests | NOT VERIFIED | 639588e7 | original reports 167 tests on an older head; no CODE same evidence |',
    '| unsigned-build | NOT VERIFIED | 639588e7 | original reports CI unsigned build on an older head; no CODE same evidence |',
    '| node-tooling | NOT VERIFIED | 639588e7 | original reports Node tests on an older head; no CODE same evidence |',
    '| ledger | NOT VERIFIED | 639588e7 | original reports ledger check on an older head; no CODE same evidence |',
    '| diff-check | NOT VERIFIED | 639588e7 | original reports diff check on an older head; no CODE same evidence |',
    '| design-check | NOT VERIFIED | 639588e7 | historical PR has no design gate evidence |',
    '| audit | NOT VERIFIED | 639588e7 | original audit confirmed an older head; no CODE same evidence |',
    '| device-smoke | NOT VERIFIED | 639588e7 | original smoke passed on an older head; no CODE same evidence |',
  ]);
  assert.equal(checkGates(transcribed, historicalHead).ok, true);
});

test('UI changes require a populated UI-Parity table', () => {
  for (const file of uiFiles) {
    assert.equal(checkUIParity('## Summary\n\nDone\n', [file]).ok, false);
    assert.equal(checkUIParity('## UI-Parity\n\nNo changes\n', [file]).ok, false);
    assert.equal(checkUIParity('## UI-Parity\n\n| State | Status |\n|---|---|\n', [file]).ok, false);
    assert.equal(checkUIParity(table, [file]).ok, true);
  }
});

test('non-App changes do not require the table', () => {
  assert.equal(checkUIParity('', ['scripts/device/device.py']).ok, true);
});

test('per-state status accepts only the contract values and rejects FAIL', () => {
  for (const status of ['AUTO-PASS', 'PENDING(P3-10)', 'NOT VERIFIED']) {
    assert.equal(checkUIParity(table.replace('AUTO-PASS', status), uiFiles).ok, true, status);
  }
  for (const status of ['FAIL', 'PASS', 'PENDING', 'UNKNOWN']) {
    assert.equal(checkUIParity(table.replace('AUTO-PASS', status), uiFiles).ok, false, status);
  }
  assert.equal(checkUIParity(table + '| Broken | abc | test | FAIL |\n', uiFiles).ok, false);
});

test('deletion-only UI diff requires a table through the CLI', t => {
  const repo = mkdtempSync(join(tmpdir(), 'picsee-ui-lint-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' });
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'test@example.invalid');
  git('config', 'user.name', 'Test');
  mkdirSync(join(repo, 'App/UI'), { recursive: true });
  const view = join(repo, 'App/UI/OldView.swift');
  writeFileSync(view, 'struct OldView {}\n');
  git('add', 'App/UI/OldView.swift');
  git('commit', '-qm', 'add view');
  git('branch', 'base');
  unlinkSync(view);
  git('add', 'App/UI/OldView.swift');
  git('commit', '-qm', 'delete view');
  const body = join(repo, 'body.md');
  writeFileSync(body, '## Summary\n\nDeleted old view.\n');
  const script = fileURLToPath(new URL('./ui-parity-pr-body-lint.mjs', import.meta.url));
  const currentGates = () => completeGates(git('rev-parse', 'HEAD').trim());
  const result = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /UI-Parity/);
  writeFileSync(body, table);
  const withoutSmoke = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(withoutSmoke.status, 1, withoutSmoke.stdout + withoutSmoke.stderr);
  assert.match(withoutSmoke.stderr, /Device-Smoke/);
  writeFileSync(body, table + '\n' + currentGates() + '\nDevice-Smoke: n/a — test only\n');
  const validExemption = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(validExemption.status, 0, validExemption.stdout + validExemption.stderr);
  for (const smoke of ['Device-Smoke: n/a —   ', 'Device-Smoke: FAIL abc1234 run=offline — broken path',
    'Device-Smoke: PASS abc1234 run=offline — path\nDevice-Smoke: FAIL abc1234 run=offline — broken path',
    'Device-Smoke: PASS abc1234 run=offline — path\nDevice-Smoke: n/a —   ']) {
    writeFileSync(body, table + '\n' + currentGates() + '\n' + smoke + '\n');
    const rejected = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body],
      { cwd: repo, encoding: 'utf8' });
    assert.equal(rejected.status, 1, smoke + rejected.stdout + rejected.stderr);
  }
  writeFileSync(body, table + '\n' + currentGates() + '\nDevice-Smoke: n/a — no user-visible behavior changed\n');
  const exempt = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(exempt.status, 0, exempt.stdout + exempt.stderr);
  const notVerifiedGates = currentGates().replace('| device-smoke | N/A | — | no user-visible change |',
    '| device-smoke | NOT VERIFIED | abc1234 | delegated device run pending |');
  writeFileSync(body, table + '\n' + notVerifiedGates + '\nDevice-Smoke: NOT VERIFIED abc1234 run=offline — delegated device run pending\n');
  const valid = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(valid.status, 0, valid.stdout + valid.stderr);
  git('branch', 'after-ui');
  mkdirSync(join(repo, 'scripts'), { recursive: true });
  writeFileSync(join(repo, 'scripts/check.py'), 'print("ok")\n');
  git('add', 'scripts/check.py');
  git('commit', '-qm', 'add non-App script');
  writeFileSync(body, currentGates() + '\nDevice-Smoke: n/a — non-App script only\n');
  const nonApp = spawnSync(process.execPath, [script, '--base', 'after-ui', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(nonApp.status, 0, nonApp.stdout + nonApp.stderr);
  writeFileSync(body, currentGates() + '\nDevice-Smoke: n/a —   \n');
  const nonAppMissingReason = spawnSync(process.execPath, [script, '--base', 'after-ui', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(nonAppMissingReason.status, 1, nonAppMissingReason.stdout + nonAppMissingReason.stderr);
});

test('rename out of App still checks the deleted App path', t => {
  const repo = mkdtempSync(join(tmpdir(), 'picsee-ui-rename-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' });
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'test@example.invalid');
  git('config', 'user.name', 'Test');
  mkdirSync(join(repo, 'App/Commands'), { recursive: true });
  writeFileSync(join(repo, 'App/Commands/Old.swift'), 'struct Old {}\n');
  git('add', 'App/Commands/Old.swift');
  git('commit', '-qm', 'base');
  git('branch', 'base');
  mkdirSync(join(repo, 'scripts'), { recursive: true });
  git('mv', 'App/Commands/Old.swift', 'scripts/Old.swift');
  git('commit', '-qm', 'move');
  const body = join(repo, 'body.md');
  writeFileSync(body, 'No table\n');
  const script = fileURLToPath(new URL('./ui-parity-pr-body-lint.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /UI-Parity/);
});

const codeGateLanes = ['package-tests', 'package-macui-tests', 'app-tests', 'unsigned-build', 'walking-skeleton'];
const staleGate = (lane, sha = oldHead, source = 'recorded run', currentHead = head) => {
  const row = `| ${lane} | PASS | ${sha} | ${source} |`;
  const body = completeGates(currentHead);
  return body.includes(`| ${lane} |`)
    ? body.replace(new RegExp(`^\\| ${lane} \\|.*$`, 'm'), row)
    : body + row + '\n';
};
const staleFailure = lane => ({ ok: false, reason: `${lane} PASS has a stale head without CODE same evidence` });
const changedPathsAdapter = changed => ({
  isAncestor: () => true,
  inputsChanged: (_sha, _head, inputs) => inputs.some(input => changed.some(file => input === '.' || file === input || file.startsWith(input))),
});

test('Gates accepts ancestor package evidence after a garden-only commit', () => {
  assert.deepEqual(checkGates(staleGate('package-tests'), head, changedPathsAdapter(['docs/feature-ledger.md'])), { ok: true });
});

test('Gates accepts every code lane after unrelated docs-only commits', () => {
  for (const lane of codeGateLanes) {
    assert.deepEqual(checkGates(staleGate(lane), head, changedPathsAdapter(['docs/notes.md'])), { ok: true }, lane);
  }
});

test('Gates rejects changed code inputs even with CODE same evidence', () => {
  for (const lane of codeGateLanes) {
    for (const source of ['recorded run', `recorded run CODE same ${codeSame}`]) {
      assert.deepEqual(checkGates(staleGate(lane, oldHead, source), head, changedPathsAdapter(['App/Changed.swift'])), source.includes('CODE same')
        ? { ok: false, reason: `${lane} PASS has a stale head: inputs changed since ${oldHead}` }
        : staleFailure(lane));
    }
  }
});

test('Gates checks ledger, design and tooling inputs separately', () => {
  for (const [lane, changed] of [['ledger', 'docs/feature-ledger.md'], ['design-check', 'design/index.html'], ['node-tooling', 'scripts/agents/new.test.mjs']]) {
    assert.deepEqual(checkGates(staleGate(lane), head, changedPathsAdapter([changed])), staleFailure(lane));
    assert.deepEqual(checkGates(staleGate(lane), head, changedPathsAdapter([])), { ok: true });
  }
  // Agent tests read repository documents and references, so their conservative input is the entire tree.
  assert.deepEqual(checkGates(staleGate('node-tooling'), head, changedPathsAdapter(['docs/notes.md'])), staleFailure('node-tooling'));
  assert.deepEqual(checkGates(staleGate('ledger'), head, changedPathsAdapter(['docs/notes.md'])), { ok: true });
});

test('Gates keeps historical CODE same policy for non-ancestor and undeclared lanes', () => {
  const nonAncestor = { isAncestor: () => false, inputsChanged: () => false };
  for (const lane of ['package-tests', 'package-coverage', 'diff-check', 'audit', 'device-smoke', 'gardener', 'unknown-lane']) {
    const adapter = ['package-tests', 'package-coverage'].includes(lane) ? nonAncestor : changedPathsAdapter([]);
    assert.deepEqual(checkGates(staleGate(lane), head, adapter), staleFailure(lane));
    assert.deepEqual(checkGates(staleGate(lane, oldHead, `CODE same ${codeSame}`), head, adapter), { ok: true });
    for (const source of [`code same ${codeSame}`, 'CODE same abc1234']) {
      assert.deepEqual(checkGates(staleGate(lane, oldHead, source), head, adapter), staleFailure(lane));
    }
  }
});

test('Gates fails closed on unknown SHA and git adapter errors', () => {
  for (const adapter of [
    { isAncestor: () => undefined, inputsChanged: () => false },
    { isAncestor: () => { throw Error('git unavailable'); }, inputsChanged: () => false },
    { isAncestor: () => true, inputsChanged: () => undefined },
    { isAncestor: () => true, inputsChanged: () => { throw Error('diff failed'); } },
  ]) {
    assert.deepEqual(checkGates(staleGate('package-tests'), head, adapter), staleFailure('package-tests'));
    assert.deepEqual(checkGates(staleGate('package-tests', oldHead, `CODE same ${codeSame}`), head, adapter), { ok: true });
  }
});

test('Gates supports 7-40 hex ancestor SHAs and stays pure without an adapter', () => {
  for (const sha of [oldHead.slice(0, 7), oldHead.slice(0, 8), oldHead, oldHead.toUpperCase()]) {
    assert.deepEqual(checkGates(staleGate('package-tests', sha), head, changedPathsAdapter([])), { ok: true });
    assert.deepEqual(checkGates(staleGate('package-tests', sha), head), staleFailure('package-tests'));
  }
  for (const sha of ['aaaaaa', 'a'.repeat(41), 'zzzzzzz']) {
    assert.match(checkGates(staleGate('package-tests', sha), head, changedPathsAdapter([])).reason, /needs a 7-40 hex SHA/);
  }
  assert.deepEqual(checkGates(completeGates(), head), { ok: true });
});

function gatesGitFixture(t) {
  const repo = mkdtempSync(join(tmpdir(), 'picsee-gates-ancestor-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'test@example.invalid');
  git('config', 'user.name', 'Test');
  const change = file => {
    const segments = file.split('/');
    if (segments.length > 1) mkdirSync(join(repo, ...segments.slice(0, -1)), { recursive: true });
    writeFileSync(join(repo, file), `changed ${file}\n`);
    git('add', file);
    git('commit', '-qm', `change ${file}`);
    return git('rev-parse', 'HEAD');
  };
  const base = change('seed.txt');
  git('branch', 'base');
  const run = (lane, sha, source = 'recorded run', cwd = repo) => {
    const body = join(repo, 'body.md');
    writeFileSync(body, table + '\n' + staleGate(lane, sha, source, git('rev-parse', 'HEAD')) + '\nDevice-Smoke: n/a — test fixture\n');
    const script = fileURLToPath(new URL('./ui-parity-pr-body-lint.mjs', import.meta.url));
    return spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body], { cwd, encoding: 'utf8' });
  };
  return { repo, git, change, base, run };
}
const assertCLIPass = result => {
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /UI-Parity PR body: PASS/);
};
const assertCLIStale = (result, lane) => {
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.ok(result.stderr.includes(`${lane} PASS has a stale head`), result.stderr);
};

test('CLI accepts a garden-only ancestor and resolves short SHA evidence', t => {
  const { base, change, run } = gatesGitFixture(t);
  change('docs/feature-ledger.md');
  for (const sha of [base, base.slice(0, 7), base.slice(0, 8), base.toUpperCase()]) {
    assertCLIPass(run('package-tests', sha));
  }
  assertCLIStale(run('ledger', base), 'ledger');
  assertCLIStale(run('unsigned-build', base), 'unsigned-build');
});

test('CLI guards every mandatory input for every declared code lane', t => {
  const { git, base, change, run } = gatesGitFixture(t);
  const mandatoryFiles = ['App/Changed.swift', 'AppTests/Changed.swift', 'Packages/Changed.swift', 'UITests/Changed.swift', 'project.yml'];
  let pairs = 0;
  for (const file of mandatoryFiles) {
    git('checkout', '-q', '--detach', base);
    change(file);
    for (const lane of codeGateLanes) {
      assertCLIStale(run(lane, base), lane);
      assertCLIStale(run(lane, base, `CODE same ${codeSame}`), lane);
      pairs++;
    }
  }
  assert.equal(pairs, codeGateLanes.length * mandatoryFiles.length);
  git('checkout', '-q', '--detach', base);
  change('docs/notes.md');
  for (const lane of codeGateLanes) assertCLIPass(run(lane, base));
});

test('CLI enforces real ledger, design and agent tooling inputs', t => {
  const { git, base, change, run } = gatesGitFixture(t);
  for (const [lane, file] of [['ledger', 'docs/feature-ledger.html'], ['design-check', 'scripts/verify_design_catalog.js'], ['node-tooling', 'scripts/agents/tool.mjs']]) {
    git('checkout', '-q', '--detach', base);
    change(file);
    assertCLIStale(run(lane, base), lane);
    assertCLIStale(run(lane, base, `CODE same ${codeSame}`), lane);
    assertCLIPass(run('package-tests', base));
  }
});

test('CLI requires CODE same for pre-rebase and unknown SHAs', t => {
  const { git, base, change, run } = gatesGitFixture(t);
  const divergent = change('docs/pre-rebase.md');
  git('checkout', '-q', '--detach', base);
  change('docs/rebased.md');
  for (const sha of [divergent, 'f'.repeat(40)]) {
    assertCLIStale(run('package-tests', sha), 'package-tests');
    assertCLIPass(run('package-tests', sha, `CODE same ${codeSame}`));
    assertCLIStale(run('package-tests', sha, `code same ${codeSame}`), 'package-tests');
  }
});

test('CLI guards transitive test assets, design files and perf fixtures for every code lane', t => {
  const { git, base, change, run } = gatesGitFixture(t);
  const files = ['TestAssets/synthetic/landscape-3x2.png', 'design/picsee-ui-system/tokens/colors.css', 'scripts/perf/fixtures/signpost-messages.json'];
  let pairs = 0;
  for (const file of files) {
    git('checkout', '-q', '--detach', base);
    change(file);
    for (const lane of codeGateLanes) {
      assertCLIStale(run(lane, base), lane);
      assertCLIStale(run(lane, base, `CODE same ${codeSame}`), lane);
      pairs++;
    }
  }
  assert.equal(pairs, codeGateLanes.length * files.length);
});


test('CLI rejects tag tree and blob object evidence without peeling to an ancestor', t => {
  const { git, base, change, run } = gatesGitFixture(t);
  git('tag', '-a', 'ancestor-tag', base, '-m', 'annotated ancestor');
  const objects = [git('rev-parse', 'ancestor-tag'), git('rev-parse', `${base}^{tree}`), git('rev-parse', `${base}:seed.txt`)];
  change('docs/notes.md');
  for (const object of objects) {
    for (const sha of [object, object.slice(0, 7)]) {
      assertCLIStale(run('package-tests', sha), 'package-tests');
      assertCLIPass(run('package-tests', sha, `CODE same ${codeSame}`));
    }
  }
});

test('CLI reuses coverage evidence after garden and docs commits', t => {
  const { base, change, run } = gatesGitFixture(t);
  change('docs/feature-ledger.md');
  change('docs/notes.md');
  for (const sha of [base, base.slice(0, 7), base.toUpperCase()]) assertCLIPass(run('package-coverage', sha));
});

test('CLI rejects coverage evidence after any declared coverage input changes', t => {
  const { git, base, change, run } = gatesGitFixture(t);
  const files = ['App/Changed.swift', 'AppTests/Changed.swift', 'Packages/Changed.swift', 'UITests/Changed.swift',
    'project.yml', 'TestAssets/fixture.png', 'design/tokens.css', 'scripts/perf/fixtures/data.json',
    '.github/workflows/ci.yml', '.github/actions/xcode-setup/action.yml', 'scripts/ci/test.sh',
    'scripts/tdd/swift-lcov.sh', 'scripts/heavy-lock.sh', '.claude/tdd-guardian/config.json',
    '.agents/skills/picsee-delegator/scripts/owner-gates.sh', '.agents/skills/picsee-delegator/scripts/lcov-total.py'];
  for (const file of files) {
    git('checkout', '-q', '--detach', base);
    change(file);
    assertCLIStale(run('package-coverage', base), 'package-coverage');
    assertCLIStale(run('package-coverage', base, `CODE same ${codeSame}`), 'package-coverage');
  }
});

test('CLI checks the same lane inputs from a repository subdirectory', t => {
  const { repo, git, base, change, run } = gatesGitFixture(t);
  const cwd = join(repo, 'scripts/nested');
  mkdirSync(cwd, { recursive: true });
  change('Packages/Changed.swift');
  assertCLIStale(run('package-tests', base, 'recorded run', cwd), 'package-tests');
  git('checkout', '-q', '--detach', base);
  change('docs/notes.md');
  assertCLIPass(run('package-tests', base, 'recorded run', cwd));
});

test('CLI explains changed ancestor inputs even when Source contains CODE same', t => {
  const { base, change, run } = gatesGitFixture(t);
  change('Packages/Changed.swift');
  const result = run('package-tests', base, `CODE same ${codeSame}`);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.ok(result.stderr.includes(`inputs changed since ${base}`), result.stderr);
  assert.doesNotMatch(result.stderr, /without CODE same/);
});

const checkerAck = (sha, families = 'ledger,design', rationale = 'Update checker rules', audits = '~/.picsee/herdr/gpt-auditor/i471-audit.md,~/.picsee/herdr/opus-auditor/i471-confirm.md') =>
  `Checker-Change: ${sha} families=${families} — ${rationale} — audits: ${audits}`;

function checkerGitFixture(t) {
  const f = gatesGitFixture(t);
  const run = acknowledgement => {
    const sha = f.git('rev-parse', 'HEAD');
    const body = join(f.repo, 'body.md');
    writeFileSync(body, completeGates(sha) + '\n' + acknowledgement + '\n');
    const script = fileURLToPath(new URL('./ui-parity-pr-body-lint.mjs', import.meta.url));
    return spawnSync(process.execPath, [script, '--base', 'base', '--body-file', body], { cwd: f.repo, encoding: 'utf8' });
  };
  return { ...f, run };
}

for (const [label, acknowledgement, reason] of [
  ['missing', () => '', /Checker-Change.*required/i],
  ['stale SHA', () => checkerAck(oldHead), /Checker-Change.*head SHA/i],
  ['short SHA', sha => checkerAck(sha.slice(0, 8)), /Checker-Change.*format/i],
  ['missing family', sha => checkerAck(sha, 'ledger'), /Checker-Change.*design/i],
  ['missing ledger family', sha => checkerAck(sha, 'design'), /Checker-Change.*ledger/i],
  ['missing audits field', sha => checkerAck(sha).split(' — audits:')[0], /Checker-Change.*format/i],
  ['tilde fenced example', sha => '~~~text\n' + checkerAck(sha) + '\n~~~', /Checker-Change.*required/i],
  ['empty rationale', sha => checkerAck(sha, 'ledger,design', ' '), /Checker-Change.*rationale/i],
  ['no audits', sha => checkerAck(sha, 'ledger,design', 'Update rules', ''), /Checker-Change.*audit/i],
  ['one audit', sha => checkerAck(sha, 'ledger,design', 'Update rules', 'gpt.md'), /Checker-Change.*audit/i],
  ['duplicate audits', sha => checkerAck(sha, 'ledger,design', 'Update rules', 'gpt.md,gpt.md'), /Checker-Change.*audit/i],
  ['placeholder audits', sha => checkerAck(sha, 'ledger,design', 'Update rules', 'TBD,none'), /Checker-Change.*audit/i],
  ['unknown family', sha => checkerAck(sha, 'ledger,design,other'), /Checker-Change.*famil/i],
  ['duplicate family', sha => checkerAck(sha, 'ledger,design,ledger'), /Checker-Change.*famil/i],
  ['duplicate lines', sha => checkerAck(sha) + '\n' + checkerAck(sha), /Checker-Change.*one|unique/i],
  ['fenced example', sha => '```text\n' + checkerAck(sha) + '\n```', /Checker-Change.*required/i],
  ['commented example', sha => '<!--\n' + checkerAck(sha) + '\n-->', /Checker-Change.*required/i],
]) {
  test(`checker-change CLI rejects ${label} acknowledgement`, t => {
    const f = checkerGitFixture(t);
    f.change('scripts/ledger/nested/rules.mjs');
    const sha = f.change('scripts/design/model.mjs');
    const result = f.run(acknowledgement(sha));
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stderr, reason);
  });
}

test('checker-change CLI covers every changed family and allows either order and extra known family', t => {
  const f = checkerGitFixture(t);
  let sha = f.change('scripts/ledger/rules.mjs');
  assertCLIPass(f.run(checkerAck(sha, 'ledger')));
  assertCLIPass(f.run(checkerAck(sha, 'design,ledger')));
  sha = f.change('scripts/design/model.mjs');
  assertCLIPass(f.run(checkerAck(sha, 'design,ledger')));
  const missing = f.run(checkerAck(sha, 'ledger'));
  assert.equal(missing.status, 1, missing.stdout + missing.stderr);
  assert.match(missing.stderr, /Checker-Change.*design/);
  assertCLIPass(f.run(checkerAck(sha.toUpperCase(), 'ledger,design', 'Document changed rules', 'https://github.com/anzchy/picsee/pull/472#pullrequestreview-123,https://github.com/anzchy/picsee/pull/472#issuecomment-456')));
});

for (const refs of [
  '#471,#449', 'TBD.md,none.md', 'http://x,http://y',
  'a.md#r1,a.md#r2', 'a.md,./a.md', 'a.md,b.md',
  'https://github.com/anzchy/picsee/pull/0#issuecomment-1,https://github.com/anzchy/picsee/pull/472#issuecomment-0',
  '~/.picsee/herdr/x-auditor/i471-audit.md,~/.picsee/herdr/opus-auditor/i471-audit.md',
  'https://example.com/review/1,https://example.com/review/2',
  'https://github.com/anzchy/other/pull/472#issuecomment-1,https://github.com/anzchy/picsee/pull/472#issuecomment-2',
  'https://github.com/anzchy/picsee/pull/472,https://github.com/anzchy/picsee/issues/471',
  '~/.picsee/herdr/gpt-auditor/i471-audit.md#r1,~/.picsee/herdr/gpt-auditor/i471-audit.md#r2',
  '~/.picsee/herdr/gpt-auditor/i471-audit.md,~/.picsee/herdr/gpt-auditor/./i471-audit.md',
  ...['TBD', 'none', 'n/a', 'n-a', 'todo', 'x'].map(token =>
    `~/.picsee/herdr/gpt-auditor/${token}-audit.md,~/.picsee/herdr/opus-auditor/i471-audit.md`),
]) {
  test(`checker-change CLI rejects non-report or duplicate audit references ${refs}`, t => {
    const f = checkerGitFixture(t);
    const sha = f.change('scripts/ledger/rules.mjs');
    const result = f.run(checkerAck(sha, 'ledger', 'Update rules', refs));
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stderr, /Checker-Change.*audit/i);
  });
}

test('checker-change CLI accepts normalized report paths and mixed report/review references', t => {
  const f = checkerGitFixture(t);
  const sha = f.change('scripts/ledger/rules.mjs');
  assertCLIPass(f.run(checkerAck(sha, 'ledger', 'Update rules',
    '~/.picsee/herdr/gpt-auditor/./i471-audit2.md#r1,~/.picsee/herdr/opus-auditor/i471-confirm-fix1.md')));
  assertCLIPass(f.run(checkerAck(sha, 'ledger', 'Update rules',
    '~/.picsee/herdr/gpt-auditor/i471-audit.md,https://github.com/anzchy/picsee/pull/472#pullrequestreview-123')));
});

test('checker-change CLI ignores fenced unclosed comments before a real acknowledgement', t => {
  const f = checkerGitFixture(t);
  const sha = f.change('scripts/ledger/rules.mjs');
  const ack = checkerAck(sha, 'ledger');
  assertCLIPass(f.run(ack));
  for (const fence of ['```', '~~~']) {
    assertCLIPass(f.run(`${fence}html\n<!--\n${fence}\n${ack}`));
    const hidden = f.run(`${fence}text\n${ack}\n${fence}`);
    assert.equal(hidden.status, 1, hidden.stdout + hidden.stderr);
    assert.match(hidden.stderr, /Checker-Change.*required/i);
  }
  for (const end of ['', '\n-->']) {
    const hidden = f.run(`<!--\n${ack}${end}`);
    assert.equal(hidden.status, 1, hidden.stdout + hidden.stderr);
    assert.match(hidden.stderr, /Checker-Change.*required/i);
  }
});

for (const [label, change, reason] of [
  ['separator-only rationale', sha => checkerAck(sha, 'ledger', '— — —'), /rationale/i],
  ['mixed separator rationale', sha => checkerAck(sha, 'ledger', '- – —'), /rationale/i],
  ['no space after first delimiter', sha => checkerAck(sha, 'ledger').replace('— Update', '—Update'), /format/i],
  ['no space before first delimiter', sha => checkerAck(sha, 'ledger').replace('ledger —', 'ledger—'), /format/i],
  ['no space before second delimiter', sha => checkerAck(sha, 'ledger').replace('rules —', 'rules—'), /format/i],
  ['no space after second delimiter', sha => checkerAck(sha, 'ledger').replace('— audits:', '—audits:'), /format/i],
]) {
  test(`checker-change CLI rejects ${label}`, t => {
    const f = checkerGitFixture(t);
    const sha = f.change('scripts/ledger/rules.mjs');
    const result = f.run(change(sha));
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stderr, reason);
  });
}

test('non-checker CLI needs no acknowledgement and permits a stray acknowledgement', t => {
  const f = checkerGitFixture(t);
  for (const file of ['docs/notes.md', 'scripts/ledger-extra/tool.mjs', 'scripts/design-check.mjs']) {
    f.change(file);
    assertCLIPass(f.run(''));
    assertCLIPass(f.run('Checker-Change: old note'));
  }
});

test('checker-change CLI includes deletions and renames across family boundaries', t => {
  const f = checkerGitFixture(t);
  f.change('scripts/ledger/rules.mjs');
  f.git('branch', '-f', 'base', 'HEAD');
  f.git('rm', 'scripts/ledger/rules.mjs');
  f.git('commit', '-qm', 'delete checker');
  assert.equal(f.run('').status, 1);
  assertCLIPass(f.run(checkerAck(f.git('rev-parse', 'HEAD'), 'ledger')));
  f.git('checkout', '-q', '--detach', 'base');
  mkdirSync(join(f.repo, 'scripts/design'), { recursive: true });
  f.git('mv', 'scripts/ledger/rules.mjs', 'scripts/design/rules.mjs');
  f.git('commit', '-qm', 'move checker');
  const sha = f.git('rev-parse', 'HEAD');
  assert.equal(f.run(checkerAck(sha, 'design')).status, 1);
  assertCLIPass(f.run(checkerAck(sha)));
});

for (const family of ['ledger', 'design']) {
  test(`checker-change CLI matches exact ${family} path and head transitions`, t => {
    const f = checkerGitFixture(t);
    let sha = f.change(`scripts/${family}`);
    assert.equal(f.run('').status, 1);
    assertCLIPass(f.run(checkerAck(sha, family)));
    const previous = sha;
    sha = f.change('docs/later.md');
    assert.equal(f.run(checkerAck(previous, family)).status, 1);
    assertCLIPass(f.run(checkerAck(sha, family)));
  });
}

for (const file of ['scripts/ledger/é.mjs', 'scripts/design/line\nbreak.mjs']) {
  test(`checker-change CLI detects Git-quoted path ${JSON.stringify(file)}`, t => {
    const f = checkerGitFixture(t);
    const sha = f.change(file);
    const result = f.run('');
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stderr, /Checker-Change.*required/);
    assertCLIPass(f.run(checkerAck(sha)));
  });
}

test('checker-change CLI detects file-to-symlink type changes', t => {
  const f = checkerGitFixture(t);
  const file = 'scripts/ledger/rules.mjs';
  f.change(file);
  f.git('branch', '-f', 'base', 'HEAD');
  unlinkSync(join(f.repo, file));
  symlinkSync('../replacement.mjs', join(f.repo, file));
  f.git('add', file);
  f.git('commit', '-qm', 'replace checker with symlink');
  const result = f.run('');
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /Checker-Change.*required/);
  assertCLIPass(f.run(checkerAck(f.git('rev-parse', 'HEAD'), 'ledger')));
});
