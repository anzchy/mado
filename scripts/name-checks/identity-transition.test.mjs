import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { checkBuiltProduct } from './built-product.mjs';
import { identityFor } from './identity.mjs';
import { checkInfo, classifyPath } from '../release/check-package.mjs';
const mach = 'com.apple.security.temporary-exception.mach-lookup.global-name';
const input = feed => ({info: {CFBundleName:'Mado',CFBundleDisplayName:'Mado',CFBundleIdentifier:'io.github.anzchy.mado',SUFeedURL:feed}, entitlements:{[mach]:['io.github.anzchy.mado-spks','io.github.anzchy.mado-spki']},catalogs:[{path:'test.xcstrings',data:{sourceLanguage:'en',strings:{}}}]});
const undecided = 'Info.plist:SUFeedURL undecided for Mado (decided in #552)';
test('Mado is the default identity and the undecided feed stays unset',()=>{
 assert.equal(identityFor().name,'Mado'); assert.equal(identityFor().info.SUFeedURL,null);
});
test('normal mode notes undecided feed while release rejects the same input',()=>{
 for(const feed of [undefined,null,'','https://example.com/feed.xml','https://github.com/anzchy/mado-other/feed.xml']){
  const artifact=input(feed), before=JSON.stringify(artifact), notes=[];
  assert.deepEqual(checkBuiltProduct(artifact,'Mado',{notes}),[]);
  assert.deepEqual(notes,[undecided]);
  assert.deepEqual(checkBuiltProduct(artifact,'Mado',{release:true}),[undecided]);
  assert.equal(JSON.stringify(artifact),before);
 }
});
test('frozen Picsee and inferred repository feed URLs always fail',()=>{
 for(const feed of ['https://raw.githubusercontent.com/anzchy/picsee/main/appcast.xml','https://raw.githubusercontent.com/anzchy/mado/main/appcast.xml','https://raw.githubusercontent.com/anzchy/mado/other/nested/feed.xml','https://github.com/anzchy/mado/raw/main/feed.xml','https://api.github.com/repos/anzchy/mado/contents/feed.xml']){
  for(const release of [false,true]) assert.ok(checkBuiltProduct(input(feed),'Mado',{release}).some(p=>p.includes('SUFeedURL')),`${release} ${feed}`);
 }
});
function xml(v){ if(typeof v==='string')return `<string>${v}</string>`;if(Array.isArray(v))return `<array>${v.map(xml).join('')}</array>`;return `<dict>${Object.entries(v).map(([k,v])=>`<key>${k}</key>${xml(v)}`).join('')}</dict>`;}
function fixture(){const root=mkdtempSync(join(tmpdir(),'mado-identity-')), app=join(root,'Mado.app');mkdirSync(join(app,'Contents'),{recursive:true});const artifact=input('');const plist=join(app,'Contents/Info.plist');writeFileSync(plist,`<plist>${xml(artifact.info)}</plist>`);const ent=join(root,'app.entitlements'),cat=join(root,'strings.xcstrings');writeFileSync(ent,`<plist>${xml(artifact.entitlements)}</plist>`);writeFileSync(cat,JSON.stringify(artifact.catalogs[0].data));return {root,app,plist,ent,cat};}
test('public CLI reports NOTE and PASS in normal mode and FAIL in release in either flag position',()=>{
 const f=fixture(),before=readFileSync(f.plist,'utf8'), script=new URL('./built-product.mjs',import.meta.url).pathname;
 const args=[script,f.app,'--entitlements',f.ent,'--catalog',f.cat];
 const normal=spawnSync(process.execPath,args,{encoding:'utf8'});assert.equal(normal.status,0,normal.stderr);assert.match(normal.stdout,/NOTE.*#552/);assert.match(normal.stdout,/PASS.*Mado/);
 for(const args2 of [[...args,'--release'],[...args.slice(0,2),'--release',...args.slice(2)]]){const run=spawnSync(process.execPath,args2,{encoding:'utf8'});assert.equal(run.status,1,run.stderr);assert.match(run.stderr,/FAIL.*#552/);}
 assert.equal(readFileSync(f.plist,'utf8'),before);
});
test('release package layout accepts only the Mado executable and refuses an undecided feed',()=>{
 assert.equal(classifyPath('Contents/MacOS/Mado'),null); assert.notEqual(classifyPath('Contents/MacOS/Picsee'),null);
 assert.ok(checkInfo({}).some(p=>p.includes('SUFeedURL')&&p.includes('#552')));
});

test('ordinary checks reject frozen-feed scheme/slash variants and Mado Pages forms',()=>{
 const frozen=identityFor('Picsee').info.SUFeedURL;
 const forbidden=[frozen, frozen+'/', frozen.replace('https:', 'http:'), frozen.replace('https:', 'http:')+'/',
  'http://anzchy.github.io/mado','https://anzchy.github.io/mado/',
  'https://ANZCHY.github.io/mado/appcast.xml','https://anzchy.github.io/mado/nested/feed.xml'];
 for(const feed of forbidden){
  for(const release of [false,true]){
   const notes=[];
   const errors=checkBuiltProduct(input(feed),'Mado',{release,notes});
   assert.ok(errors.some(error=>error.includes('forbidden')&&error.includes('SUFeedURL')&&error.includes('#552')),`${release} ${feed}: ${errors}`);
   assert.deepEqual(notes,[]);
  }
 }
 for(const feed of ['https://anzchy.github.io/mado-other/feed.xml','https://example.com/mado/feed.xml','https://anzchy.github.io/other/feed.xml']){
  const notes=[];
  assert.deepEqual(checkBuiltProduct(input(feed),'Mado',{notes}),[]);
  assert.deepEqual(notes,[undecided]);
  assert.deepEqual(checkBuiltProduct(input(feed),'Mado',{release:true}),[undecided]);
 }
});
