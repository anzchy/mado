import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Owner 2026-11-14: 「…不需要hook，在brief template中，验证的漏洞…」 — the brief, not a hook, requires mado-verify.
const root = fileURLToPath(new URL('../../../../', import.meta.url));
const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
const templates = '.agents/skills/mado-delegator/references/templates';
const section = (text, heading) => {
  const start = text.indexOf(heading);
  assert.notEqual(start, -1, `missing ${heading}`);
  const next = text.indexOf('\n## ', start + heading.length);
  return text.slice(start, next === -1 ? undefined : next);
};

test('brief template keeps the mark-target line at the top with the handoff argument', () => {
  const head = read(`${templates}/brief-template.md`).split('\n').slice(0, 8).join('\n');
  assert.match(head, /mark-target\.mjs <pane-home> <briefed-worktree> <issue-number> <Report-Task> <absolute-handoff-path>/);
  assert.match(head, /\{worktree, branch, issue, task, handoff\}/);
});

test('brief template has a mandatory Verify section for the first handoff and every fix round', () => {
  const verify = section(read(`${templates}/brief-template.md`), '## Verify (mado-verify)');
  assert.match(verify, /mandatory/i);
  assert.match(verify, /`\/mado-verify`/);
  assert.match(verify, /\.agents\/skills\/mado-verify\/SKILL\.md/);
  assert.match(verify, /every fix round/);
  assert.match(verify, /comment URL/);
  assert.match(verify, /head/);
  assert.match(verify, /evidence\.mjs check --head/);
});

test('brief template Gates block points to SKILL.md step 1 instead of a stale command list', () => {
  const gates = section(read(`${templates}/brief-template.md`), '## Gates');
  assert.match(gates, /SKILL\.md.*step 1/);
  assert.match(gates, /owner-gates\.sh/);
  assert.match(gates, /App tests/);
  assert.doesNotMatch(gates, /swift test --package-path|swift-lcov\.sh|```/);
});

test('fix brief template asks for a new mado-verify run on the fix head', () => {
  const fix = read(`${templates}/confirm-and-fix-templates.md`);
  const fixBrief = fix.slice(0, fix.indexOf('# Confirm request template'));
  assert.match(fixBrief, /mado-verify/);
  assert.match(fixBrief, /comment URL/);
});

test('delegator loop: briefs keep the Verify section; record check before audit and before merge', () => {
  const skill = read('.agents/skills/mado-delegator/SKILL.md');
  const step = n => skill.slice(skill.indexOf(`\n${n}. **`), skill.indexOf(`\n${n + 1}. **`));
  assert.match(step(2), /Verify \(mado-verify\)/);
  assert.match(step(2), /hand-written brief/);
  assert.match(step(4), /evidence\.mjs check --head <sha>/);
  assert.match(step(5), /mado-verify/);
  assert.match(step(8), /evidence\.mjs check --head <(?:audited-)?sha>/);
});

test('delegator check steps pin the issue, open the comment by hand, and handle a rebase (fix round 1)', () => {
  const skill = read('.agents/skills/mado-delegator/SKILL.md');
  const step = n => skill.slice(skill.indexOf(`\n${n}. **`), skill.indexOf(`\n${n + 1}. **`));
  assert.match(step(4), /evidence\.mjs check --head <sha> --issue <n>/);
  assert.match(step(4), /open the comment by hand/);
  assert.match(step(8), /evidence\.mjs check --head <audited-sha> --issue <n>/);
  assert.match(step(8), /CODE same/);
  assert.match(step(8), /CODE differ[^.]*new\s+mado-verify run/);
  assert.match(section(read(`${templates}/brief-template.md`), '## Verify (mado-verify)'), /check --head <sha> --issue <n>/);
  const verifySkill = read('.agents/skills/mado-verify/SKILL.md');
  assert.match(verifySkill, /check --head <sha> --issue <n>/);
  assert.match(verifySkill, /anzchy\/mado/);
  assert.match(verifySkill, /exit(?:s| code)? 70/);
});

test('ui-parity contract names the local apptests lane and keeps CI as the app-tests row source', () => {
  const contract = read('docs/agents/ui-parity-contract.md');
  assert.doesNotMatch(contract, /owner-gates 不设本地 App lane/);
  assert.match(contract, /owner-gates[^。]*本地 `apptests` lane[^。]*heavy-lock[^。]*gates-rows\.mjs --ci/);
});

test('SKILL.md step 1 runs App tests the CI way and names the Codex key-window limit', () => {
  const skill = read('.agents/skills/mado-verify/SKILL.md');
  const step1 = skill.slice(skill.indexOf('## 1. Gate ladder'), skill.indexOf('## 2.'));
  assert.match(step1, /build-for-testing/);
  assert.match(step1, /scripts\/tdd\/app-lane\.mjs/);
  assert.match(step1, /unset MADO_APP_FILTER/);
  assert.doesNotMatch(step1, /xcodebuild test -scheme/);
  assert.match(step1, /keyWindow=nil/);
  assert.match(step1, /NOT VERIFIED/);
  assert.match(step1, /delegator's `?owner-gates/);
});

// #898 (owner 2026-11-25): 「执行更严格的tdd：在 brief 里加一条：实现之前不得有生产代码改动进入 RED 记录的 dirty_source…」
const sepDocs = ['.agents/skills/mado-delegator/references/templates/brief-template.md', '.agents/skills/mado-verify/SKILL.md',
  '.agents/skills/mado-verify/evidence-template.md', 'docs/agents/audit-dimensions.md', 'docs/agents/test-lanes.md',
  '.agents/skills/mado-delegator/SKILL.md', '.agents/skills/mado-delegator/references/templates/audit-brief.md',
  '.agents/skills/mado-delegator/references/templates/audit-request-template.md'];

test('898 brief template Test-first carries the RED separation rule and the stub policy', () => {
  const tf = section(read(`${templates}/brief-template.md`), '## Test-first');
  assert.match(tf, /no tracked production file may differ from the RED record's `head_sha`/);
  assert.match(tf, /Stub-For: <receipt-ID>/);
  assert.match(tf, /signatures only/);
  assert.match(tf, /clean committed tree/);
  assert.match(tf, /waiver/i);
  assert.match(section(read(`${templates}/brief-template.md`), '## Handoff'), /RED separation/);
});

test('898 mado-verify SKILL, evidence template, D5 and the audit templates name the tdd-separation lane', () => {
  const skill = read('.agents/skills/mado-verify/SKILL.md');
  for (const re of [/tdd-separation\.mjs/, /report-only/, /Stub-For:/, /RED was recorded on a clean committed tree/, /--rebased-from/, /replay/, /tdd-waivers/])
    assert.match(skill, re);
  assert.match(read('.agents/skills/mado-verify/evidence-template.md'), /RED separation/);
  const d5 = read('docs/agents/audit-dimensions.md').split('\n').find(line => line.startsWith('| D5 '));
  assert.match(d5, /tdd-separation/); assert.match(d5, /waiver/); assert.match(d5, /receipt present/i);
  for (const rel of ['.agents/skills/mado-delegator/references/templates/audit-brief.md', '.agents/skills/mado-delegator/references/templates/audit-request-template.md'])
    assert.match(read(rel), /tdd-separation/, rel);
  const delegator = read('.agents/skills/mado-delegator/SKILL.md');
  assert.match(delegator, /tdd-waivers/); assert.match(delegator, /Stub-For:/);
});

test('898 test-lanes.md reconciles the stub policy: stubs are committed before the RED', () => {
  const lanes = read('docs/agents/test-lanes.md');
  // A boolean, not doesNotMatch: the doc quotes "No such file or directory", which the plugin reads as an environment failure.
  assert.equal(lanes.includes('桩在 record 时是未提交的实现改动'), false, 'test-lanes.md still says stubs are uncommitted at record time');
  assert.match(lanes, /Stub-For:/);
  assert.match(lanes, /tdd-separation/);
});

test('898 no text claims the lane proves test-first', () => {
  for (const rel of sepDocs)
    for (const line of read(rel).split('\n'))
      if (/test-first is proven|proves? test-first/i.test(line)) assert.match(line, /\b(never|not|no)\b/i, `${rel}: ${line}`);
});

// #898 fix1 WI-6: the docs describe the fix-round rules (anchored Refactor:, waiver claims accepted by digest, required
// replays by assertion, exceptions on the auditor checklist).
test('898 fix1 WI-6 docs: anchored Refactor:, accepted waiver claims, required replays, exceptions on the audit checklist', () => {
  const tf = section(read(`${templates}/brief-template.md`), '## Test-first');
  assert.match(tf, /Refactor: <receipt-ID> <why>/);
  assert.match(tf, /claim/);
  const skill = read('.agents/skills/mado-verify/SKILL.md');
  for (const re of [/--accept-waiver/, /CLAIMED-WAIVER/, /OWNER_GATES_ACCEPT_WAIVERS/, /\.build\/mado-verify\/replay\//, /ERR_ASSERTION/, /required=yes\|no/, /--remerge-diff/, /byte for byte/, /stub-only-window/])
    assert.match(skill, re);
  const delegator = read('.agents/skills/mado-delegator/SKILL.md');
  assert.match(delegator, /--accept-waiver/); assert.match(delegator, /expires/);
  const d5 = read('docs/agents/audit-dimensions.md').split('\n').find(line => line.startsWith('| D5 '));
  assert.match(d5, /EXCEPTIONS/); assert.match(d5, /CLAIMED-WAIVER/);
  for (const rel of ['.agents/skills/mado-delegator/references/templates/audit-brief.md', '.agents/skills/mado-delegator/references/templates/audit-request-template.md']) {
    const text = read(rel);
    assert.match(text, /EXCEPTIONS/, rel); assert.match(text, /CLAIMED-WAIVER/, rel);
  }
});
