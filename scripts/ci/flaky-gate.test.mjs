import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseAppResult, runAppLane } from '../tdd/app-lane.mjs';
import { classifyFlaky } from './flaky-gate.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const fixtures = ['a1','a4-diagnostic','a5'].map(id => readFileSync(new URL(`./fixtures/app-${id}.txt`, import.meta.url),'utf8'));
const recordedA4 = readFileSync(new URL('./fixtures/app-a4.txt', import.meta.url), 'utf8');
const names = ['t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves','sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild','t229Fix2RecoveryFollowsRootMovedWhileReadable'];
const result = (stdout=fixtures[0], extra={}) => ({stdout,stderr:'',status:1,signal:null,...extra});
const issueLines = fixtures.map(s=>s.split('\n').find(l=>l.includes('recorded an issue')));
const endings = fixtures.map(s=>s.split('\n').find(l=>l.startsWith('✘ Test ')&&l.includes(' failed after ')));
const header = "Test Suite 'All tests' passed at 2026-11-03 00:00:00.000.\n Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds\n◇ Test run started.\n";
// Explicit derived mutations of the recordings, not new native runs.
const combined = header + issueLines.join('\n')+'\n'+endings.join('\n')+'\n✘ Test run with 3 tests in 1 suite failed after 180.000 seconds with 3 issues.\n';
const passing = header+'✔ Test passing() passed after 0.001 seconds.\n➜ Test skipped() skipped: "fixture"\n✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n';
const pass = result(passing,{status:0});
const eligible = r=>assert.equal(classifyFlaky(r).decision,'retry-eligible');
const denied = r=>assert.equal(classifyFlaky(r).decision,'fail');
function harness(sequence, options={}) {
  let calls=0, stdout='',stderr='';
  const evidencePath=path.join(mkdtempSync(path.join(tmpdir(),'mado-i424-')),'app-lane-attempt1.log');
  const status=runAppLane({spawn:()=>{assert.ok(calls<sequence.length,'unexpected extra attempt');return sequence[calls++];},env:{},evidencePath,stdout:s=>stdout+=s,stderr:s=>stderr+=s,...options});
  return {status,calls,stdout,stderr,evidencePath};
}

test('each recorded or derived known failure matches exact name and issue',()=>{
  fixtures.forEach((text,i)=>{
    assert.equal(parseAppResult(result(text)).reliable,true);
    const got=classifyFlaky(result(text));
    assert.equal(got.decision,'retry-eligible');
    assert.deepEqual(got.names,[names[i]]);
    assert.deepEqual(got.issues,[i===1?425:379]);
  });
});
test('derived A4 diagnostic fixture changes only the recorded issue line', () => {
  const recordedIssue = recordedA4.split('\n').find(line => line.includes('recorded an issue'));
  assert.equal(fixtures[1].replace(issueLines[1], recordedIssue), recordedA4);
  assert.match(issueLines[1], /; state: rows=\[.+; at B click: rows=\[.+; after Cancel: rows=\[/);
});
test('A4 diagnostic fixture issue sites agree with the final live Swift source', () => {
  const source = readFileSync(path.join(root, 'AppTests/SidebarTreeControllerTests.swift'), 'utf8').split('\n');
  const signature = parseAppResult(result(fixtures[1])).issues[0].signature;
  const location = /^SidebarTreeControllerTests\.swift:(\d+):2: Caught error: wait timed out after 100\.0 seconds at MadoAppTests\/SidebarTreeControllerTests\.swift:(\d+) \(sidebar stage: restore A tree\); state: /.exec(signature);
  assert.ok(location, 'derived fixture represents the diagnostic restore-A wait failure');
  const annotation = source.findIndex(line => line.includes(`@Test(`) && line.includes(`func ${names[1]}()`));
  const restore = source.findIndex(line => line.includes('try await waitForSidebar("restore A tree", state: state)'));
  assert.ok(annotation >= 0 && restore >= 0, 'both native issue sites exist');
  assert.equal(Number(location[1]), annotation + 1);
  assert.equal(Number(location[2]), restore + 1);
});
test('A4 diagnostics do not authorize other stages, locations, errors, or missing state', () => {
  for (const text of [
    fixtures[1].replace('restore A tree', 'load B tree'),
    fixtures[1].replace('SidebarTreeControllerTests.swift:305:2', 'SidebarTreeControllerTests.swift:306:2'),
    fixtures[1].replace('SidebarTreeControllerTests.swift:389 (sidebar stage:', 'SidebarTreeControllerTests.swift:390 (sidebar stage:'),
    fixtures[1].replace('Caught error: wait timed out after 100.0 seconds', 'Caught error: unexpected folder failure'),
    fixtures[1].replace(/; state: rows=.*$/m, ''),
    fixtures[1].replace(/; state: rows=.*$/m, '; state: '),
  ]) {
    assert.equal(parseAppResult(result(text)).reliable, true);
    denied(result(text));
  }
});
test('A4 old stale signature and 180-second time-limit variant remain denied', () => {
  const timeLimit = fixtures[1].replace(issueLines[1],
    `✘ Test ${names[1]}() recorded an issue at SidebarTreeControllerTests.swift:305:2: Time limit was exceeded: 180.000 seconds`);
  for (const text of [recordedA4, timeLimit]) {
    assert.equal(parseAppResult(result(text)).reliable, true);
    denied(result(text));
  }
});
test('A4 cannot hide an additional foreign issue on the same failed test', () => {
  const foreignIssue = `✘ Test ${names[1]}() recorded an issue at Other.swift:1:1: Expectation failed`;
  const text = fixtures[1].replace(issueLines[1], `${issueLines[1]}\n${foreignIssue}`)
    .replaceAll('with 1 issue.', 'with 2 issues.');
  const parsed = parseAppResult(result(text));
  assert.equal(parsed.reliable, true);
  assert.equal(parsed.unattributedIssues, false);
  assert.equal(parsed.issues.length, 2);
  denied(result(text));
});
test('all-known complete subset allows multiple failures',()=>{
  const got=classifyFlaky(result(combined));
  assert.equal(got.decision,'retry-eligible');assert.deepEqual(got.names,names);assert.deepEqual(got.issues,[379,425]);
});
test('unknown, suffix, A2 and A3 names are denied',()=>{
  for(const name of ['unknown',names[0]+'Suffix','t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores','issue281RetryAfterFailedReadShowsTheReadingFooter']) denied(result(fixtures[0].replaceAll(names[0],name)));
});
test('name match alone cannot borrow a different signature',()=>{
  for(const text of [fixtures[0].replace('180.000 seconds','181.000 seconds'),fixtures[0].replace('LostAccessRecoveryTests.swift:1315:13','Other.swift:1315:13'),fixtures[0].replace(':1315:13',':459:13'),fixtures[1].replace('restore A tree','load B tree')]) denied(result(text));
});
test('every issue must match, including extra foreign and orphan issues',()=>{
  for(const text of [combined.replace('180.000 seconds','other failure'),combined.replaceAll(names[2],'unknown'),combined.replace(issueLines[0],issueLines[0]+'\n'+issueLines[0].replace('180.000 seconds','unexpected')),combined.replace(issueLines[0],issueLines[0]+'\n✘ Test unknown() recorded an issue at Other.swift:1:1: Expectation failed'),combined.replace(issueLines[0],issueLines[0]+'\n✘ Suite Something recorded an issue at Other.swift:1:1: Expectation failed')]) denied(result(text));
});
test('completeness guards deny unreliable results',()=>{
  const s=fixtures[0];
  const variants=[s.replace(/Test Suite 'All tests' passed at .+\n/,''),s.replace(/.*Executed 0 tests.*\n/,''),s.replace('◇ Test run started.',''),s.replace(/✘ Test run with .+\n/,''),s+'◇ Test run started.\n',s+s.split('\n').find(l=>l.startsWith('✘ Test run with '))+'\n',s.replace('with 187 tests','with 0 tests'),s.replace('with 187 tests','with 188 tests'),s.replace(/✘ Test run with (.+) failed after/,'✔ Test run with $1 passed after'),''];
  for(const text of variants){const r=result(text);assert.equal(parseAppResult(r).status,70);denied(r);}
  for(const extra of [{status:0},{status:70},{status:null,signal:'SIGTERM'},{error:Error('spawn failed')}]){const r=result(s,extra);assert.equal(parseAppResult(r).status,70);denied(r);}
  assert.equal(parseAppResult(result(passing)).status,70);
});
test('crash diagnostics in either stream deny completed-looking output',()=>{
  for(const line of ['error: Exited with signal code 5',"error: Process '/SCRATCH/test' exited with unexpected signal code 5",'Fatal error: fixture trap','File.swift:4:2: Fatal error: fixture trap','Segmentation fault: 11',"Test Suite 'All tests' crashed.",'✘ Test known() crashed after 0.001 seconds.']){
    denied(result(fixtures[0]+'\n'+line));denied(result(fixtures[0],{stderr:line}));
  }
});
test('crash or signal words in passing test names are not diagnostics',()=>{
  eligible(result(combined.replace('with 3 tests','with 4 tests').replace('◇ Test run started.','◇ Test run started.\n✔ Test CrashSignalHandler() passed after 0.001 seconds.')));
});
test('complete pass with skip counts is reliable but never retry eligible',()=>{
  const got=parseAppResult(pass);assert.equal(got.status,0);assert.equal(got.count,2);assert.equal(got.skipped,1);denied(pass);
});
test('unmatched additions deny eligibility regardless of interleaving',()=>{
  for(let i=0;i<fixtures.length;i++){
    eligible(result(fixtures[i]));
    for(const order of [issueLines.join('\n'),[...issueLines].reverse().join('\n')]) {
      const control=header+order+'\n'+endings.join('\n')+'\n✘ Test run with 3 tests in 1 suite failed after 180.000 seconds with 3 issues.\n';
      eligible(result(control));denied(result(control.replaceAll(names[i],`unknown${i}`)));
      denied(result(control.replace('◇ Test run started.','◇ Test run started.\n✘ Test unknown() recorded an issue at File.swift:1:1: bad')));
    }
  }
});
test('known failure retries once, preserves first bytes and prints names',()=>{
  const first=result(fixtures[1],{stderr:'first stderr marker\n'}),h=harness([first,pass]);
  assert.equal(h.status,0);assert.equal(h.calls,2);
  assert.match(h.stdout,new RegExp(`app-lane: known flaky ${names[1]} \\(#425\\); retrying once`));
  assert.match(h.stdout,new RegExp(`app-lane: first-attempt failures: ${names[1]}`));
  assert.equal(h.stdout.match(/app-lane: first-attempt failures:/g).length,1);
  assert.match(h.stdout,/Tests run: 2, Failures: 0, Errors: 0, Skipped: 1/);
  assert.equal(readFileSync(h.evidencePath,'utf8'),first.stdout+'\n'+first.stderr);
  assert.ok(h.stdout.includes(first.stdout)&&h.stdout.includes(passing));assert.ok(h.stderr.includes(first.stderr));
});
test('every second attempt determines status, never a third',()=>{
  const second=[result(),result(fixtures[2]),result(fixtures[0].replaceAll(names[0],'unknown')),pass,result('',{status:70}),result(fixtures[0],{signal:'SIGABRT',status:null}),result(fixtures[0],{error:Error('failure')})];
  for(const r of second){const h=harness([result(),r,pass]);assert.equal(h.calls,2);assert.equal(h.status,parseAppResult(r).status);assert.equal((h.stdout.match(/retrying once/g)||[]).length,1);assert.equal(readFileSync(h.evidencePath,'utf8'),fixtures[0]+'\n');if(h.status===70)assert.doesNotMatch(h.stdout,/Tests run:/);}
});
test('disable flag, success and ineligible failures never retry',()=>{
  const cases=[pass,result(fixtures[0].replaceAll(names[0],'unknown')),result(fixtures[0].replace('180.000 seconds','other')),result('',{status:70}),result(fixtures[0],{signal:'SIGKILL',status:null})];
  for(const r of cases){const h=harness([r,pass]);assert.equal(h.status,parseAppResult(r).status);assert.equal(h.calls,1);assert.doesNotMatch(h.stdout,/retrying once/);}
  const h=harness([result(),pass],{env:{PICSEE_APP_LANE_NO_RETRY:'1'}});assert.equal(h.status,1);assert.equal(h.calls,1);assert.doesNotMatch(h.stdout,/retrying once/);assert.match(h.stdout,/first-attempt failures:/);
});
test('real Node child process transports recorded output, stderr and exit status',()=>{
  let n=0;const text=fixtures[1], h=harness([],{spawn:()=>spawnSync(process.execPath,['-e',`process.stdout.write(${JSON.stringify(n++?passing:text)});process.stderr.write('real stderr\\n');process.exit(${n===1?1:0})`],{encoding:'utf8'})});
  assert.equal(h.status,0);assert.equal(n,2);assert.equal(readFileSync(h.evidencePath,'utf8'),text+'\nreal stderr\n');assert.match(h.stderr,/real stderr/);
});
test('evidence-write ENOTDIR is visible and prevents retry',()=>{
  const dir=mkdtempSync(path.join(tmpdir(),'mado-i424-enotdir-')), parent=path.join(dir,'file');writeFileSync(parent,'intact');
  const h=harness([result(),pass],{evidencePath:path.join(parent,'attempt1.log')});assert.equal(h.status,70);assert.equal(h.calls,1);assert.match(h.stderr,/app-lane:.*(?:preserve|evidence|attempt1)/);assert.doesNotMatch(h.stdout,/retrying once/);assert.equal(readFileSync(parent,'utf8'),'intact');
});
test('real module imports do not launch native tools',()=>{
  const r=spawnSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(new URL('../tdd/app-lane.mjs',import.meta.url).href)});await import(${JSON.stringify(new URL('./flaky-gate.mjs',import.meta.url).href)});`],{encoding:'utf8',cwd:root,env:{PATH:''}});assert.equal(r.status,0,r.stderr);assert.equal(r.stdout,'');assert.equal(r.stderr,'');
});
test('flaky gate CLI reads recording and explicit exit status',()=>{
  const r=spawnSync(process.execPath,['scripts/ci/flaky-gate.mjs','scripts/ci/fixtures/app-a1.txt','1'],{cwd:root,encoding:'utf8'});assert.equal(r.status,0,r.stderr);assert.equal(r.stdout.trim(),'retry-eligible');
  const no=spawnSync(process.execPath,['scripts/ci/flaky-gate.mjs','scripts/ci/fixtures/app-a1.txt','70'],{cwd:root,encoding:'utf8'});assert.equal(no.status,1);assert.equal(no.stdout.trim(),'fail');
});
test('XCTest root failures and anonymous issues cannot hide behind known Swift failure',()=>{
  denied(result(fixtures[0].replace('with 0 failures (0 unexpected)','with 1 failure (0 unexpected)')));
  denied(result(fixtures[0].replace('with 0 failures (0 unexpected)','with 0 failures (1 unexpected)')));
  denied(result(fixtures[0]+'\n✘ Test run recorded an issue: anonymous\n'));
});
test('flaky gate CLI refuses missing metadata, invalid status and unreadable log',()=>{
  for(const args of [[],['scripts/ci/fixtures/app-a1.txt'],['scripts/ci/fixtures/app-a1.txt','garbage'],['/does-not-exist/i424.log','1']]){
    const r=spawnSync(process.execPath,['scripts/ci/flaky-gate.mjs',...args],{cwd:root,encoding:'utf8'});assert.equal(r.status,1);assert.equal(r.stdout,'fail\n');
  }
});
test('injected process boundary uses locked native command and preserves environment',()=>{
  let command,args,options;
  const h=harness([pass],{env:{PICSEE_APP_LANE_NO_RETRY:'1',EXAMPLE:'kept'},spawn:(...values)=>{[command,args,options]=values;return pass;}});
  assert.equal(h.status,0);assert.match(command,/scripts\/heavy-lock\.sh$/);assert.deepEqual(args,['xcrun','xctest','.build/dd-ci/Build/Products/Debug/MadoAppTests.xctest']);assert.equal(options.env.EXAMPLE,'kept');assert.equal(options.env.SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH,'1');
});
test('default output streams emit final result using recorded Node transport',()=>{
  const code=`import {runAppLane} from ${JSON.stringify(new URL('../tdd/app-lane.mjs',import.meta.url).href)}; process.exitCode=runAppLane({spawn:()=>(${JSON.stringify({...pass,stderr:'default-stderr-marker\n'})})});`;
  const r=spawnSync(process.execPath,['--input-type=module','-e',code],{encoding:'utf8',cwd:root});assert.equal(r.status,0,r.stderr);assert.ok(r.stdout.includes(passing));assert.match(r.stdout,/Tests run: 2, Failures: 0, Errors: 0, Skipped: 1/);assert.equal(r.stderr,'default-stderr-marker\n');
});

for (const diagnostic of [
  'error: Exited with unexpected signal code 9',
  "error: Process '/SCRATCH/test' exited with unexpected signal code 9",
  'error: Exited with signal code 9',
  'error: Exited with signal SIGKILL',
  "error: Process '/SCRATCH/test' exited with unexpected signal SIGKILL",
]) {
  for (const stream of ['stdout', 'stderr']) {
    test(`signal exit refuses retry: ${stream}: ${diagnostic}`, () => {
      const run = stream === 'stdout'
        ? result(fixtures[0] + '\n' + diagnostic + '\n')
        : result(fixtures[0], { stderr: diagnostic + '\n' });
      denied(run);
      const h = harness([run, pass]);
      assert.equal(h.status, 70);
      assert.equal(h.calls, 1);
      assert.doesNotMatch(h.stdout, /retrying once|Tests run:/);
      assert.equal(readFileSync(h.evidencePath, 'utf8'), run.stdout + '\n' + run.stderr);
    });
  }
}

test('first App attempt upload is nonfatal while App tests retain their exit status', () => {
  const workflow = readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');
  const steps = workflow.split(/^      - name: /m);
  const upload = steps.find(step => step.startsWith('Upload first App attempt\n'));
  const lane = steps.find(step => step.startsWith('Run App tests\n'));
  assert.ok(upload, 'first-attempt upload step exists');
  assert.match(upload, /^        continue-on-error: true$/m);
  assert.match(upload, /^        if: always\(\)$/m);
  assert.match(upload, /^        uses: actions\/upload-artifact@[a-f0-9]{40}/m);
  assert.match(upload, /^          path: \.build\/app-lane-attempt1\.log$/m);
  assert.ok(lane, 'App lane step exists');
  assert.match(lane, /^        run: node scripts\/tdd\/app-lane\.mjs$/m);
  assert.doesNotMatch(lane, /continue-on-error:/);
});
