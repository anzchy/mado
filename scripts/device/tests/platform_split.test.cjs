// The explicit inventory is also checked against the actual, unfiltered CI commands.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '../../..');
const lanes = {
  portablePython: ['fix1_test.py', 'fix2_test.py', 'launch_contract_test.py',
    'panel_choose_test.py', 'process_query_test.py', 'xcode_selection_test.py'],
  portableNode: ['device.test.cjs', 'platform_split.test.cjs'],
  macosNode: ['macos.test.cjs'],
};
const legacyCases = [
  "cleanup kills only recorded PID, spares same-name process",
  "cleanup refuses executable outside recorded bundle",
  "doctor emits exactly one PASS line per check and identifies the empty window title",
  "doctor accepts exactly one window titled as a fixture file and identifies it",
  "doctor rejects an unrecorded file title and keeps zero windows distinct",
  "doctor emits one result per check and fails on each individual defect",
  "window lookup uses PID even with identical or misleading owner names",
  "sandbox parser reads explicit XML and rejects typed text",
  "screenshot validation rejects a black image and accepts visible window pixels",
  "doctor keeps permission errors on one verdict line",
  "key helper rejects named or multi-character keys before touching a run",
  "fix-round-1 offline behavioral regressions",
  "fix-round-2 report storage and re-sign regressions",
  "Xcode selection uses the locked build from fake app bundles"
];

function inventory(dir = __dirname, prefix = '') {
  return fs.readdirSync(dir, {withFileTypes: true}).flatMap(entry => {
    const name = prefix + entry.name;
    if (entry.isDirectory()) return inventory(path.join(dir, entry.name), name + '/');
    return /(?:_test\.py|^test_.*\.py|\.test\.(?:cjs|mjs|js))$/.test(name) ? [name] : [];
  });
}
function assertPartition(files, groups = lanes) {
  const assigned = Object.values(groups).flat();
  const duplicates = assigned.filter((name, index) => assigned.indexOf(name) !== index);
  assert.equal(duplicates.length, 0, `duplicate lane assignment: ${duplicates}`);
  const unknown = files.filter(name => !assigned.includes(name));
  assert.equal(unknown.length, 0, `unassigned test files: ${unknown}`);
  assert.deepEqual([...assigned].sort(), [...files].sort(), 'assigned files must exist');
}
function read(name) { return fs.readFileSync(path.join(root, name), 'utf8'); }
function job(file, id) {
  const section = read(file).split(`  ${id}:\n`)[1];
  assert.ok(section, `missing job ${id}`);
  return section.split(/^  [\w-]+:\s*$/m)[0];
}
function step(body, name) {
  const sections = body.split(/^      - name: /m).slice(1);
  const matches = sections.filter(section => section.split('\n')[0] === name);
  assert.equal(matches.length, 1, `expected exactly one step: ${name}`);
  assert.doesNotMatch(matches[0], /^        (?:if|continue-on-error):/m);
  return matches[0];
}
function runBlock(section) {
  const block = section.match(/^        run: \|\n((?:          .*\n?)+)/m);
  if (block) return block[1].replace(/^          /gm, '').trimEnd();
  const line = section.match(/^        run: (.+)$/m);
  assert.ok(line, 'missing runnable step');
  return line[1];
}
function portableStep() {
  return step(job('.github/workflows/pr-body.yml', 'agent-tests'), 'Test portable device tools');
}
function caseNames(file) {
  if (!fs.existsSync(path.join(__dirname, file))) return [];
  return [...fs.readFileSync(path.join(__dirname, file), 'utf8')
    .matchAll(/^test\('([^'\n]+)'/gm)].map(match => match[1]);
}

test('every device test file and case is assigned to exactly one unfiltered CI lane', () => {
  assertPartition(inventory());
  const portable = runBlock(portableStep());
  assert.equal(portable.split('\n')[0],
    "python3 -m unittest discover -s scripts/device/tests -p '*_test.py'");
  assert.deepEqual(lanes.portablePython.sort(), inventory().filter(name => name.endsWith('_test.py')).sort());
  assert.equal(portable.split('\n')[1],
    'node --test ' + lanes.portableNode.map(name => 'scripts/device/tests/' + name).join(' '));
  assert.equal(portable.split('\n').length, 2, 'no filtered or masked collection');
  const nativeJob = job('.github/workflows/ci.yml', 'package-tests');
  assert.match(nativeJob, /^    name: Package tests \(non-UI\)$/m);
  assert.match(nativeJob, /^    runs-on: macos-26$/m);
  assert.equal(runBlock(step(nativeJob, 'Test macOS device tools')),
    'node --test scripts/device/tests/macos.test.cjs');
  const names = [...nativeJob.matchAll(/^      - name: (.+)$/gm)].map(match => match[1]);
  const at = names.indexOf('Watchdog script tests');
  assert.deepEqual(names.slice(at, at + 3),
    ['Watchdog script tests', 'Test macOS device tools', 'Set up Xcode']);
  // Whole files are passed to runners without name filters: every declared case
  // inherits its file's sole lane. Preserve all 14 original Node names as well.
  const original = [...caseNames('device.test.cjs'), ...caseNames('macos.test.cjs')];
  assert.deepEqual(original.sort(), [...legacyCases].sort());
  assert.equal(caseNames('macos.test.cjs').length, 3);
  assert.ok(caseNames('platform_split.test.cjs').length > 0);
  assert.doesNotMatch(read('scripts/device/tests/device.test.cjs'), /sips|\/usr\/bin\/osascript|function dummy\(/);
  for (const name of lanes.portableNode.concat(lanes.macosNode)) {
    assert.doesNotMatch(read('scripts/device/tests/' + name), /\btest\.(?:skip|todo|only)\s*\(/);
  }
});

test('inventory refuses future unassigned test files and duplicate lane assignments', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'device-inventory-'));
  try {
    for (const name of Object.values(lanes).flat()) fs.writeFileSync(path.join(dir, name), '');
    for (const name of ['unassigned_test.py', 'unassigned.test.cjs', 'unassigned.test.mjs']) {
      fs.writeFileSync(path.join(dir, name), '');
      assert.throws(() => assertPartition(inventory(dir)), /unassigned test files: unassigned/);
      fs.unlinkSync(path.join(dir, name));
    }
    for (const duplicate of [
      {...lanes, macosNode: [...lanes.macosNode, lanes.portableNode[0]]},
      {...lanes, portablePython: [...lanes.portablePython, lanes.portablePython[0]]},
    ]) assert.throws(() => assertPartition(inventory(dir), duplicate), /duplicate lane assignment/);
    assertPartition(inventory(dir));
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

test('Ubuntu tooling explicitly installs device dependencies and preserves existing agent tests', () => {
  const body = job('.github/workflows/pr-body.yml', 'agent-tests');
  assert.match(body, /^    runs-on: ubuntu-latest$/m);
  assert.match(body, /uses: actions\/setup-node@/);
  assert.match(body, /node-version: 22/);
  const install = runBlock(step(body, 'Install portable device test tools'));
  assert.match(install, /sudo apt-get update/);
  assert.match(install, /sudo apt-get install[^\n]*\bpython3\b[^\n]*\bgit\b[^\n]*\bzsh\b/);
  assert.match(portableStep(), /^        working-directory: pr-head$/m);
  assert.equal(runBlock(step(body, 'Test agent tooling')),
    'node --test scripts/agents/*.test.mjs scripts/perf/*.test.mjs scripts/ledger/*.test.mjs scripts/tdd/*.test.mjs');
});

// Execute the REAL workflow block in a fixture checkout, with real runners.
// These tests never execute themselves recursively: the fixture files are tiny
// independent node:test / unittest suites at the workflow's exact paths.
function fixtureRun(pythonFails, nodeFails) {
  const script = runBlock(portableStep());
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'device-step-'));
  const tests = path.join(dir, 'scripts/device/tests');
  fs.mkdirSync(tests, {recursive: true});
  try {
    fs.writeFileSync(path.join(tests, 'propagation_test.py'),
      'import unittest\nclass Propagation(unittest.TestCase):\n' +
      ' def test_fixture(self):\n  print("PYTHON_FIXTURE_RAN")\n' +
      `  self.assertTrue(${pythonFails ? 'False' : 'True'}, "injected Python failure")\n`);
    for (const [index, name] of lanes.portableNode.entries()) {
      fs.writeFileSync(path.join(tests, name),
        "const test=require('node:test'); const assert=require('node:assert/strict');\n" +
        `test('node fixture ${index}',()=>{console.log('NODE_FIXTURE_RAN');` +
        `assert.ok(${nodeFails && index === 0 ? 'false' : 'true'}, 'injected Node failure');});\n`);
    }
    // A fresh CI shell is not a child of node:test. Clear its runner marker so
    // nested Node CLI invocations really collect and run the fixture files.
    const env = {...process.env};
    delete env.NODE_TEST_CONTEXT;
    return spawnSync('bash', ['--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script],
      {cwd: dir, env, encoding: 'utf8', timeout: 30000});
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
}
function assertPassing(result) {
  assert.equal(result.status, 0, result.stdout + result.stderr + (result.error || ''));
  assert.match(result.stdout, /PYTHON_FIXTURE_RAN/);
  assert.match(result.stdout, /NODE_FIXTURE_RAN/);
  assert.match(result.stderr, /Ran 1 test/);
}

test('actual Agent tooling device step executes passing Python and Node fixtures', () => {
  assertPassing(fixtureRun(false, false));
});

test('a failing Python device test fails the actual Agent tooling step', () => {
  const failed = fixtureRun(true, false);
  assert.equal(failed.status, 1, failed.stdout + failed.stderr);
  assert.match(failed.stderr, /injected Python failure/);
  assert.doesNotMatch(failed.stdout, /NODE_FIXTURE_RAN/, 'CI fails before later commands');
  assertPassing(fixtureRun(false, false));
});

test('a failing Node device test fails the actual Agent tooling step after Python passes', () => {
  const failed = fixtureRun(false, true);
  assert.equal(failed.status, 1, failed.stdout + failed.stderr);
  assert.match(failed.stdout, /PYTHON_FIXTURE_RAN/);
  assert.match(failed.stdout + failed.stderr, /injected Node failure/);
  assertPassing(fixtureRun(false, false));
});
