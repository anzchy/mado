const {test,after}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const base=path.resolve(__dirname,'..');
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'mado-device-'));
after(()=>fs.rmSync(scratch,{recursive:true,force:true}));
function call(name,args){return spawnSync(path.join(base,name+'.sh'),args,{encoding:'utf8'});}
const checks=['build-sha','bundle-id','signature-team','signature-valid','sandbox','process-bundle','fresh-sources','single-instance','window','launch-log','machine','fixtures'];
function fixture(){return {expectedSHA:'abc1234',sha:'abc1234',bundleID:'io.github.anzchy.mado',team:'GRT84NAK4T',signatureValid:true,sandbox:true,processMatches:true,fresh:true,alone:true,windows:[{title:'Mado'}],fixtureNames:['orientation-1.tiff','nested/alpha-gradient.png'],log:'Mado launch git=abc1234',machineMatches:true,fixturesIntact:true};}
function doctor(input,name){const file=path.join(scratch,name+'.json');fs.writeFileSync(file,JSON.stringify(input));return call('doctor',['--fixture',file]);}
test('doctor emits exactly one PASS line per check and identifies the empty window title',()=>{const r=doctor(fixture(),'pass');assert.equal(r.status,0,r.error?.message);assert.deepEqual(r.stdout.trim().split('\n'),checks.map(c=>c==='window'?'PASS window — title=Mado':'PASS '+c));});
test('doctor accepts exactly one window titled as a fixture file and identifies it',()=>{
 const f=fixture();f.windows=[{title:'alpha-gradient.png'}];const r=doctor(f,'fixture-window');
 assert.equal(r.status,0,r.stdout+r.stderr);
 assert.match(r.stdout,/^PASS window — title=alpha-gradient\.png$/m);
});
test('doctor rejects an unrecorded file title and keeps zero windows distinct',()=>{
 const unknown=fixture();unknown.windows=[{title:'personal-photo.jpg'}];const unknownResult=doctor(unknown,'unknown-window');
 assert.equal(unknownResult.status,1);assert.match(unknownResult.stdout,/^FAIL window — expected one window titled Mado or a recorded fixture file$/m);
 const zero=fixture();zero.windows=[];zero.errors={window:'0 windows'};const zeroResult=doctor(zero,'zero-window');
 assert.equal(zeroResult.status,1);assert.match(zeroResult.stdout,/^FAIL window — 0 windows$/m);
});
test('doctor emits one result per check and fails on each individual defect',()=>{
 for(const [key,value] of Object.entries({sha:'old',bundleID:'wrong',team:'wrong',signatureValid:false,sandbox:false,processMatches:false,fresh:false,alone:false,windows:[],log:'<private>',machineMatches:false,fixturesIntact:false})){
 const f=fixture();f[key]=value;const r=doctor(f,'fail-'+key);assert.equal(r.status,1,key+': '+r.error?.message);const lines=r.stdout.trim().split('\n');assert.equal(lines.length,checks.length);for(let i=0;i<checks.length;i++)assert.match(lines[i],new RegExp('^(PASS '+checks[i]+'(?: — .+)?$|FAIL '+checks[i]+' — .+)'));assert.equal(lines.filter(l=>l.startsWith('FAIL')).length,1,key);
 }
});
test('window lookup uses PID even with identical or misleading owner names',()=>{
 const helper=require('../winid.js');const windows=[{kCGWindowOwnerPID:11,kCGWindowOwnerName:'Mado',kCGWindowLayer:0,kCGWindowNumber:1},{kCGWindowOwnerPID:22,kCGWindowOwnerName:'Other',kCGWindowLayer:0,kCGWindowNumber:2},{kCGWindowOwnerPID:22,kCGWindowOwnerName:'Mado',kCGWindowLayer:3,kCGWindowNumber:3}];
 assert.deepEqual(helper.selectWindows(windows,22).map(w=>w.kCGWindowNumber),[2]);
 assert.deepEqual(helper.selectWindows(windows,33),[]);
});
test('sandbox parser reads explicit XML and rejects typed text',()=>{
 const script=`import sys
sys.path.insert(0, sys.argv[1])
from device import sandbox_enabled
assert not sandbox_enabled('[Dict]\\n\\t[Key] com.apple.security.app-sandbox\\n\\t[Value]\\n\\t\\t[Bool] true\\n')
assert not sandbox_enabled('[Dict]\\n\\t[Key] com.apple.security.app-sandbox\\n\\t[Value]\\n\\t\\t[Bool] false\\n\\t[Key] other\\n\\t[Value]\\n\\t\\t[Bool] true\\n')
assert sandbox_enabled(b'<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>')
assert not sandbox_enabled('nonsense')`;
 const r=spawnSync('python3',['-c',script,base],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
});
test('doctor keeps permission errors on one verdict line',()=>{
 const f=fixture();f.windows=[];f.errors={window:'permission denied\nsecond diagnostic line'};
 const r=doctor(f,'multiline');assert.equal(r.status,1);assert.equal(r.stdout.trim().split('\n').length,checks.length);
});

test('key helper rejects named or multi-character keys before touching a run',()=>{
 const r=call('key',['/does/not/exist','tab']);
 assert.equal(r.status,1);
 assert.match(r.stderr,/key\.sh accepts one printable character; use kc\.sh with a key code for named keys/);
});

test('fix-round-1 offline behavioral regressions',()=>{
 const r=spawnSync('python3',[path.join(__dirname,'fix1_test.py')],{encoding:'utf8'});
 assert.equal(r.status,0,r.stdout+r.stderr);
});
test('fix-round-2 report storage and re-sign regressions',()=>{
 const r=spawnSync('python3',[path.join(__dirname,'fix2_test.py')],{encoding:'utf8'});
 assert.equal(r.status,0,r.stdout+r.stderr);
});
test('Xcode selection uses the locked build from fake app bundles',()=>{
 const r=spawnSync('python3',[path.join(__dirname,'xcode_selection_test.py')],{encoding:'utf8'});
 assert.equal(r.status,0,r.stdout+r.stderr);
});
