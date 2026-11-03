import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, unlinkSync } from 'node:fs';
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
