import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Owner 2026-11-14: 「…不需要hook，在brief template中，验证的漏洞…」 — the brief, not a hook, requires mado-verify.
const root = fileURLToPath(new URL('../../../../', import.meta.url));
const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
const templates = '.agents/skills/picsee-delegator/references/templates';
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
  const skill = read('.agents/skills/picsee-delegator/SKILL.md');
  const step = n => skill.slice(skill.indexOf(`\n${n}. **`), skill.indexOf(`\n${n + 1}. **`));
  assert.match(step(2), /Verify \(mado-verify\)/);
  assert.match(step(2), /hand-written brief/);
  assert.match(step(4), /evidence\.mjs check --head <sha>/);
  assert.match(step(5), /mado-verify/);
  assert.match(step(8), /evidence\.mjs check --head <(?:audited-)?sha>/);
});

test('delegator check steps pin the issue, open the comment by hand, and handle a rebase (fix round 1)', () => {
  const skill = read('.agents/skills/picsee-delegator/SKILL.md');
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
  assert.match(step1, /unset PICSEE_APP_FILTER/);
  assert.doesNotMatch(step1, /xcodebuild test -scheme/);
  assert.match(step1, /keyWindow=nil/);
  assert.match(step1, /NOT VERIFIED/);
  assert.match(step1, /delegator's `?owner-gates/);
});
