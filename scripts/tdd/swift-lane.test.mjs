import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createRequire } from 'node:module';

const root = process.cwd();
const temp = mkdtempSync(path.join(os.tmpdir(), 'mado-swift-tests-'));
after(() => rmSync(temp, { recursive: true, force: true }));
// Only Swift itself is replaced: the real wrapper and heavy lock execute.
writeFileSync(path.join(temp, 'swift'), `#!${process.execPath}
const fs = require('node:fs');
fs.writeFileSync(process.env.ARGV_FILE, JSON.stringify({argv:process.argv.slice(2), held:process.env.PICSEE_HEAVY_LOCK_HELD}));
let text=fs.readFileSync(process.env.FIXTURE);
if(process.env.TRUNCATE_ROOT) text=Buffer.from(text.toString().split("Test Suite 'All tests' failed")[0]);
// Feed uneven byte chunks (including multibyte checkmarks), across both streams.
const stream = process.env.ON_STDERR ? process.stderr : process.stdout;
for(let i=0;i<text.length;i+=17) stream.write(text.subarray(i,i+17));
if(process.env.SPLIT) process.stderr.write(text);
if(process.env.CRASH_STDERR) process.stderr.write(fs.readFileSync(process.env.CRASH_STDERR_FIXTURE,'utf8').split('\\n').filter(l=>/Fatal error|exited with unexpected signal/.test(l)).join('\\n'));
if(process.env.INCOMPLETE_SWIFT) process.stderr.write(fs.readFileSync(process.env.SWIFT_START_FIXTURE,'utf8').split('\\n').filter(l=>l.includes('Test run started')).join('\\n')); 
process.exitCode=Number(process.env.SWIFT_EXIT);
`, { mode: 0o755 });
const require = createRequire(import.meta.url);
const cache = path.join(process.env.HOME, '.claude/plugins/cache/xiaolai/tdd-guardian');
const plugin = process.env.PICSEE_TDD_PLUGIN_ROOT || path.join(cache, '0.10.2');
// Keep the real plugin optional, and load it only inside tests that use it.
function pluginTest(name, fn) {
  test(name, t => {
    const execPath = path.join(plugin, 'scripts/tdd-guardian/lib/exec.js');
    const verificationPath = path.join(plugin, 'scripts/tdd-guardian/lib/verification.js');
    if (!existsSync(execPath) || !existsSync(verificationPath)) {
      t.skip(`tdd-guardian plugin cache not found at ${plugin}`);
      return;
    }
    const exec = require(execPath);
    const { classifyRedRun } = require(verificationPath);
    return fn({ exec, classifyRedRun });
  });
}
function run(fixture, code, { filter = 'FixtureTests/selectedOnly', args = [], stderr = false, split = false, crashStderr = false, truncateRoot = false, incompleteSwift = false } = {}) {
  const argvFile = path.join(temp, 'argv.json');
  const env = { ...process.env, PATH: `${temp}:${process.env.PATH}`, PICSEE_SWIFT_FILTER: filter,
    PICSEE_HEAVY_LOCK: path.join(temp, 'heavy.lock'), PICSEE_HEAVY_LOCK_HELD: '',
    PICSEE_MDPRO_LOCK: path.join(temp, 'mdpro.lock'), MDPRO_HEAVY_LOCK_HELD: '',
    SWIFT_START_FIXTURE: path.join(root,'scripts/tdd/fixtures/swift-pass.txt'), TRUNCATE_ROOT: truncateRoot ? '1' : '', INCOMPLETE_SWIFT: incompleteSwift ? '1' : '', CRASH_STDERR_FIXTURE: path.join(root,'scripts/tdd/fixtures/xctest-partial-crash.txt'), ARGV_FILE: argvFile, FIXTURE: path.join(root, 'scripts/tdd/fixtures', fixture + '.txt'),
    SWIFT_EXIT: String(code), ON_STDERR: stderr ? '1' : '', SPLIT: split ? '1' : '', CRASH_STDERR: crashStderr ? '1' : '' };
  const r = spawnSync(process.execPath, ['scripts/tdd/swift-lane.mjs', ...args], { env, encoding:'utf8', timeout:10000 });
  assert.ifError(r.error);
  return { ...r, argvFile };
}
for (const [fixture, code, expected, kind] of [
  ['swift-pass',0,{total:3,failed:0,passed:2,skipped:1},'green'],
  ['swift-fail',1,{total:3,failed:1,passed:1,skipped:1},'assertion-failure'],
  ['xctest-pass',0,{total:12,failed:0,passed:11,skipped:1},'green'],
  ['xctest-fail',1,{total:12,failed:1,passed:10,skipped:1},'assertion-failure'],
  ['xctest-two-assertions',1,{total:1,failed:1,passed:0,skipped:0},'assertion-failure'],
  ['swift-crash-name-pass',0,{total:1,failed:0,passed:1,skipped:0},'green'],
  ['swift-crash-name-fail',1,{total:1,failed:1,passed:0,skipped:0},'assertion-failure'],
  ['swift-known-pass',0,{total:3,failed:0,passed:3,skipped:0},'green'],
  ['swift-known-fail',1,{total:3,failed:1,passed:2,skipped:0},'assertion-failure'],
]) {
  pluginTest(`${fixture}: counted once, classified ${kind} by real plugin`, ({ exec, classifyRedRun }) => {
    const r = run(fixture,code,{stderr:fixture.startsWith('xctest')});
    assert.deepEqual(exec.parseCounts(r.stdout,r.stderr),expected);
    assert.equal(r.status,code,r.stderr);
    assert.equal(classifyRedRun({status:exec.classify(r.status,r.stdout,r.stderr),testCounts:exec.parseCounts(r.stdout,r.stderr)}).kind,kind);
    assert.equal((r.stdout.match(/^Tests run:/gm)||[]).length,1);
  });
}
pluginTest('compile failure is runner-error/environment with no count line', ({ exec, classifyRedRun }) => {
  const r = run('compile-fail',1);
  assert.equal(r.status,70);
  assert.equal(exec.parseCounts(r.stdout,r.stderr),null);
  assert.equal(exec.classify(r.status,r.stdout,r.stderr),'runner-error');
  assert.equal(classifyRedRun({status:exec.classify(r.status,r.stdout,r.stderr)}).kind,'environment');
});
test('only the selected filter is passed as a literal argv under the lock', () => {
  const r = run('swift-pass',0,{args:['selected name;$literal']});
  assert.equal(r.status,0,r.stderr);
  assert.deepEqual(JSON.parse(readFileSync(r.argvFile)),{argv:['test','--package-path','Packages/MadoKit','--filter','selected name;$literal'],held:'1'});
});
test('missing filter fails closed rather than running the full suite', () => {
  const r = run('swift-pass',0,{filter:''});
  assert.equal(r.status,64);
  assert.doesNotMatch(r.stdout,/Tests run:/);
});
pluginTest('a runner failure after a completed pass is not assertion RED', ({ exec }) => {
  const r = run('swift-pass',1);
  assert.equal(r.status,70);
  assert.equal(exec.parseCounts(r.stdout,r.stderr),null);
});
test('captured fixtures contain no private home prefix', () => {
  for (const file of readdirSync('scripts/tdd/fixtures').filter(f => f.endsWith('.txt'))) {
    assert.ok(!readFileSync(path.join('scripts/tdd/fixtures',file),'utf8').includes(process.env.HOME),file);
  }
});

pluginTest('partial XCTest crash after assertion failure is environment, with no count line', ({ exec }) => {
  const r=run('xctest-partial-crash',1);
  assert.equal(r.status,70);
  assert.equal(exec.parseCounts(r.stdout,r.stderr),null);
});
pluginTest('duplicate Swift display names preserve two failed and two skipped tests', ({ exec }) => {
  const r=run('swift-duplicate',1);
  assert.equal(r.status,1,r.stderr);
  assert.deepEqual(exec.parseCounts(r.stdout,r.stderr),{total:4,failed:2,passed:0,skipped:2});
});
test('records the literal filter beside its count line for the output tail', () => {
  const r=run('swift-fail',1,{filter:'sameFilter'});
  assert.match(r.stdout,/swift-lane filter=sameFilter\nTests run: 3, Failures: 1/);
});
pluginTest('two completed fixture streams fail closed', ({ exec }) => {
  const r=run('swift-fail',1,{split:true});
  assert.equal(r.status,70);
  assert.equal(exec.parseCounts(r.stdout,r.stderr),null);
});
pluginTest('crash diagnostics in stderr override a completed failing stdout result', ({ exec }) => {
  const r=run('swift-fail',1,{crashStderr:true});
  assert.equal(r.status,70);
  assert.equal(exec.parseCounts(r.stdout,r.stderr),null);
});

pluginTest('XCTest subtotals without root completion are rejected even without a crash marker', ({ exec }) => {
  const r=run('xctest-fail',1,{truncateRoot:true});
  assert.equal(r.status,70);
  assert.equal(exec.parseCounts(r.stdout,r.stderr),null);
});
pluginTest('a started Swift Testing stream must finish even when XCTest finished elsewhere', ({ exec }) => {
  const r=run('xctest-fail',1,{incompleteSwift:true});
  assert.equal(r.status,70);
  assert.equal(exec.parseCounts(r.stdout,r.stderr),null);
});
test('all discovery probes share the heavy lock and issue-specific integration stays manual', () => {
  const config=JSON.parse(readFileSync('.claude/tdd-guardian/config.json','utf8'));
  // Pure Node lanes run light tests only, so their discovery stays outside the heavy lock.
  const manual393=['app-prebuilt-red','ci-app-compare-node','ci-code-name-node','ci-host-ownership-node','ci-hosted-focus-node','ci-legacy393-node','ci-native-red-node'];
  const heavy=config.lanes.filter(l=>!['release-appcast-node','release-node','name-check-node','module-name-node','docs-node','ci-cache-node','ci-flaky-node','release-tag-ci-node','unit-watchdog-node',...manual393].includes(l.name));
  const probes=heavy.map(l=>l.probeCommand);
  assert.deepEqual(config.lanes.map(l=>l.name).sort(), ['app-prebuilt-red', 'app-red', 'ci-app-compare-node', 'ci-cache-node', 'ci-code-name-node', 'ci-flaky-node', 'ci-host-ownership-node', 'ci-hosted-focus-node', 'ci-legacy393-node', 'ci-native-red-node', 'docs-node', 'integration', 'module-name-node', 'name-check-node', 'release-appcast-node', 'release-node', 'release-tag-ci-node', 'swift-red', 'unit', 'unit-watchdog-node']);
  for(const name of manual393){
    const lane=config.lanes.find(l=>l.name===name);
    assert.deepEqual(lane.gateOn,['manual']);
    assert.equal(lane.probeCommand,'node --version');
  }
  assert.deepEqual(config.lanes.find(l=>l.name==='integration').gateOn, ['manual']);
  assert.deepEqual(config.lanes.find(l=>l.name==='app-red').gateOn, ['manual']);
  const appcast=config.lanes.find(l=>l.name==='release-appcast-node');
  assert.deepEqual(appcast.gateOn, ['manual']);
  assert.equal(appcast.command, 'node scripts/tdd/node-lane.mjs scripts/release/appcast.test.mjs');
  assert.equal(appcast.probeCommand, 'node --version');
  const release=config.lanes.find(l=>l.name==='release-node');
  assert.deepEqual(release.gateOn, ['manual']);
  assert.equal(release.command, 'node scripts/tdd/node-lane.mjs scripts/release/check-entitlements.test.mjs');
  assert.equal(release.probeCommand, 'node --version');
  const names=config.lanes.find(l=>l.name==='name-check-node');
  assert.deepEqual(names.gateOn, ['manual']);
  assert.equal(names.command, 'node scripts/tdd/node-lane.mjs scripts/name-checks/identity-transition.test.mjs');
  assert.equal(names.probeCommand, 'node --version');
  // docs-node is retained for documentation RED receipts; it never discovers native tests.
  const docs=config.lanes.find(l=>l.name==='docs-node');
  assert.deepEqual(docs.gateOn, ['manual']);
  assert.equal(docs.command, 'node scripts/tdd/node-lane.mjs scripts/name-checks/living-docs.test.mjs scripts/name-checks/docs-fix.test.mjs scripts/design/design-prompts.test.mjs');
  assert.equal(docs.probeCommand, 'node --version');
  const modules=config.lanes.find(l=>l.name==='module-name-node');
  assert.deepEqual(modules.gateOn, ['manual']);
  assert.equal(modules.command, 'node scripts/tdd/node-lane.mjs scripts/name-checks/module-name.test.mjs');
  assert.equal(modules.probeCommand, 'node --version');
  const cache=config.lanes.find(l=>l.name==='ci-cache-node');
  assert.deepEqual(cache.gateOn, ['manual']);
  assert.equal(cache.command, 'node scripts/tdd/node-lane.mjs scripts/ci/cache-key.test.mjs');
  assert.equal(cache.probeCommand, 'node --version');
  const tagCI=config.lanes.find(l=>l.name==='release-tag-ci-node');
  assert.deepEqual(tagCI.gateOn, ['manual']);
  assert.equal(tagCI.command, 'node scripts/tdd/node-lane.mjs scripts/release/check-tag-ci.test.mjs scripts/release/release-workflow.test.mjs');
  assert.equal(tagCI.probeCommand, 'node --version');
  assert.match(readFileSync('scripts/tdd/app-lane.mjs','utf8'), /spawnSync\(lock, \["xcrun", "xctest"/);
  assert.ok(probes.every(command=>command.startsWith('scripts/heavy-lock.sh ')));
  assert.ok(heavy.filter(l=>l.name!=='app-red').every(l=>l.probeCommand.startsWith('scripts/heavy-lock.sh swift test ')));
});

pluginTest('crash-related test name and assertion message on stderr remain assertion RED', ({ exec, classifyRedRun }) => {
  const r=run('swift-crash-name-fail',1,{stderr:true});
  assert.equal(r.status,1,r.stderr);
  const counts=exec.parseCounts(r.stdout,r.stderr);
  assert.deepEqual(counts,{total:1,failed:1,passed:0,skipped:0});
  assert.equal(classifyRedRun({status:exec.classify(r.status,r.stdout,r.stderr),testCounts:counts}).kind,'assertion-failure');
});
