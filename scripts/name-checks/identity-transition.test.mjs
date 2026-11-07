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
const feedURL = 'https://raw.githubusercontent.com/anzchy/mado/main/appcast-mado.xml';
test('Mado default identity uses its separately configured feed',()=>{
 assert.equal(identityFor().name,'Mado'); assert.equal(identityFor().info.SUFeedURL,feedURL);
});
test('exact configured feed passes both modes without changing input',()=>{
 for(const release of [false,true]) {
  const artifact=input(feedURL), before=JSON.stringify(artifact), notes=[];
  assert.deepEqual(checkBuiltProduct(artifact,'Mado',{release,notes}),[]);
  assert.deepEqual(notes,[]); assert.equal(JSON.stringify(artifact),before);
 }
});
test('absent empty arbitrary historical and alternate feed URLs fail in both modes',()=>{
 const feeds=[undefined,null,'',' \n\t','https://example.com/feed.xml',
  'https://raw.githubusercontent.com/anzchy/picsee/main/appcast.xml',
  'https://raw.githubusercontent.com/anzchy/mado/main/appcast.xml',
  'https://raw.githubusercontent.com/anzchy/mado/other/appcast-mado.xml',
  'https://raw.githubusercontent.com/anzchy/mado/main/nested/appcast-mado.xml',
  'https://github.com/anzchy/mado/raw/main/appcast-mado.xml',
  'https://api.github.com/repos/anzchy/mado/contents/appcast-mado.xml',
  feedURL+'/',feedURL.replace('https:','http:'),feedURL.replace('mado/main','Mado/main')];
 for(const feed of feeds) for(const release of [false,true]) {
  const artifact=input(feed), before=JSON.stringify(artifact), notes=[];
  const errors=checkBuiltProduct(artifact,'Mado',{release,notes});
  assert.ok(errors.some(p=>p.includes('SUFeedURL')),`${release} ${feed}: ${errors}`);
  assert.deepEqual(notes,[]); assert.equal(JSON.stringify(artifact),before);
 }
});
function xml(v){ if(typeof v==='string')return `<string>${v}</string>`;if(Array.isArray(v))return `<array>${v.map(xml).join('')}</array>`;return `<dict>${Object.entries(v).map(([k,v])=>`<key>${k}</key>${xml(v)}`).join('')}</dict>`;}
function fixture(){const root=mkdtempSync(join(tmpdir(),'mado-identity-')), app=join(root,'Mado.app');mkdirSync(join(app,'Contents'),{recursive:true});const artifact=input(feedURL);const plist=join(app,'Contents/Info.plist');writeFileSync(plist,`<plist>${xml(artifact.info)}</plist>`);const ent=join(root,'app.entitlements'),cat=join(root,'strings.xcstrings');writeFileSync(ent,`<plist>${xml(artifact.entitlements)}</plist>`);writeFileSync(cat,JSON.stringify(artifact.catalogs[0].data));return {root,app,plist,ent,cat};}
test('public CLI accepts exact feed in normal and either release flag position without writing it',()=>{
 const f=fixture(),before=readFileSync(f.plist,'utf8'), script=new URL('./built-product.mjs',import.meta.url).pathname;
 const args=[script,f.app,'--entitlements',f.ent,'--catalog',f.cat];
 for(const argv of [args,[...args,'--release'],[...args.slice(0,2),'--release',...args.slice(2)]]){
  const run=spawnSync(process.execPath,argv,{encoding:'utf8'});
  assert.equal(run.status,0,run.stderr); assert.match(run.stdout,/PASS.*Mado/); assert.doesNotMatch(run.stdout,/NOTE/);
 }
 assert.equal(readFileSync(f.plist,'utf8'),before);
});
test('release package layout accepts only the Mado executable and refuses an absent feed',()=>{
 assert.equal(classifyPath('Contents/MacOS/Mado'),null); assert.notEqual(classifyPath('Contents/MacOS/Picsee'),null);
 assert.ok(checkInfo({}).some(p=>p.includes('SUFeedURL')));
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
   assert.ok(errors.some(error=>error.includes('SUFeedURL')),`${release} ${feed}: ${errors}`);
   assert.deepEqual(notes,[]);
  }
 }
 for(const feed of ['https://anzchy.github.io/mado-other/feed.xml','https://example.com/mado/feed.xml','https://anzchy.github.io/other/feed.xml']){
  const notes=[];
  assert.ok(checkBuiltProduct(input(feed),'Mado',{notes}).some(p=>p.includes('SUFeedURL')));
  assert.deepEqual(notes,[]);
  assert.ok(checkBuiltProduct(input(feed),'Mado',{release:true}).some(p=>p.includes('SUFeedURL')));
 }
});
