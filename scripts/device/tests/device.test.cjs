const {test,after}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawn,spawnSync}=require('node:child_process');
const base=path.resolve(__dirname,'..');
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'picsee-device-'));
after(()=>fs.rmSync(scratch,{recursive:true,force:true}));
function call(name,args){return spawnSync(path.join(base,name+'.sh'),args,{encoding:'utf8'});}
function dummy(dir){
 fs.mkdirSync(dir,{recursive:true});
 const source=path.join(dir,'sleep.c'),exe=path.join(dir,'sleep');
 fs.writeFileSync(source,'#include <unistd.h>\nint main(void){for(;;) sleep(1);}\n');
 const built=spawnSync('/usr/bin/clang',[source,'-o',exe],{encoding:'utf8'});
 assert.equal(built.status,0,built.stderr||built.error?.message);
 fs.unlinkSync(source);
 return spawn(exe,[],{stdio:'ignore'});
}
function record(dir,pid,bundle){fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'picsee.pid'),String(pid));fs.writeFileSync(path.join(dir,'bundle.path'),bundle);const r=spawnSync('python3',['-c',`import sys,json;sys.path.insert(0,sys.argv[1]);from device import process_snapshot;print(json.dumps(process_snapshot(int(sys.argv[2]))))`,base,String(pid)],{encoding:'utf8'});if(r.status===0)fs.writeFileSync(path.join(dir,'process.json'),r.stdout);}
test('cleanup kills only recorded PID, spares same-name process',async()=>{
 const bundle=path.join(scratch,'Good.app'),one=dummy(path.join(bundle,'Contents/MacOS')),two=dummy(path.join(scratch,'other'));
 try {await new Promise(r=>setTimeout(r,100));const run=path.join(scratch,'cleanup-good');record(run,one.pid,bundle);const r=call('cleanup',[run]);assert.equal(r.status,0,r.stderr||r.error?.message);await new Promise(r=>setTimeout(r,100));assert.throws(()=>process.kill(one.pid,0));assert.doesNotThrow(()=>process.kill(two.pid,0));}
 finally{one.kill();two.kill();}
});
test('cleanup refuses executable outside recorded bundle',async()=>{
 const child=dummy(path.join(scratch,'outside'));
 try{await new Promise(r=>setTimeout(r,100));const run=path.join(scratch,'cleanup-wrong');record(run,child.pid,path.join(scratch,'Wrong.app'));const r=call('cleanup',[run]);assert.equal(r.status,1,r.error?.message);assert.match(r.stdout,/FAIL cleanup.*outside recorded bundle/);assert.doesNotThrow(()=>process.kill(child.pid,0));}finally{child.kill();}
});
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
test('screenshot validation rejects a black image and accepts visible window pixels',()=>{
 for(const [name,pixel,expected] of [['black',[0,0,0],1],['visible',[255,255,255],0]]){
  const ppm=path.join(scratch,name+'.ppm'),png=path.join(scratch,name+'.png');
  fs.writeFileSync(ppm,Buffer.concat([Buffer.from('P6\n2 2\n255\n'),Buffer.from([...pixel,...pixel,...pixel,...pixel])]));
  assert.equal(spawnSync('/usr/bin/sips',['-s','format','png',ppm,'--out',png]).status,0);
  const r=spawnSync('/usr/bin/osascript',['-l','JavaScript',path.join(base,'check-image.js'),png],{encoding:'utf8'});
  assert.equal(r.status,expected,r.stderr);
  if(expected)assert.match(r.stderr,/black or empty image/);
 }
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
