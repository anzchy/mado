import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { readFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
const base = 'design/prototypes/picsee-browser/states/';
const baseline = 'fba1348e81e54a388d5c75b38d5985588bcad49c';
test('#540 tools material variants preserve inspector and filmstrip', async () => {
 const server = http.createServer((req,res) => {
  const u=new URL(req.url,'http://localhost');
  try { const file=path.join(base,u.pathname); const bytes=u.searchParams.has('baseline') ? execFileSync('git',['show',`${baseline}:${file}`]) : readFileSync(file); res.setHeader('Content-Type',file.endsWith('.html')?'text/html':file.endsWith('.jpg')?'image/jpeg':'application/octet-stream');res.end(bytes); } catch {res.statusCode=404;res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch();
 try {
 const page=await browser.newPage({viewport:{width:1280,height:800}});
 const snapshot=()=>page.evaluate(()=>[...document.querySelectorAll('.inspector, .c-filmstrip')].map(e=>({html:e.outerHTML,styles:[e,...e.querySelectorAll('*')].map(n=>{const s=getComputedStyle(n);return Object.fromEntries([...s].filter(k=>!k.startsWith('--')).map(k=>[k,s.getPropertyValue(k)]));})})));
 for(const file of ['viewer-controls','viewer-inspector','viewer-filmstrip']) for(const theme of ['light','dark']) {
 const url=`http://127.0.0.1:${server.address().port}/${file}.html?theme=${theme}`;
 await page.goto(url+'&baseline'); const original=await snapshot();
 for(const opacity of ['30','50','100','default','invalid']) {
 await page.goto(url+(opacity==='default'?'':`&tool-opacity=${opacity}`));
 assert.deepEqual(await snapshot(),original,`${file} ${theme} protected surfaces`);
 const actual=await page.evaluate(()=>[...document.querySelectorAll('.viewer-floating-controls > [data-viewer-controls]')].map(e=>{const s=getComputedStyle(e);return {kind:e.dataset.viewerControls,background:s.backgroundColor,blur:s.backdropFilter,radius:s.borderRadius,shadow:s.boxShadow};}));
 assert.equal(actual.length,file==='viewer-filmstrip'?2:3);
 const percentage=['30','100'].includes(opacity)?+opacity:50;
 const expected=await page.evaluate(p=>{const e=document.createElement('i');e.style.backgroundColor=`color-mix(in srgb, var(--color-panel) ${p}%, transparent)`;e.style.boxShadow='var(--shadow-soft)';document.body.append(e);const s=getComputedStyle(e),v={background:s.backgroundColor,shadow:s.boxShadow};e.remove();return v;},percentage);
 for(const pod of actual) {assert.equal(pod.background,expected.background,`${file} ${theme} ${opacity} ${pod.kind} alpha`);assert.equal(pod.blur,'blur(20px) saturate(1.6)');assert.equal(pod.radius,'6px');assert.equal(pod.shadow,expected.shadow);}
 if(process.env.I540_SCREENSHOTS && ['30','50','100'].includes(opacity)) {mkdirSync(process.env.I540_SCREENSHOTS,{recursive:true});await page.screenshot({path:path.join(process.env.I540_SCREENSHOTS,`${file}-${theme}-${opacity}.png`)});}
 }
 }
 } finally {await browser.close();await new Promise(r=>server.close(r));}
});
