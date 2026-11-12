/** Focused integration tests loaded by Xcode into the real Mado.app executable. */
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {randomUUID} from 'node:crypto';
import { runAttestedSync } from './status-channel.mjs';

const lock = fileURLToPath(new URL('../heavy-lock.sh', import.meta.url));
const hostOwner=fileURLToPath(new URL('./hosted-xcode-owner.mjs',import.meta.url));
function inheritedControlStdio(env){
  if(env.PICSEE_HEAVY_LOCK_HELD!=='1')return undefined;
  const control=Number(env.PICSEE_HEAVY_CONTROL_FD);
  if(!Number.isInteger(control)||control<3||control>64)throw new Error('missing inherited heavy-lock control FD');
  const fds=[control];
  if(env.PICSEE_HEAVY_FLOCK_FD){
    const flock=Number(env.PICSEE_HEAVY_FLOCK_FD);
    if(!Number.isInteger(flock)||flock<3||flock>64)throw new Error('invalid inherited heavy-lock flock FD');
    fds.push(flock);
  }
  const stdio=['ignore','pipe','pipe'];
  for(const fd of fds){while(stdio.length<=fd)stdio.push('ignore');stdio[fd]=fd;}
  return stdio;
}
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

const expectedArguments = new Map([
  ['issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount:)', ['0', '1', '2']],
  ['issue527NonCanvasPressPreservesFocusAndImage(target:)', ['"chromeGap"', '"inspector"', '"overlay"', '"sidebar"']],
]);
const resultState = values => values.includes('Failed') ? 'Failed' : values.includes('Skipped') ? 'Skipped' : 'Passed';
const validState = value => ['Passed', 'Failed', 'Skipped'].includes(value);

/** xcresult counts functions at the root and argument executions per device.
 * Validate both levels, including every fixed argument identity, rather than
 * comparing the twelve execution cases to the seven function-test summary. */
export function parseHostedResult(run, summary, tree, expected) {
  const bad = () => ({status:70, reliable:false, count:0, failed:0, skipped:0,
    caseCount:0, caseFailed:0, failureNames:[]});
  const output = `${run?.stdout ?? ''}\n${run?.stderr ?? ''}`;
  if (!run || run.error || run.signal || ![0,65].includes(run.status) ||
      /(?:crashed|exited with[^\n]*signal|Fatal error:|TEST EXECUTE CANCELLED)/i.test(output) ||
      !summary || !tree || !Array.isArray(expected) || !expected.length ||
      expected.some(name => typeof name !== 'string') || new Set(expected).size !== expected.length) return bad();
  const functions = [], executions = [], names = new Set(), failureNames = [];
  let invalid = false;
  const walk = node => {
    if (!node || typeof node !== 'object' || Array.isArray(node)) {invalid=true; return [];}
    if (node.nodeType === 'Test Case') {
      const id = node.nodeIdentifier;
      const name = typeof id === 'string' ? expected.find(name => id === name || id.endsWith('/'+name) || id.endsWith('.'+name)) : null;
      if (!name || names.has(name) || !validState(node.result)) {invalid=true; return [];}
      names.add(name);
      if (node.nodeIdentifierURL !== undefined &&
          node.nodeIdentifierURL !== `test://com.apple.xcode/Mado/MadoHostedFocusTests/${name}`) invalid=true;
      const children = node.children ?? [];
      if (!Array.isArray(children)) {invalid=true; return [];}
      const arguments_ = children.filter(child => child?.nodeType === 'Arguments');
      if (children.some(child => !['Arguments','Failure Message'].includes(child?.nodeType))) invalid=true;
      const domain = expectedArguments.get(name);
      if (domain) {
        const argumentNames = arguments_.map(child => child.name);
        if (argumentNames.length !== domain.length || new Set(argumentNames).size !== domain.length ||
            argumentNames.some(value => !domain.includes(value))) invalid=true;
      } else if (arguments_.length) invalid=true;
      const states = domain ? arguments_.map(child => child.result) : [node.result];
      if (!states.length || states.some(value => !validState(value)) || resultState(states) !== node.result) invalid=true;
      functions.push(node.result); executions.push(...states);
      if (node.result === 'Failed') failureNames.push(name);
      return [node.result];
    }
    const children = node.children ?? [];
    if (!Array.isArray(children)) {invalid=true; return [];}
    const states = children.flatMap(walk);
    if (node.result !== undefined && states.length && node.result !== resultState(states)) invalid=true;
    return states;
  };
  if (!Array.isArray(tree.testNodes)) return bad();
  tree.testNodes.forEach(walk);
  const totals = values => ({passed:values.filter(value => value === 'Passed').length,
    failed:values.filter(value => value === 'Failed').length, skipped:values.filter(value => value === 'Skipped').length});
  const top = totals(functions), cases = totals(executions);
  const matches = (record, totals) => record !== null && typeof record === 'object' && !Array.isArray(record) &&
    ['passed','failed','skipped'].every(key =>
    Number.isSafeInteger(record[`${key}Tests`]) && record[`${key}Tests`] === totals[key]) &&
    (record.expectedFailures === undefined || record.expectedFailures === 0);
  const configurations = summary.devicesAndConfigurations;
  if (configurations !== undefined && (!Array.isArray(configurations) || configurations.length !== 1 ||
      !matches(configurations[0],cases))) invalid=true;
  if (summary.result !== undefined && summary.result !== resultState(functions)) invalid=true;
  if (summary.testFailures !== undefined && (!Array.isArray(summary.testFailures) ||
      (summary.testFailures.length > 0) !== (top.failed > 0))) invalid=true;
  if (invalid || names.size !== expected.length || functions.length !== expected.length || top.skipped || cases.skipped ||
      !executions.length || !Number.isSafeInteger(summary.totalTestCount) || summary.totalTestCount !== functions.length ||
      !matches(summary,top) || (run.status === 0) !== (top.failed === 0) ||
      !output.includes(top.failed ? '** TEST EXECUTE FAILED **' : '** TEST EXECUTE SUCCEEDED **')) return bad();
  return {status:top.failed ? 1 : 0, reliable:true, count:functions.length, ...top,
    caseCount:executions.length, caseFailed:cases.failed, failureNames};
}

export function runHostedAppLane({ spawn = spawnSync, env = process.env, selected = hostedTestNames,
  derivedDataPath = env.PICSEE_APP_DERIVED_DATA_PATH ?? '.build/dd-ci', stdout = s => process.stdout.write(s), stderr = s => process.stderr.write(s),
  evidencePath = '.build/app-lane-hosted-attempt1.log' } = {}) {
  mkdirSync('.build', {recursive:true});
  const directory = mkdtempSync(path.resolve('.build/hosted-'));
  const resultPath = path.join(directory, 'result.xcresult');
  const settings = { encoding:'utf8', maxBuffer:32 * 1024 * 1024, timeout:2100000,
    env:{...env, TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:'1',
      SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:'1'},
    ...(env.PICSEE_HEAVY_LOCK_HELD==='1'?{stdio:inheritedControlStdio(env)}:{}) };
  const processStarted = Date.now();
  let run;
  try {
    const launch=spawn===spawnSync?runAttestedSync:spawn;
    const nativeArgs=['xcodebuild', 'test-without-building', '-scheme', 'Mado',
      '-destination', 'platform=macOS', '-derivedDataPath', derivedDataPath,
      '-parallel-testing-enabled', 'NO', '-resultBundlePath', resultPath,
      ...(selected.length === hostedTestNames.length && selected.every(name => hostedTestNames.includes(name))
        ? ['-only-testing:MadoHostedFocusTests'] : selected.map(name => '-only-testing:MadoHostedFocusTests/' + name))];
    if(spawn===spawnSync&&env.MADO_HOST_OWNERSHIP_REQUIRED==='1'){
      const token=env.MADO_TEST_RUN_TOKEN??randomUUID();
      settings.env.MADO_TEST_RUN_TOKEN=token;
      settings.env.TEST_RUNNER_MADO_TEST_RUN_TOKEN=token;
      settings.env.MADO_HOST_EXECUTABLE=env.MADO_HOST_EXECUTABLE??path.resolve(derivedDataPath,
        'Build/Products/Debug/Mado.app/Contents/MacOS/Mado');
      run=launch(lock,[process.execPath,hostOwner,...nativeArgs],settings);
    }else run=launch(lock,nativeArgs,settings);
  } catch (error) { run = {error, status:null}; }
  stdout(run.stdout ?? ''); stderr(run.stderr ?? '');
  const raw = `${run.stdout ?? ''}\n${run.stderr ?? ''}`;
  writeFileSync(path.join(directory, 'execution.log'), raw);
  writeFileSync(path.join(directory, 'process.json'), JSON.stringify({version:1, status:run.status ?? null,
    signal:run.signal ?? null, error:run.error?.message ?? null, selected, derivedDataPath, resultPath,
    ...(spawn===spawnSync&&env.MADO_HOST_OWNERSHIP_REQUIRED==='1'
      ?{hostCleanup:run.status===0||run.status===1||run.status===65?'complete':'incomplete'}:{}),
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
