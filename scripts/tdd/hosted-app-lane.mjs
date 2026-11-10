/** Focused integration tests loaded by Xcode into the real Mado.app executable. */
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const lock = fileURLToPath(new URL('../heavy-lock.sh', import.meta.url));
export const hostedTestNames = [
  'issue393RunsInsideRealAppWithLiveDispatchAndActivation()',
  'issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount:)',
  'issue527InspectorCloseCanvasPressPans()',
  'issue527NonCanvasPressPreservesFocusAndImage(target:)',
  'issue527InactiveFirstClickKeepsFocusConsistent()',
  'issue564KeyWindowFixtureHandlesDelayedAndNeverKey()',
  'retry442NativeKeyboardMatrix()',
];
export const hostedTestIDs = hostedTestNames.map(name => `MadoHostedFocusTests.${name}`);

/** Trust both xcresult's completed tree and totals, never the command's exit code alone. */
export function parseHostedResult(run, summary, tree, expected) {
  const bad = () => ({ status: 70, reliable: false, count: 0, failed: 0, skipped: 0, failureNames: [] });
  const output = `${run?.stdout ?? ''}\n${run?.stderr ?? ''}`;
  if (!run || run.error || run.signal || ![0, 65].includes(run.status) ||
      /(?:crashed|exited with[^\n]*signal|Fatal error:|TEST EXECUTE CANCELLED)/i.test(output) ||
      !summary || !tree || !expected?.length || new Set(expected).size !== expected.length) return bad();
  const names = [], failures = [];
  let invalid = false, passed = 0, failed = 0, skipped = 0;
  const walk = node => {
    if (!node || typeof node !== 'object') { invalid = true; return; }
    if (node.nodeType === 'Test Case') {
      const id = node.nodeIdentifier;
      const name = expected.find(name => id === name || id?.endsWith('/' + name) || id?.endsWith('.' + name));
      if (!name || names.includes(name)) { invalid = true; return; }
      names.push(name);
      // Parameterized children are execution cases; the parent is the selected test identity.
      const results = node.children?.length ? node.children.map(child => child.result) : [node.result];
      for (const result of results) {
        if (result === 'Passed') passed++;
        else if (result === 'Failed') { failed++; failures.push(name); }
        else if (result === 'Skipped') skipped++;
        else invalid = true;
      }
      return;
    }
    if (node.children) {
      if (!Array.isArray(node.children)) invalid = true;
      else node.children.forEach(walk);
    }
  };
  if (!Array.isArray(tree.testNodes)) return bad();
  tree.testNodes.forEach(walk);
  const total = passed + failed + skipped;
  if (invalid || names.length !== expected.length || skipped || !total ||
      ![summary.totalTestCount, summary.passedTests, summary.failedTests, summary.skippedTests].every(Number.isSafeInteger) ||
      summary.totalTestCount !== total || summary.passedTests !== passed || summary.failedTests !== failed ||
      summary.skippedTests !== skipped || (run.status === 0) !== (failed === 0) ||
      !output.includes(failed ? '** TEST EXECUTE FAILED **' : '** TEST EXECUTE SUCCEEDED **')) return bad();
  return { status: failed ? 1 : 0, reliable: true, count: total, failed, skipped, failureNames: [...new Set(failures)] };
}

export function runHostedAppLane({ spawn = spawnSync, env = process.env, selected = hostedTestNames,
  derivedDataPath = env.PICSEE_APP_DERIVED_DATA_PATH ?? '.build/dd-ci', stdout = s => process.stdout.write(s), stderr = s => process.stderr.write(s),
  evidencePath = '.build/app-lane-hosted-attempt1.log' } = {}) {
  mkdirSync('.build', {recursive:true});
  const directory = mkdtempSync(path.resolve('.build/hosted-'));
  const resultPath = path.join(directory, 'result.xcresult');
  const settings = { encoding:'utf8', maxBuffer:32 * 1024 * 1024, timeout:2100000,
    env:{...env, TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:'1',
      SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:'1'} };
  const processStarted = Date.now();
  let run;
  try {
    run = spawn(lock, ['xcodebuild', 'test-without-building', '-scheme', 'Mado',
      '-destination', 'platform=macOS', '-derivedDataPath', derivedDataPath,
      '-parallel-testing-enabled', 'NO', '-resultBundlePath', resultPath,
      ...(selected.length === hostedTestNames.length && selected.every(name => hostedTestNames.includes(name))
        ? ['-only-testing:MadoHostedFocusTests'] : selected.map(name => '-only-testing:MadoHostedFocusTests/' + name))], settings);
  } catch (error) { run = {error, status:null}; }
  stdout(run.stdout ?? ''); stderr(run.stderr ?? '');
  const raw = `${run.stdout ?? ''}\n${run.stderr ?? ''}`;
  writeFileSync(path.join(directory, 'execution.log'), raw);
  writeFileSync(path.join(directory, 'process.json'), JSON.stringify({version:1, status:run.status ?? null,
    signal:run.signal ?? null, error:run.error?.message ?? null, selected, derivedDataPath, resultPath,
    wallMilliseconds:Date.now()-processStarted}, null, 2) + '\n');
  const readResult = kind => {
    const extraction = spawn('xcrun', ['xcresulttool', 'get', 'test-results', kind, '--path', resultPath],
      { encoding:'utf8', maxBuffer:32 * 1024 * 1024, timeout:120000, env });
    if (extraction.error || extraction.signal || extraction.status !== 0) throw new Error('missing or unreadable hosted ' + kind);
    const value = JSON.parse(extraction.stdout);
    writeFileSync(path.join(directory, kind + '.json'), JSON.stringify(value, null, 2));
    return value;
  };
  let parsed;
  try { parsed = parseHostedResult(run, readResult('summary'), readResult('tests'), selected); }
  catch (error) { stderr(`hosted-app-lane: ${error.message}\n`); parsed = parseHostedResult(run, null, null, selected); }
  if (parsed.status !== 0) {
    mkdirSync(path.dirname(evidencePath), {recursive:true}); writeFileSync(evidencePath, raw);
  }
  if (!parsed.reliable) stderr('hosted-app-lane: no reliable completed hosted App result\n');
  else {
    if (parsed.failed) stdout(`app-lane: first-attempt failures: ${parsed.failureNames.join(', ')}\n`);
    stdout(`hosted-app-lane Tests run: ${parsed.count}, Failures: ${parsed.failed}, Errors: 0, Skipped: 0\n`);
  }
  stdout(`hosted-app-lane result=${resultPath}\n`);
  return {...parsed,resultPath};
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  process.exitCode = runHostedAppLane().status;
