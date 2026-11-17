import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { decide } from './heavy-lock-guard.mjs';

const script = fileURLToPath(new URL('./heavy-lock-guard.mjs', import.meta.url));
const bash = (command) => ({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd: '/tmp' });
const denied = (command) => decide(bash(command))?.hookSpecificOutput?.permissionDecision === 'deny';

test('denies bare heavy commands', () => {
  for (const c of [
    'swift test --package-path Packages/MadoKit',
    'xcodegen generate',
    "xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci",
    'cd Packages/MadoKit && swift test --filter foo',
    'MADO_HEAVY_LOCK_HELD=1 swift test --package-path Packages/MadoKit',
    'env FOO=1 swift test',
    'time xcodebuild test -scheme Mado',
    'xcrun xcodebuild -list',
    'xcodebuild',
    "bash -c 'swift test --package-path Packages/MadoKit'",
    'swift test 2>&1 | tail -20',
    'echo start; swift --package-path Packages/MadoKit test',
  ]) assert.ok(denied(c), c);
});

test('allows heavy commands under scripts/heavy-lock.sh', () => {
  for (const c of [
    'scripts/heavy-lock.sh swift test --package-path Packages/MadoKit',
    './scripts/heavy-lock.sh xcodegen generate',
    '/Users/x/picsee-wt/a/scripts/heavy-lock.sh xcodebuild build -scheme Mado',
    '~/.mado/device/ram/with-ram.sh unit scripts/heavy-lock.sh swift test --package-path Packages/MadoKit',
    'MADO_HEAVY_LOCK_WAIT_SECS=60 scripts/heavy-lock.sh swift test',
    "scripts/heavy-lock.sh bash -c 'xcodegen generate && xcodebuild build'",
  ]) assert.equal(decide(bash(c)), null, c);
});

test('lanes and receipt.js take the lock themselves and pass unwrapped', () => {
  for (const c of [
    'node scripts/tdd/swift-lane.mjs itemIDSurvivesJSONRoundTrip',
    'node scripts/tdd/app-lane.mjs issue512ChildReadKeepsTitleCurrentRowAndFailureDash',
    'node scripts/tdd/trash-lane.mjs --discover',
    'node "$plugin_root/scripts/tdd-guardian/receipt.js" record --id P0-XX-WI-1 --lane swift-red --files Packages/MadoKit/Tests/MadoCoreTests/ItemIDTests.swift',
    'node "$plugin_root/scripts/tdd-guardian/receipt.js" verify --id P0-XX-WI-1',
  ]) assert.equal(decide(bash(c)), null, c);
});

test('denies trash-lane wrapped in heavy-lock.sh', () => {
  const r = decide(bash('scripts/heavy-lock.sh node scripts/tdd/trash-lane.mjs'));
  assert.equal(r.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(r.hookSpecificOutput.permissionDecisionReason, /trash-lane/);
});

test('ignores heavy words that are only text', () => {
  for (const c of [
    'grep -rn "swift test" AGENTS.md',
    "git commit -m 'run swift test under the lock; xcodebuild too'",
    'echo xcodebuild',
    'swift --version',
    'xcodebuild -version',
    'xcodegen --version',
    'swift build --package-path Packages/MadoKit',
    "cat > /tmp/x <<'EOF'\nswift test\nxcodebuild build\nEOF\necho done",
    '# swift test\nls',
  ]) assert.equal(decide(bash(c)), null, c);
});

test('ignores other tools', () => {
  assert.equal(decide({ tool_name: 'Edit', tool_input: { file_path: 'a', command: 'swift test' } }), null);
});

test('end to end: stdin JSON in, deny JSON out', () => {
  const r = spawnSync(process.execPath, [script], { input: JSON.stringify(bash('swift test')), encoding: 'utf8' });
  assert.equal(r.status, 0);
  const out = JSON.parse(r.stdout);
  assert.equal(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.equal(out.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /scripts\/heavy-lock\.sh swift test/);
  const ok = spawnSync(process.execPath, [script], { input: JSON.stringify(bash('scripts/heavy-lock.sh swift test')), encoding: 'utf8' });
  assert.equal(ok.status, 0);
  assert.equal(ok.stdout, '');
});

test('malformed stdin passes through silently', () => {
  const r = spawnSync(process.execPath, [script], { input: 'not json', encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout, '');
});
