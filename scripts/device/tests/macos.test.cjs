// Real macOS adapter integrations: libproc, sips, JXA and AppKit.
const {test,after}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawn,spawnSync}=require('node:child_process');
const base=path.resolve(__dirname,'..');
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'mado-device-'));
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
