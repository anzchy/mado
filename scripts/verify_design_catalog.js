// Run with `npm run design:check` (scripts/design-check.mjs serves design/ and states/ and passes their origins).
// Verification output is returned as JSON; this file does not modify design sources.
// Each branch's played destinations, written from plan §1.6, ADR-0010 and ADR-014 rather than read from journeys.html.
// A page with a query is written page?query. Branches without a state page (placeholders, menu actions) have no player.
const BRANCH_PLAYS={
 'J1-cancel':[['first-launch','folder-loading','first-launch'],['grid-light','folder-loading','grid-light']],
 'J1-empty':[['folder-loading','empty-folder','folder-loading']],
 'J1-scan-failed':[['folder-loading','folder-loading?case=failed','folder-loading'],['folder-loading','folder-loading?case=failed','folder-loading']],
 'J1-access':[['grid-light','permission-denied','grid-light'],['grid-light','permission-denied','permission-denied'],['grid-light','permission-denied','folder-loading'],['grid-light','permission-denied?cause=volume','grid-light']],
 'J1-moved':[['grid-light','permission-denied?case=moved','grid-light'],['grid-light','permission-denied?case=moved','folder-loading']],
 'J2-error':[['viewer-quiet','image-error','viewer-quiet'],['viewer-quiet','image-error','grid-light']],
 'J2-tools':[['viewer-quiet','viewer-controls','viewer-quiet']],
 'J2-actual':[['viewer-quiet','original-size','viewer-quiet']],
 'J2-film':[['viewer-quiet','viewer-filmstrip','viewer-quiet']],
 'J3-search':[['grid-light','search-empty','grid-light']],
 'J4-light':[['viewer-inspector','viewer-inspector-light','viewer-inspector']],
 'J4-settings':[['grid-display','settings?section=display','grid-display']],
 'J4-shortcuts':[['grid-light','shortcuts','grid-light']],
};
// Settings window, layout B (#214, spec #212): sidebar sections in order, each reachable by ?section=.
const SETTINGS_SECTIONS=[['general','通用'],['display','显示'],['cache','缓存'],['update','更新'],['about','关于']];
// Every control in each Settings pane, in order: ready when the app has it, soon when it is greyed 「即将推出」
// (user: 「显示但置灰」). A control left out of this list fails. Not built: PREF-03 display settings, DIST-05 updates,
// the About links (no ledger row). Built: PREF-01 appearance, CHROME-04 always-show tools, CACHE-03 clearing the cache.
const SETTINGS_CONTROLS={
 general:[['跟随系统','ready'],['浅色','ready'],['深色','ready'],['始终显示大图工具','ready']],
 display:[['缩略图大小','soon'],['显示文件名','soon'],['填充裁剪','soon'],['完整显示','soon']],
 cache:[['清理缓存…','ready']],
 update:[['自动检查更新','soon'],['立即检查','soon']],
 about:[['报告问题…','soon'],['隐私说明','soon'],['源代码','soon']],
};
// Shortcut list, layout C: one card per context, in order, each reachable by ?card=.
const SHORTCUT_CARDS=[['files','文件与窗口','任何时候'],['grid','网格','浏览文件夹时'],['viewer','大图','查看一张图片时']];
// #317 (spec #311): the grid Bottom Bar sits over the Grid at the window background's 80%, with no top rule (user:
// 「填充 80%（很实）」「不要，靠 80% 底色区分」), in every window with a folder open (「只有未打开文件夹的窗口没有底栏」).
// These pages show it; page 21 (the Home) does not. Each URL below is checked against grid-footer-fill.html.
const GRID_BAR_PAGES=['grid-light','grid-dark','grid-display','empty-folder','search-empty','folder-loading','permission-denied','compact-grid','components','grid-context-menu','grid-multiselect'];
const GRID_BAR_CASES=[...GRID_BAR_PAGES.map(n=>n+'.html'),'empty-folder.html?theme=dark','empty-folder.html?drag=over','permission-denied.html?theme=dark','folder-loading.html?case=failed','folder-loading.html?case=failed&theme=dark',
 'grid-light.html?scroll=behind','grid-dark.html?scroll=behind','grid-light.html?transparency=reduced','grid-dark.html?transparency=reduced'];
// #317 retained prior viewer bytes; #347 deliberately supersedes tool fill on 14/16/33 only.
// Other viewer pages retain their old pins and are not #351 tool-fill oracles.
const VIEWER_BAR_SHA256={'viewer-quiet':'1cb5ee6198cd4333f156095c35fa7e1ea03eccb03e3b0144bfe799794f2cd101','viewer-controls':'8577ac87f024fd2d8923d003de44b2b5a4ae410215b1a9cf9d170d5fc86551c1','viewer-inspector':'18ccde89fe43e8514f42d26af03a45b92de18f5f3faf322fed1709bb97723d75','image-error':'98573fc7914a86e4c55c55b233aa4901a26ba080763ddda92f4474405b7119cb','original-size':'8b4395816c23ae87fae0aa99efda248db30d09949a76273e2d9c38db6e17aab9','keyboard-focus':'4651f48a5895f120efb3ff79abe72941ca7019aecb0f2d31e761e5ce0c48909f','viewer-filmstrip':'5e29ff116c256162441366a9a78d1dadc3454384d30e23e8b42463c2fadeb83c','viewer-inspector-light':'a2e2331cef71140452d0d8070a814f0a875f1d5bcf0f697d87758f75a0c9d01e'};
module.exports=async(page,{design,states,screenshot})=>{
 const base=design+'/prototypes/picsee-browser/states/';
 const errors=[],failures=[],results=[];page.on('pageerror',e=>errors.push(e.message));page.on('response',r=>{if(r.status()>=400&&r.url().startsWith('http://127.0.0.1:'))failures.push({url:r.url(),status:r.status()})});
 await page.goto(base+'index.html');await page.getByRole('navigation',{name:'设计页面'}).waitFor();
 const catalog=await page.evaluate(async()=>{const r=await fetch('manifest.json');return r.json()});
 if(catalog.states.length!==22||await page.locator('nav button').count()!==22)throw Error('Expected 22 catalog states');

 // 22 and 26 are local replacements of the accepted Stitch pages (ADR-014), like 31–34.
 for(const name of ['empty-folder','permission-denied','settings','shortcuts'])if(catalog.states.find(s=>s.name===name).origin!=='local-C-adaptation')throw Error(name+' origin is not local-C-adaptation');
 for(const state of catalog.states){
  await page.setViewportSize(state.viewport);await page.goto(base+state.file);await page.evaluate(async()=>Promise.all([...document.images].map(i=>i.decode().catch(()=>{}))));
  const check=await page.evaluate(()=>({broken:[...document.images].some(i=>!i.complete||!i.naturalWidth),overflow:document.documentElement.scrollWidth>innerWidth,inlineImages:[...document.images].some(i=>i.src.startsWith('data:')),externalImages:[...document.images].some(i=>!i.src.startsWith(location.origin))}));
  if(Object.values(check).some(Boolean))throw Error(state.name+' invalid resource/layout '+JSON.stringify(check));
  if(state.name==='viewer-quiet'&&await page.locator('.zoom-pod').isVisible())throw Error('Quiet controls regression');
  if(state.name==='viewer-controls'&&!await page.locator('.zoom-pod').isVisible())throw Error('Visible controls regression');
  if(state.name==='grid-multiselect'&&await page.locator('.photo-cell[aria-selected="true"]').count()!==3)throw Error('Selection count regression');
  // Page 15 has no shortcut entry; the list lives under 帮助 → 键盘快捷键 (user: 「Page 15 中去掉快捷键入口」).
  if(state.name==='grid-display'&&await page.evaluate(()=>document.body.innerText.includes('键盘快捷键')||!!document.querySelector('.setting-help')))throw Error('Page 15 still shows 键盘快捷键');
  if(state.name==='viewer-filmstrip'&&(await page.locator('.c-filmstrip-images button').count()!==12||await page.locator('.navigation-pod').count()))throw Error('Filmstrip regression');
  results.push({name:state.name,passed:true});
 }
 // #347 fix1: owner A A C (2026-11-03) replaces the .72 height oracle and adds rendered contrast.
 const variantFailures=[],contrastTable=[],geometryTable=[];let viewerToolVariants=0,thumbnailSizeVariants=0;
 const canonicalTokens=await (await page.request.get(design+'/picsee-ui-system/tokens/viewer-grid.css')).text();
 const viewerRules=await (await page.request.get(base+'viewer-grid-variants.css')).text();
 const runtimeTokens=await (await page.request.get(base+'_ds/picsee-ui-system/tokens/viewer-grid.css')).text();
 if(canonicalTokens!==runtimeTokens)variantFailures.push('canonical/runtime tokens differ');
 for(const file of ['grid-light','grid-dark','viewer-controls','viewer-inspector','viewer-filmstrip']){
  await page.goto(base+file+'.html');
  const inline=await page.evaluate(()=>({links:[...document.querySelectorAll('link[rel="stylesheet"]')].map(e=>e.href),tokens:document.querySelector('style[data-viewer-grid-tokens]')?.textContent,tools:document.querySelector('style[data-viewer-tools]')?.textContent,imports:[...document.querySelectorAll('style')].some(e=>/@import\b/.test(e.textContent))}));
  if(inline.imports||(file.startsWith('viewer')&&inline.tools?.trim()!==viewerRules.trim()))variantFailures.push(file+': external import or stale inline tool rules');
  if(inline.links.length||inline.tokens?.trim()!==canonicalTokens.trim())variantFailures.push(file+': rendering is not fully inline/pinned');
 }
 for(const file of ['viewer-controls','viewer-inspector','viewer-filmstrip'])for(const theme of ['light','dark'])for(const backdrop of ['white','black']){
  await page.setViewportSize({width:1280,height:800});await page.goto(base+file+'.html?theme='+theme);
  await page.addStyleTag({content:'.picture-stage{background:'+backdrop+'}.large-image{visibility:hidden}'});
  // Preserve unrelated root classes when switching theme (L2).
  await page.evaluate(()=>{document.documentElement.classList.add('review-marker');const script=[...document.scripts].find(s=>s.textContent.includes("get('theme')"));if(script)(0,eval)(script.textContent)});
  const got=await page.evaluate(()=>{
   const box=e=>{const r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height}};
   const pods=[...document.querySelectorAll('[data-viewer-controls]')];
   const surfaces=pods.map(e=>({kind:e.dataset.viewerControls,box:box(e),fill:getComputedStyle(e).backgroundColor,blur:getComputedStyle(e).backdropFilter,radius:getComputedStyle(e).borderRadius,shadow:getComputedStyle(e).boxShadow,visible:e.checkVisibility({opacityProperty:true,visibilityProperty:true})}));
   const counter=document.querySelector('.viewer-file-label > span, .c-strip-count'),zoom=document.querySelector('.zoom-pod select');
   const elements=[...pods.flatMap(p=>[...p.querySelectorAll('svg')].map((e,i)=>({e,kind:'glyph',name:p.dataset.viewerControls+'-icon-'+i}))),{e:counter,kind:'text',name:'counter'},{e:zoom,kind:'text',name:'zoom'}].map(({e,kind,name})=>{
    if(!e)return{missing:true,kind,name};const p=e.closest('[data-viewer-controls],.c-filmstrip'),s=getComputedStyle(e);
    return{kind,name,box:box(e),surface:box(p),color:s.color,halo:kind==='glyph'?s.filter:s.textShadow,visible:e.checkVisibility({opacityProperty:true,visibilityProperty:true})};
   });
   const probe=document.createElement('i');probe.style.boxShadow='var(--shadow-soft)';document.body.append(probe);const shadow=getComputedStyle(probe).boxShadow;probe.remove();
   return{theme:document.documentElement.className,pods:surfaces,elements,shadow};
  });
  viewerToolVariants++;
  const expected=file==='viewer-filmstrip'?['leading','zoom']:['leading','navigation','zoom'];
  if(!got.theme.includes('theme-'+theme)||!got.theme.includes('review-marker')||JSON.stringify(got.pods.map(p=>p.kind).sort())!==JSON.stringify(expected))variantFailures.push(file+' '+theme+': theme/classes/groups');
  const fill=await page.evaluate(theme=>{const e=document.createElement('i');e.style.backgroundColor='color-mix(in srgb,'+(theme==='light'?'#fff':'#141821')+' 50%,transparent)';document.body.append(e);const c=getComputedStyle(e).backgroundColor;e.remove();return c},theme);
  for(const p of got.pods)if(p.fill!==fill||p.blur!=='blur(20px) saturate(1.6)'||p.radius!=='6px'||p.shadow!==got.shadow||!p.visible)variantFailures.push(file+' '+theme+': material '+p.kind);
  const screenshot=(await page.screenshot()).toString('base64');
  // Sample the actual screenshot: interior backing colour and the strongest rendered foreground pixel,
  // after blur, alpha compositing, halo and font antialiasing. No computed-color-only contrast oracle.
  const measured=await page.evaluate(async({screenshot,elements})=>{
   const img=new Image();img.src='data:image/png;base64,'+screenshot;await img.decode();const c=document.createElement('canvas');c.width=img.width;c.height=img.height;const ctx=c.getContext('2d');ctx.drawImage(img,0,0);
   const pixel=(x,y)=>[...ctx.getImageData(Math.floor(x),Math.floor(y),1,1).data].slice(0,3);
   const lum=rgb=>rgb.map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4}).reduce((s,v,i)=>s+v*[.2126,.7152,.0722][i],0);
   const contrast=(a,b)=>(Math.max(lum(a),lum(b))+.05)/(Math.min(lum(a),lum(b))+.05);
   return elements.map(e=>{if(e.missing)return e;const target=e.color.match(/[\d.]+/g).slice(0,3).map(Number);const bg=pixel(e.surface.x+e.surface.width/2,e.surface.y+4);let foreground,best=Infinity;
    for(let y=Math.ceil(e.box.y);y<Math.floor(e.box.y+e.box.height);y++)for(let x=Math.ceil(e.box.x);x<Math.floor(e.box.x+e.box.width);x++){
     const rgb=pixel(x,y),d=rgb.reduce((s,v,i)=>s+(v-target[i])**2,0);if(d<best){best=d;foreground=rgb;}
    }
    return{element:e.name,kind:e.kind,foreground,background:bg,ratio:foreground?contrast(foreground,bg):0,halo:e.halo,visible:e.visible,color:e.color};
   });
  },{screenshot,elements:got.elements});
  for(const e of measured){if(!e.halo?.includes('1px'))variantFailures.push(file+': missing nonzero halo '+e.name);contrastTable.push({page:file,theme,backdrop,...e});
   if(e.missing||!e.visible||!e.halo||e.halo==='none'||e.color!==(theme==='light'?'rgb(26, 26, 26)':'rgb(229, 231, 235)')||e.ratio<(e.kind==='glyph'?3:4.5))variantFailures.push(file+' '+theme+' '+backdrop+': rendered contrast '+JSON.stringify(e));
  }
 }
 for(const file of ['grid-light','grid-dark'])for(const viewport of [480,720,1050,1280,1600]){
  let invariant;
  for(const [query,size] of [['',220],['?thumbnail-size=140',140],['?thumbnail-size=220',220],['?thumbnail-size=280',280],['?thumbnail-size=invalid',220]]){
   await page.setViewportSize({width:viewport,height:800});await page.goto(base+file+'.html'+query);
   const got=await page.evaluate(()=>{
    const grid=document.querySelector('.photo-grid'),s=getComputedStyle(grid),rect=grid.getBoundingClientRect(),bar=document.querySelector('.grid-bottom-bar'),b=bar.getBoundingClientRect(),bs=getComputedStyle(bar);
    const cells=[...grid.querySelectorAll('.photo-cell')].map(e=>{const t=e.querySelector('.thumbnail-wrap').getBoundingClientRect(),r=e.getBoundingClientRect();return{width:r.width,height:t.height}});
    const cell=grid.querySelector('.photo-cell'),label=cell.querySelector('.photo-name');label.textContent='很长的中英文件名 — A very long photograph filename with details — 2026.jpg';cell.title=label.textContent;
    const ls=getComputedStyle(label),lr=label.getBoundingClientRect();return{size:s.getPropertyValue('--thumb-min').trim(),width:rect.width,gap:parseFloat(s.columnGap),columns:s.gridTemplateColumns.split(' ').length,cells,
     label:{ellipsis:ls.textOverflow,wrap:ls.whiteSpace,overflow:ls.overflow,clipped:label.scrollWidth>label.clientWidth,inside:lr.right<=cell.getBoundingClientRect().right,full:cell.title===label.textContent},
     bar:{rect:[b.x,b.y,b.width,b.height],fill:bs.backgroundColor,border:bs.borderTop,html:bar.innerHTML},overflow:document.documentElement.scrollWidth>innerWidth};
   });
   thumbnailSizeVariants++;
   const min=viewport<=720?145:size,columns=viewport<=480?1:Math.max(1,Math.floor((got.width+got.gap)/(min+got.gap))),width=(got.width-(columns-1)*got.gap)/columns;
   const baseHeight=viewport>=1600?200:viewport<=1050?165:Math.max(135,Math.min(225,viewport*.147));const height=viewport<=720?150:baseHeight*size/220;
   geometryTable.push({page:file,viewport,size,columns:got.columns,track:got.cells[0]?.width,height:got.cells[0]?.height,query});
   if(got.columns!==columns||got.cells.some(c=>Math.abs(c.width-width)>.1||Math.abs(c.height-height)>.1)||got.overflow||got.bar.rect[2]!==viewport)variantFailures.push(file+query+' @'+viewport+': geometry '+JSON.stringify(got));
   if(got.label.ellipsis!=='ellipsis'||got.label.wrap!=='nowrap'||got.label.overflow!=='hidden'||!got.label.clipped||!got.label.inside||!got.label.full)variantFailures.push(file+query+': filename '+JSON.stringify(got.label));
   if(invariant&&JSON.stringify(got.bar)!==invariant)variantFailures.push(file+query+': Bottom Bar changed with size');invariant=JSON.stringify(got.bar);
  }
 }
 if(variantFailures.length)throw Error('#347 fix1 variants: '+variantFailures.join(' | '));
 // Each manifest sha256 pins the exact bytes of its page.
 for(const state of catalog.states){const actual=await page.evaluate(async f=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',await(await fetch(f,{cache:'no-store'})).arrayBuffer()))].map(b=>b.toString(16).padStart(2,'0')).join(''),state.file);if(actual!==state.sha256)throw Error(state.file+' SHA256 mismatch: manifest '+state.sha256+', actual '+actual)}
 // #347 explicitly updates only the 14/16/33 viewer pins for the chosen frosted tools; other viewer pins remain fixed.
 // #317: page 21 is the Home with the Image Wall of home-image-wall.html (user: 「C 取代 B4 外观，保留拖入反馈」), and
 // every grid Bottom Bar matches grid-footer-fill.html. Expected values are read from those reference pages, not retyped.
 const barIssues=[];const shows={bar:[],viewer:[]};
 for(const state of catalog.states){await page.setViewportSize(state.viewport);await page.goto(base+state.file);
  const got=await page.evaluate(()=>({bar:!!document.querySelector('.grid-bottom-bar')&&document.querySelector('.grid-bottom-bar').getClientRects().length>0,viewer:!!document.querySelector('.picture-viewer')}));
  if(got.bar)shows.bar.push(state.name);if(got.viewer)shows.viewer.push(state.name)}
 if(JSON.stringify(shows.bar.sort())!==JSON.stringify([...GRID_BAR_PAGES].sort()))barIssues.push('pages showing the grid Bottom Bar are '+shows.bar.join(',')+', want '+[...GRID_BAR_PAGES].sort().join(','));
 if(JSON.stringify(shows.viewer.sort())!==JSON.stringify(Object.keys(VIEWER_BAR_SHA256).sort()))barIssues.push('pages showing the viewer command bar are '+shows.viewer.join(','));
 for(const [name,sha] of Object.entries(VIEWER_BAR_SHA256))if(catalog.states.find(s=>s.name===name).sha256!==sha)barIssues.push(name+' (viewer command bar) changed');
 const barProbe=()=>{const bar=document.querySelector('.grid-bottom-bar'),scroll=document.querySelector('.grid-scroll'),divider=document.querySelector('.grid-bottom-left .toolbar-divider');
  const token=v=>{const e=document.createElement('i');e.style.color=v;document.body.append(e);const c=getComputedStyle(e).color;e.remove();return c};
  if(!bar)return{missing:true};const b=bar.getBoundingClientRect(),s=scroll&&scroll.getBoundingClientRect(),d=divider&&divider.getBoundingClientRect();
  const behind=[...document.querySelectorAll('.photo-cell img')].some(i=>{const r=i.getBoundingClientRect();return r.bottom>b.top+1&&r.top<b.bottom});
  let clipped=[];if(scroll){scroll.scrollTop=scroll.scrollHeight;clipped=[...scroll.querySelectorAll('*')].filter(e=>e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden'&&e.getBoundingClientRect().height>0&&e.getBoundingClientRect().bottom>b.top+0.5).map(e=>e.className||e.tagName).slice(0,3)}
  return{dark:document.documentElement.classList.contains('theme-dark'),fill:getComputedStyle(bar).backgroundColor,rule:getComputedStyle(bar).borderTopWidth+' '+getComputedStyle(bar).borderTopStyle,bg:token('var(--color-bg)'),
   divider:d?[Math.round(d.width),getComputedStyle(divider).backgroundColor]:null,under:!!s&&s.bottom>=b.bottom-0.5&&s.top<b.top,behind,clipped}};
 const barRef={};for(const theme of ['light','dark']){await page.setViewportSize({width:1280,height:800});await page.goto(base+'grid-footer-fill.html?theme='+theme);barRef[theme]=await page.evaluate(barProbe)}
 for(const url of GRID_BAR_CASES){const state=catalog.states.find(s=>s.file===url.split('?')[0]);await page.setViewportSize(state.viewport);await page.goto(base+url);
  await page.evaluate(async()=>Promise.all([...document.images].map(i=>i.decode().catch(()=>{}))));const got=await page.evaluate(barProbe),want=barRef[got.dark?'dark':'light'],bad=[];
  if(got.missing){barIssues.push(url+': no grid Bottom Bar');continue}
  if(/transparency=reduced/.test(url)){if(got.fill!==got.bg)bad.push('Reduce Transparency fill '+got.fill+' is not the window background '+got.bg)}else if(got.fill!==want.fill)bad.push('fill '+got.fill+', want '+want.fill);
  if(got.rule!==want.rule)bad.push('top rule '+got.rule+', want '+want.rule);
  if(JSON.stringify(got.divider)!==JSON.stringify(want.divider))bad.push('leading divider '+JSON.stringify(got.divider)+', want '+JSON.stringify(want.divider));
  if(!got.under)bad.push('Grid scroll area does not run behind the bar');if(got.clipped.length)bad.push('content still under the bar at the end of the scroll: '+got.clipped.join(','));
  if(/scroll=behind/.test(url)&&!got.behind)bad.push('no photo behind the bar');
  if(bad.length)barIssues.push(url+': '+bad.join(', '));
 }
 const homeProbe=()=>{const q=s=>document.querySelector(s),cs=(e,p)=>e?getComputedStyle(e,p):{};const visible=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
  const wall=q('.wall'),tiles=q('.wall .tiles'),t=cs(tiles),img=q('.wall .tiles img'),even=q('.wall .tiles>:nth-child(2n)'),rect=e=>e?['top','left','width','height'].map(k=>Math.round(e.getBoundingClientRect()[k])):null;
  const anim=tiles&&tiles.getAnimations()[0];const prompt=q('[data-drop-prompt]')||[...document.querySelectorAll('main .mock-muted')].find(e=>e.innerText.includes('拖入'));const outline=q('.drop-outline');
  const token=v=>{const e=document.createElement('i');e.style.color=v;document.body.append(e);const c=getComputedStyle(e).color;e.remove();return c};
  return{dark:document.documentElement.classList.contains('theme-dark'),bar:visible(q('.grid-bottom-bar')),sidebar:visible(q('.sidebar')),wallHidden:!!wall&&wall.getAttribute('aria-hidden')==='true'&&cs(wall).pointerEvents==='none',wallRect:rect(wall),
   tiles:tiles?{transform:t.transform,opacity:t.opacity,columns:t.gridTemplateColumns,rows:t.gridAutoRows,gap:t.rowGap+' '+t.columnGap,box:[t.left,t.right,t.top,t.height].join(' '),count:tiles.children.length,
    motion:[t.animationDuration,t.animationDirection,t.animationTimingFunction,t.animationIterationCount].join(' '),keyframes:anim?JSON.stringify(anim.effect.getKeyframes().map(k=>[k.offset,k.translate])):'none',
    radius:cs(img).borderRadius,shadow:cs(img).boxShadow,fit:cs(img).objectFit,offset:cs(even).transform,veil:cs(wall,'::after').backgroundImage}:null,
   heading:(q('main h2')||{}).innerText,chips:/文件夹 · |单张或多张图片|常见图片格式/.test(document.body.innerText),button:q('.mock-primary')&&[q('.mock-primary').innerText,...rect(q('.mock-primary'))],hint:prompt&&[prompt.innerText,...rect(prompt)],
   onTop:(b=>!!b&&document.elementFromPoint(b.left+b.width/2,b.top+b.height/2)===q('.mock-primary'))(q('.mock-primary')&&q('.mock-primary').getBoundingClientRect()),
   wallAlpha:wall&&tiles?+cs(wall).opacity*+t.opacity:0,dragOver:!!q('[data-drop-target].is-drag-over'),promptColor:prompt?cs(prompt).color:null,accentText:token('var(--color-accent-text)'),outline:outline?cs(outline).borderTopColor:null}};
 const homeRef={};for(const theme of ['light','dark']){await page.setViewportSize({width:1280,height:800});await page.goto(base+'home-image-wall.html?theme='+theme);homeRef[theme]=await page.evaluate(homeProbe)}
 const home={};for(const url of ['first-launch.html','first-launch.html?theme=dark','first-launch.html?drag=over','first-launch.html?drag=over&theme=dark']){await page.setViewportSize({width:1280,height:800});await page.goto(base+url);home[url]=await page.evaluate(homeProbe)}
 for(const [url,overURL,want,dark] of [['first-launch.html','first-launch.html?drag=over',homeRef.light,false],['first-launch.html?theme=dark','first-launch.html?drag=over&theme=dark',homeRef.dark,true]]){const got=home[url],over=home[overURL],bad=[];
  if(got.dark!==dark)bad.push('dark='+got.dark);if(got.bar)bad.push('shows the Bottom Bar');if(got.sidebar)bad.push('shows the sidebar');
  if(!got.tiles)bad.push('no Image Wall');else{if(!got.wallHidden)bad.push('wall not aria-hidden or takes pointer events');if(JSON.stringify(got.wallRect)!==JSON.stringify(want.wallRect))bad.push('wall '+got.wallRect+', want '+want.wallRect);
   for(const k of Object.keys(want.tiles))if(got.tiles[k]!==want.tiles[k])bad.push('wall '+k+' '+JSON.stringify(got.tiles[k])+', want '+JSON.stringify(want.tiles[k]))}
  // The centre is B4's, not the reference page's: drop hint, then 「选择文件夹…」, 18 apart, and no chips row (#441).
  if(got.heading!=='把照片文件夹拖到这里'||!got.hint||got.hint[0]!==got.heading)bad.push('hint '+JSON.stringify(got.hint)+', want the B4 drop hint');
  if(!got.button||got.button[0]!=='选择文件夹…')bad.push('button '+JSON.stringify(got.button)+', want 选择文件夹…');else if(got.hint&&got.button[1]-got.hint[1]-got.hint[4]!==18)bad.push('hint→button gap '+(got.button[1]-got.hint[1]-got.hint[4])+', want 18');
  // At 1280×800 the Swift tests pin these from the content top (345 and 387 below the 38 px title bar).
  if(got.hint&&got.button&&(got.hint[1]!==383||got.button[1]!==425))bad.push('hint top '+got.hint[1]+' / button top '+got.button[1]+', want 383 / 425');
  if(got.chips||over.chips)bad.push('shows the chips row');if(!got.onTop)bad.push('centre button is covered');
  // Drag-over keeps B4's feedback: the wall fades and the drop prompt highlights with the accent (#311).
  if(!over.dragOver)bad.push('?drag=over: no drop target in drag-over');if(!(over.wallAlpha<got.wallAlpha))bad.push('?drag=over: wall does not fade ('+over.wallAlpha+' vs '+got.wallAlpha+')');
  if(over.promptColor!==over.accentText||got.promptColor===got.accentText)bad.push('?drag=over: drop prompt not highlighted ('+got.promptColor+' → '+over.promptColor+')');
  if(over.heading!=='松开即可打开')bad.push('?drag=over: hint reads '+JSON.stringify(over.heading)+', want 松开即可打开');
  if(!over.outline||/^rgba\(0, 0, 0, 0\)$|transparent/.test(over.outline))bad.push('?drag=over: no drop outline');
  if(bad.length)barIssues.push(url+': '+bad.join(', '));
 }
 // Reduce Motion stops the drift entirely.
 await page.emulateMedia({reducedMotion:'reduce'});await page.goto(base+'first-launch.html');if(await page.evaluate(()=>{const t=document.querySelector('.wall .tiles');return!t||getComputedStyle(t).animationName!=='none'}))barIssues.push('first-launch.html: wall drifts under Reduce Motion');await page.emulateMedia({reducedMotion:null});
 if(barIssues.length)throw Error('#317 Home and Bottom Bar: '+barIssues.join(' | '));
 // Sub-cases of 22-BD, 24 and 26-BC (ADR-014) are reachable by query; the bare URL is the pinned main case.
 const subcases=[
  ['empty-folder.html',{tiles:3,recents:0,buttons:['包含子文件夹浏览','选择其他文件夹…'],drop:true}],
  ['empty-folder.html?case=no-subfolders',{tiles:0,minRecents:1,maxRecents:10,buttons:['选择其他文件夹…'],drop:true}],
  ['empty-folder.html?theme=dark',{dark:true,tiles:3}],
  ['empty-folder.html?drag=over',{tiles:3,dragOver:true}],
  ['permission-denied.html',{unavailable:true,buttons:['重新选择文件夹…'],absent:['选择其他文件夹…']}],
  ['permission-denied.html?cause=volume',{focus:'选择其他文件夹…',unavailable:true,text:'等待磁盘连接',texts:['重新确认访问权限'],notText:['不需要再选择'],buttons:['选择其他文件夹…'],absent:['重新选择文件夹…']}],
  ...['case=volume','case=volume&theme=dark','cause=volume&theme=dark'].map(query=>['permission-denied.html?'+query,{dark:query.includes('theme=dark'),unavailable:true,text:'等待磁盘连接',buttons:['选择其他文件夹…'],absent:['重新选择文件夹…'],focus:'选择其他文件夹…'}]),
  ['permission-denied.html?cause=missing',{unavailable:true,text:'找不到',buttons:['在新位置选择…','选择其他文件夹…']}],
  ['permission-denied.html?cause=unknown',{unavailable:true,text:'无法访问此文件夹',buttons:['重新选择文件夹…','选择其他文件夹…']}],
  ['permission-denied.html?case=moved',{unavailable:false,strip:'不是这个？选择其他文件夹…',cells:true}],
  ['permission-denied.html?theme=dark',{dark:true,unavailable:true}],
  // 24 读取失败 (24F-A, #236): no partial grid or count, 「重试」 holds key focus, the footer reads 读取未完成.
  ['folder-loading.html',{focus:'取消读取',buttons:['取消读取'],absent:['重试'],noGrid:true,rootCount:''}],
  ['folder-loading.html?theme=dark',{dark:true,focus:'取消读取',buttons:['取消读取'],absent:['重试'],noGrid:true,rootCount:''}],
  ['folder-loading.html?case=failed',{text:'没能读完“待整理”',texts:['读取在中途停止了'],buttons:['重试','选择其他文件夹…'],absent:['取消读取'],focus:'重试',noGrid:true,noCount:true,footer:'读取未完成',tokens:'failed'}],
  ['folder-loading.html?case=failed&theme=dark',{dark:true,text:'没能读完“待整理”',buttons:['重试','选择其他文件夹…'],focus:'重试',noGrid:true,noCount:true,footer:'读取未完成'}],
 ];
 const subcaseFailures=[];
 for(const [url,want] of subcases){
  await page.setViewportSize({width:1280,height:800});await page.goto(base+url);await page.evaluate(async()=>Promise.all([...document.images].map(i=>i.decode().catch(()=>{}))));
  // orphanLine: no line of #state-text may hold only one or two characters (the 「次。」 wrap). Line breaks depend on the
  // fonts headless Chromium resolves, so the copy is measured at letter-spacing −1…+1 px to stand in for wider and narrower glyphs.
  const got=await page.evaluate(()=>{const visible=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';const buttons=[...document.querySelectorAll('main button')].filter(visible).map(b=>b.textContent.trim());const strip=document.querySelector('.follow-strip');return{dark:document.documentElement.classList.contains('theme-dark'),tiles:document.querySelectorAll('main .subfolder-tile').length,recents:document.querySelectorAll('main .recent-folder').length,buttons,text:document.querySelector('main').innerText,drop:!!document.querySelector('main [data-drop-target]'),dragOver:!!document.querySelector('main [data-drop-target].is-drag-over'),unavailable:!!document.querySelector('.sidebar .ds-nav-row.is-unavailable .row-warning'),collapsed:(r=>!!r&&r.getAttribute('aria-expanded')==='false'&&visible(r.querySelector('.row-disclosure'))&&!document.querySelector('.sidebar .folder-children'))(document.querySelector('.sidebar .ds-nav-row.is-unavailable')),pendingRows:[...document.querySelectorAll('.sidebar .ds-nav-row')].filter(r=>/个人收藏|最近查看/.test(r.innerText)).map(r=>r.dataset.pending==='P3-14'),pendingHeading:(m=>!!m&&visible(m)&&m.innerText.includes('PENDING(P3-14)'))(document.querySelector('.sidebar .library-toggle [data-pending="P3-14"]')),pendingSentence:(e=>!e||(!!e.closest('[data-pending="P3-14"]')&&e.closest('[data-pending="P3-14"]').innerText.includes('PENDING(P3-14)')))([...document.querySelectorAll('#state-text *, #state-text')].find(e=>[...e.childNodes].some(n=>n.nodeType===3&&n.textContent.includes('收藏和最近查看')))),sentence:document.querySelector('main').innerText.includes('收藏和最近查看'),tileLabels:[...document.querySelectorAll('main .subfolder-tile')].map(t=>t.getAttribute('aria-label')||''),tileGroup:(g=>!g||g.getAttribute('role')==='group')(document.querySelector('main .subfolder-tiles')),orphanLine:(p=>{if(!p)return '';for(let t=-10;t<=10;t++){p.style.letterSpacing=t/10+'px';const lines=new Map();const walk=document.createTreeWalker(p,NodeFilter.SHOW_TEXT);for(let n;(n=walk.nextNode());)for(let i=0;i<n.length;i++){if(!n.textContent[i].trim())continue;const r=document.createRange();r.setStart(n,i);r.setEnd(n,i+1);const b=r.getClientRects()[0];if(!b)continue;const k=Math.round(b.top);lines.set(k,(lines.get(k)||'')+n.textContent[i])}const o=[...lines.values()].find(l=>l.length<=2);if(o){p.style.letterSpacing='';return o+' at letter-spacing '+t/10+'px'}}p.style.letterSpacing='';return ''})(document.querySelector('#state-text')),strip:strip&&visible(strip)?strip.innerText:'',cells:document.querySelectorAll('main .photo-cell').length,focus:(a=>a&&a.closest('main')?a.textContent.trim():'')(document.activeElement),focusRing:(a=>!!a&&a!==document.body&&getComputedStyle(a).outlineStyle!=='none'&&parseFloat(getComputedStyle(a).outlineWidth)>0)(document.activeElement),footer:(e=>e?e.innerText.replace(/\s+/g,' ').trim():'')(document.querySelector('.grid-bottom-bar .grid-file-status')),rootCount:(e=>e?e.innerText.trim():'')(document.querySelector('.sidebar .ds-nav-row[aria-current="page"] .row-count')),caseStyles:Object.fromEntries([...document.querySelectorAll('style[data-case]')].map(e=>[e.dataset.case,e.textContent])),shell:visible(document.querySelector('.sidebar'))&&visible(document.querySelector('.grid-bottom-bar')),broken:[...document.images].some(i=>!i.complete||!i.naturalWidth),overflow:document.documentElement.scrollWidth>innerWidth}});
  const bad=[];if(!got.shell)bad.push('sidebar/footer missing');if(got.broken||got.overflow)bad.push('resource/layout');
  if(want.dark&&!got.dark)bad.push('not dark');if('tiles' in want&&got.tiles!==want.tiles)bad.push('tiles '+got.tiles);if('recents' in want&&got.recents!==want.recents)bad.push('recents '+got.recents);
  if(want.minRecents&&(got.recents<want.minRecents||got.recents>want.maxRecents))bad.push('recents '+got.recents);if(want.drop&&!got.drop)bad.push('no drop target');if(want.dragOver&&!got.dragOver)bad.push('no drag-over affordance');
  for(const b of want.buttons||[])if(!got.buttons.includes(b))bad.push('missing button '+b);for(const b of want.absent||[])if(got.buttons.includes(b))bad.push('unexpected button '+b);
  if(want.text&&!got.text.includes(want.text))bad.push('missing text '+want.text);if('unavailable' in want&&got.unavailable!==want.unavailable)bad.push('sidebar unavailable='+got.unavailable);
  if(want.unavailable&&!got.collapsed)bad.push('subfolders not drawn collapsed (aria-expanded=false + disclosure)');if(url.startsWith('permission-denied')){if(got.pendingRows.length!==2||!got.pendingRows.every(Boolean)||!got.pendingHeading)bad.push('个人收藏/最近查看 rows not marked PENDING(P3-14)');if(want.unavailable&&!got.sentence)bad.push('missing 收藏和最近查看 sentence');if(!got.pendingSentence)bad.push('收藏和最近查看 sentence not marked PENDING(P3-14)')}if(!got.tileGroup)bad.push('subfolder tiles not a group');for(const l of got.tileLabels)if(!/^\S.*，子文件夹$/.test(l))bad.push('tile label '+JSON.stringify(l));if(got.orphanLine)bad.push('orphan line '+JSON.stringify(got.orphanLine));for(const s of want.texts||[])if(!got.text.includes(s))bad.push('missing text '+s);for(const s of want.notText||[])if(got.text.includes(s))bad.push('unexpected text '+s);if(want.strip&&!got.strip.includes(want.strip))bad.push('missing strip');if(want.cells&&!got.cells)bad.push('no grid');if(want.noGrid&&got.cells)bad.push('partial grid '+got.cells);if(want.focus&&(got.focus!==want.focus||!got.focusRing))bad.push('focus on '+JSON.stringify(got.focus)+(got.focusRing?'':' without a ring')+' instead of '+want.focus);if(want.footer&&got.footer.replace(/^— /,'')!==want.footer)bad.push('footer '+JSON.stringify(got.footer));if('rootCount' in want&&got.rootCount!==want.rootCount)bad.push('folder row count '+JSON.stringify(got.rootCount));if(want.noCount&&(/\d/.test(got.footer)||got.rootCount!=='—'))bad.push('partial count: footer '+JSON.stringify(got.footer)+', folder row '+JSON.stringify(got.rootCount));if(want.tokens){const css=got.caseStyles[want.tokens];if(css===undefined)bad.push('no style[data-case='+want.tokens+']');else{const lit=css.match(/#[0-9a-f]{3,8}\b|\b(?:rgba?|hsla?)\(|font(?:-size)?:\s*\d[^;}]*/gi);if(lit)bad.push('non-token values '+JSON.stringify(lit))}}
  if(bad.length)subcaseFailures.push(url+': '+bad.join(', '));
 }
 if(subcaseFailures.length)throw Error('22/24/26 sub-cases: '+subcaseFailures.join(' | '));
 // Settings (B) and the shortcut list (C): every section and card by query, light and dark, examples labelled.
 const windowCases=[['settings.html',{section:'general'}],...SETTINGS_SECTIONS.map(([id])=>['settings.html?section='+id,{section:id}]),['settings.html?theme=dark',{section:'general',dark:true}],['settings.html?section=about&theme=dark',{section:'about',dark:true}],
  ['shortcuts.html',{card:null}],...SHORTCUT_CARDS.map(([id])=>['shortcuts.html?card='+id,{card:id}]),['shortcuts.html?theme=dark',{card:null,dark:true}]];
 const windowFailures=[];
 for(const [url,want] of windowCases){
  await page.setViewportSize({width:1280,height:800});await page.goto(base+url);
  const got=await page.evaluate(()=>{const visible=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';const win=document.querySelector('.window');const r=win&&win.getBoundingClientRect();
   // A sample number (size, build, time) must sit inside a [data-example] element that says 示例.
   const unlabelled=[];const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);for(let n;(n=walk.nextNode());){if(!visible(n.parentElement)||!/\d+(\.\d+)?\s?(KB|MB|GB)|构建\s?\d+|\d{1,2}:\d{2}|\d+\.\d+\.\d+/.test(n.textContent))continue;const ex=n.parentElement.closest('[data-example]');if(!ex||!ex.innerText.includes('示例'))unlabelled.push(n.textContent.trim())}
   // A [data-coming-soon] group says 即将推出 and every control in it is disabled and out of the tab order.
   const controlsOf=e=>e.matches('button,input')?[e]:[...e.querySelectorAll('button,input')];
   const soon=[...document.querySelectorAll('[data-coming-soon]')].filter(e=>{const c=controlsOf(e);return!c.length||c.some(b=>!(b.disabled||b.getAttribute('aria-disabled')==='true')||b.tabIndex!==-1)||!e.innerText.includes('即将推出')||/<kbd/.test(e.innerHTML)}).map(e=>e.innerText.trim());
   const pane=[...document.querySelectorAll('.settings-pane')].find(visible);
   const controls=pane?[...pane.querySelectorAll('button,input')].map(b=>[b.getAttribute('aria-label')||b.innerText.trim(),b.closest('[data-coming-soon]')?'soon':'ready']):[];
   const rows=[...document.querySelectorAll('.shortcut-card li')].filter(visible);
   return{dark:document.documentElement.classList.contains('theme-dark'),window:!!win&&r.left>=0&&r.top>=0&&r.right<=innerWidth&&r.bottom<=innerHeight,
    sections:[...document.querySelectorAll('.settings-sidebar [data-section]')].map(b=>[b.dataset.section,b.innerText.trim()]),current:[...document.querySelectorAll('.settings-sidebar [aria-current="page"]')].map(b=>b.dataset.section),
    panes:[...document.querySelectorAll('.settings-pane')].filter(visible).map(p=>[p.dataset.section,(p.querySelector('h2')||{}).innerText]),
    cards:[...document.querySelectorAll('.shortcut-card')].filter(visible).map(c=>[c.dataset.card,c.querySelector('h3 .title').innerText,c.querySelector('h3 .when').innerText,c.querySelectorAll('[data-shortcut]').length]),
    targets:[...document.querySelectorAll('.shortcut-card.is-review-target')].map(c=>c.dataset.card),inputs:document.querySelectorAll('.shortcut-card input, .shortcut-window input').length,
    unlabelled,soon,controls,untagged:rows.filter(r=>!r.dataset.shortcut).map(r=>r.innerText.trim()),broken:[...document.images].some(i=>!i.complete||!i.naturalWidth),overflow:document.documentElement.scrollWidth>innerWidth}});
  const bad=[];if(!got.window)bad.push('window missing or outside the viewport');if(got.broken||got.overflow)bad.push('resource/layout');if(!!want.dark!==got.dark)bad.push('dark='+got.dark);
  if(got.unlabelled.length)bad.push('sample values not labelled 示例: '+got.unlabelled.join(' / '));if(got.soon.length)bad.push('coming-soon entries not greyed/unfocusable/「即将推出」: '+got.soon.join(' / '));
  if(url.startsWith('settings')){const label=SETTINGS_SECTIONS.find(([id])=>id===want.section)[1];
   if(JSON.stringify(got.sections)!==JSON.stringify(SETTINGS_SECTIONS))bad.push('sidebar '+JSON.stringify(got.sections));if(JSON.stringify(got.current)!==JSON.stringify([want.section]))bad.push('current '+got.current.join(','));
   if(JSON.stringify(got.panes)!==JSON.stringify([[want.section,label]]))bad.push('panes '+JSON.stringify(got.panes));
   if(JSON.stringify(got.controls)!==JSON.stringify(SETTINGS_CONTROLS[want.section]))bad.push('controls '+JSON.stringify(got.controls)+', want '+JSON.stringify(SETTINGS_CONTROLS[want.section]))}
  else{if(JSON.stringify(got.cards.map(c=>c.slice(0,3)))!==JSON.stringify(SHORTCUT_CARDS))bad.push('cards '+JSON.stringify(got.cards));if(got.cards.some(c=>!c[3]))bad.push('empty card');if(got.untagged.length)bad.push('rows without data-shortcut: '+got.untagged.join(' / '));
   if(JSON.stringify(got.targets)!==JSON.stringify(want.card?[want.card]:[]))bad.push('review target '+got.targets.join(','));if(got.inputs)bad.push('read-only list has inputs')}
  if(bad.length)windowFailures.push(url+': '+bad.join(', '));
 }
 if(windowFailures.length)throw Error('settings/shortcuts: '+windowFailures.join(' | '));
 // journeys.html: linked from the index, success-path playback, branches return, no hand-typed status, no prototype files.
 await page.setViewportSize({width:1440,height:900});await page.goto(base+'index.html');await page.getByRole('navigation',{name:'设计页面'}).waitFor();
 if(!await page.locator('a[href="journeys.html"]').count())throw Error('index.html does not link journeys.html');
 const jr=await page.goto(base+'journeys.html');if(!jr||!jr.ok())throw Error('journeys.html missing');await page.locator('section.journey#J1').waitFor();
 const journeyIssues=await page.evaluate(SETTINGS_SECTIONS=>{const issues=[];const html=document.documentElement.outerHTML;
  if(/prototype-[\w-]*\.html/.test(html))issues.push('references a prototype file');if(document.querySelector('.st')||/部分真机|仅单元|未开始/.test(document.body.innerText))issues.push('hand-typed status badges');
  for(const id of ['ENTRY','J1','J2','J3','J4','REF'])if(!document.getElementById(id))issues.push('missing section '+id);
  const rows=[...document.querySelectorAll('#ENTRY tbody tr')].map(r=>r.innerText.replace(/\s+/g,' '));if(rows.length<8)issues.push('entry table has fewer than 8 entrances');
  // ADR-0010, OPEN-03/04, ACCESS-01: a single image inside an access root scans without a prompt and Esc goes 24 → 11;
  // outside every root → asks for access and stays in the viewer, and Esc does nothing.
  for(const [what,re] of [['Finder',/访达/],['image drop',/图片拖进窗口/]]){const pair=rows.filter(r=>re.test(r));
   if(pair.length!==2)issues.push(what+' entrance is not split into in-root / not-in-root rows');
   else{if(!pair.some(r=>/(?<!不在)授权范围内/.test(r)&&/不弹授权/.test(r)&&/Esc\s*→\s*24[^]*→\s*11/.test(r)&&/当前项/.test(r)))issues.push(what+': in-root row lacks Esc → 24 → 11 with this image current, no prompt');
    if(!pair.some(r=>/不在授权范围/.test(r)&&/ACCESS-01/.test(r)&&/留在大图/.test(r)&&/Esc\s*无变化/.test(r)))issues.push(what+': not-in-root row lacks → asks for access, stays in viewer, Esc does nothing')}}
  const moved=document.querySelector('[data-branch="J1-moved"] .card');if(!moved||!/26M-C 已跟随到新位置/.test(moved.innerText)||/权限失效/.test(moved.innerText))issues.push('J1-moved card is not titled 26M-C 已跟随到新位置');
  const j4=[...document.querySelectorAll('#J4 .arrow .lab')].map(l=>l.innerHTML);if(!j4.some(l=>(l.match(/<kbd>Esc<\/kbd>/g)||[]).length>=2&&/Inspector/.test(l)))issues.push('J4: Esc order is not two steps');
  const failed=document.querySelector('[data-branch="J1-scan-failed"]');if(!failed||!failed.querySelector('.card[data-page="folder-loading"][data-query="case=failed"]')||failed.querySelector('.placeholder'))issues.push('J1-scan-failed does not link folder-loading.html?case=failed');
  const access=document.querySelector('[data-branch="J1-access"]');if(!access||!/选择其他文件夹/.test(access.innerText)||!/自动恢复/.test(access.innerText))issues.push('J1-access lacks 选择其他文件夹… and auto-recovery after mount');
  // Settings and Help → 键盘快捷键 are linked where they appear (#214): J4's display step and its return to the grid.
  if(!document.querySelector('[data-branch="J4-settings"] .card[data-page="settings"]'))issues.push('J4 does not link settings.html from 15');
  if(!document.querySelector('[data-branch="J4-shortcuts"] .card[data-page="shortcuts"]'))issues.push('J4 does not link shortcuts.html');
  for(const [id] of SETTINGS_SECTIONS.filter(([id])=>id!=='display'))if(!document.querySelector('[data-branch="J4-settings"] [data-page="settings"][data-query="section='+id+'"]'))issues.push('J4-settings lacks section '+id);
  if(/⚠ 还没挂到任何旅程/.test(document.body.innerText))issues.push('a state page is not on any journey');
  const branches=[...document.querySelectorAll('[data-branch]')];if(!branches.length)issues.push('no branches');
  for(const b of branches){if(!b.dataset.to)issues.push('branch without to: '+b.dataset.branch);else if(!b.querySelector('.ret'))issues.push('branch without return edge: '+b.dataset.branch)}
  return issues},SETTINGS_SECTIONS);
 const journeyIds=await page.locator('section.journey[data-main]').evaluateAll(s=>s.map(e=>e.id));
 for(const id of journeyIds){
  const main=JSON.parse(await page.locator('#'+id).getAttribute('data-main'));const play=page.locator('#'+id+' button.play');await play.click();
  if(!await page.evaluate(()=>!!document.activeElement.closest('#player')))journeyIssues.push(id+': focus not in player');
  const played=[];for(let n=0;n<40;n++){played.push(await page.locator('#player').getAttribute('data-page'));const next=page.locator('#p-next');if(await next.isDisabled())break;await next.click()}
  if(JSON.stringify(played)!==JSON.stringify(main))journeyIssues.push(id+': played '+played.join(',')+' instead of main path '+main.join(','));
  // A click inside the preview must not take the player's keys: Esc still closes and Tab stays in the dialog.
  const box=await page.locator('#p-frame').boundingBox();await page.mouse.click(box.x+box.width/2,box.y+box.height/2);
  await page.keyboard.press('Tab');if(!await page.evaluate(()=>!!document.activeElement.closest('#player')&&document.activeElement.tagName!=='IFRAME'))journeyIssues.push(id+': Tab after a click in the preview left the player controls');
  await page.mouse.click(box.x+box.width/2,box.y+box.height/2);await page.keyboard.press('Escape');if(await page.locator('#player').isVisible()){journeyIssues.push(id+': Esc after a click in the preview did not close');await page.locator('#p-close').click()}
  await play.click();
  for(let n=0;n<12;n++)await page.keyboard.press('Tab');if(!await page.evaluate(()=>!!document.activeElement.closest('#player')))journeyIssues.push(id+': Tab left the player');
  await page.keyboard.press('Escape');if(await page.locator('#player').isVisible())journeyIssues.push(id+': Esc did not close');
  if(!await page.evaluate(i=>document.activeElement===document.querySelector('#'+i+' button.play'),id))journeyIssues.push(id+': focus did not return');
 }
 if(journeyIds.length<4)journeyIssues.push('expected J1–J4 with data-main, got '+journeyIds.join(','));
 // Every branch outcome plays from its start through the branch page to its real destination.
 const branchPlayed={};let branchPlays=0;
 for(const button of await page.locator('[data-play-branch]').all()){
  const id=await button.getAttribute('data-play-branch');await button.click();const played=[];
  for(let n=0;n<10;n++){played.push(await page.locator('#player').evaluate(p=>p.dataset.page+(p.dataset.query?'?'+p.dataset.query:'')));const next=page.locator('#p-next');if(await next.isDisabled())break;await next.click()}
  (branchPlayed[id]=branchPlayed[id]||[]).push(played);branchPlays++;
  await page.waitForFunction(()=>{const frame=document.querySelector('#p-frame iframe');return frame?.contentDocument?.readyState==='complete'&&frame.contentDocument.URL===frame.src});
  await page.keyboard.press('Escape');if(await page.locator('#player').isVisible())throw Error(id+': branch Esc did not close the loaded preview');
  if(!await button.evaluate(b=>document.activeElement===b))throw Error(id+': branch Esc did not restore opener focus');
 }
 // Focused recovery actions in intermediate branch states must also leave the player with Escape.
 for(const [name,query,focus] of [['folder-loading','case=failed','重试'],['permission-denied','cause=volume','选择其他文件夹…']]){
  const opener=page.locator('[data-page="'+name+'"][data-query="'+query+'"]').first();await opener.click();
  await page.waitForFunction(()=>{const frame=document.querySelector('#p-frame iframe');return frame?.contentDocument?.readyState==='complete'&&frame.contentDocument.URL===frame.src});
  const actual=await page.locator('#p-frame iframe').evaluate(frame=>frame.contentDocument.activeElement.textContent.trim());
  if(actual!==focus)throw Error(name+'?'+query+': embedded focus '+JSON.stringify(actual)+' instead of '+focus);
  await page.keyboard.press('Escape');if(await page.locator('#player').isVisible())throw Error(name+'?'+query+': embedded Esc did not close');
  if(!await opener.evaluate(b=>document.activeElement===b))throw Error(name+'?'+query+': embedded Esc did not restore opener focus');
 }
 // Player keys must work from the preview's real startup focus, including reverse Tab entry.
 const waitForJourneyPreview=()=>page.waitForFunction(()=>{const frame=document.querySelector('#p-frame iframe');return frame?.contentDocument?.readyState==='complete'&&frame.contentDocument.URL===frame.src});
 const playerPosition=()=>page.locator('#player').evaluate(p=>({open:!p.hidden&&p.classList.contains('open'),page:p.dataset.page,query:p.dataset.query,step:document.getElementById('p-step').textContent.split(' · ')[0]}));
 const focusedJourneyKeys=[
  {name:'main J1 reading',opener:'[data-play="J1"]',page:'folder-loading',query:'',focus:'取消读取',left:'first-launch',right:'grid-light'},
  {name:'J1-access volume',opener:'[data-play-branch="J1-access"][data-out="3"]',page:'permission-denied',query:'cause=volume',focus:'选择其他文件夹…',left:'grid-light',right:'grid-light'},
 ];
 for(const sample of focusedJourneyKeys)for(const key of ['ArrowRight','ArrowLeft','Tab','Shift+Tab']){
  const opener=page.locator(sample.opener);await opener.click();await page.locator('#p-next').click();await waitForJourneyPreview();
  const focused=await page.locator('#p-frame iframe').evaluate(frame=>({parentIsFrame:document.activeElement===frame,child:frame.contentDocument.activeElement.textContent.trim()}));
  if(!focused.parentIsFrame||focused.child!==sample.focus)journeyIssues.push(sample.name+' '+key+': startup focus '+JSON.stringify(focused));
  await page.keyboard.press(key);
  const got=await playerPosition();
  if(key.startsWith('Arrow')){
   const expected={open:true,page:key==='ArrowRight'?sample.right:sample.left,query:'',step:(key==='ArrowRight'?'3':'1')+' / 3'};
   if(JSON.stringify(got)!==JSON.stringify(expected))journeyIssues.push(sample.name+' '+key+': position '+JSON.stringify(got)+' instead of '+JSON.stringify(expected));
  }else{
   const correctControl=await page.evaluate(reverse=>{const controls=[...document.querySelectorAll('#player button, #player a[href]')].filter(x=>!x.disabled);return document.activeElement===controls[reverse?controls.length-1:0]},key==='Shift+Tab');
   if(!correctControl)journeyIssues.push(sample.name+' '+key+': focus did not enter the '+(key==='Shift+Tab'?'last':'first')+' enabled parent control');
   if(!got.open||got.page!==sample.page||got.query!==sample.query||got.step!=='2 / 3')journeyIssues.push(sample.name+' '+key+': changed position '+JSON.stringify(got));
  }
  await page.locator('#p-close').click();
 }
 // A parent-focused arrow must not run twice and skip over the middle step.
 await page.locator('[data-play="J1"]').click();await waitForJourneyPreview();await page.locator('#p-next').focus();
 if(!await page.locator('#p-next').evaluate(button=>document.activeElement===button&&!button.disabled))journeyIssues.push('parent ArrowRight: next control did not receive focus');
 await page.keyboard.press('ArrowRight');
 const parentPosition=await playerPosition();
 if(!parentPosition.open||parentPosition.page!=='folder-loading'||parentPosition.query!==''||parentPosition.step!=='2 / 3')journeyIssues.push('parent ArrowRight: advanced other than one step '+JSON.stringify(parentPosition));
 await page.locator('#p-close').click();
 // A real sandboxed navigation supplies an opaque document; do not fake contentDocument.
 const opaqueErrors=[],onOpaqueError=error=>opaqueErrors.push(error.message);page.on('pageerror',onOpaqueError);
 try{
  const opener=page.locator('[data-play="J1"]');await opener.click();await waitForJourneyPreview();
  const opaque=await page.locator('#p-frame iframe').evaluate(frame=>new Promise(resolve=>{
   frame.addEventListener('load',()=>resolve(frame.contentDocument===null),{once:true});
   frame.setAttribute('sandbox','allow-scripts');const url=new URL(frame.src);url.searchParams.set('opaque-preview-check','1');frame.src=url.href;
  }));
  if(!opaque)journeyIssues.push('opaque preview: contentDocument was not null');
  await page.locator('#p-close').click();
  if(await page.locator('#player').isVisible())journeyIssues.push('opaque preview: parent close button did not close');
  if(!await opener.evaluate(button=>document.activeElement===button))journeyIssues.push('opaque preview: parent close did not restore opener focus');
  if(opaqueErrors.length)journeyIssues.push('opaque preview pageerror: '+opaqueErrors.join(' | '));
 }finally{page.off('pageerror',onOpaqueError)}
 const sortedJSON=o=>JSON.stringify(Object.keys(o).sort().map(k=>[k,o[k].map(s=>s.join('>')).sort()]));
 if(sortedJSON(branchPlayed)!==sortedJSON(BRANCH_PLAYS))for(const id of new Set([...Object.keys(BRANCH_PLAYS),...Object.keys(branchPlayed)])){const want=(BRANCH_PLAYS[id]||[]).map(s=>s.join('>')).sort(),got=(branchPlayed[id]||[]).map(s=>s.join('>')).sort();if(JSON.stringify(want)!==JSON.stringify(got))journeyIssues.push(id+': branch plays '+(got.join(' ; ')||'none')+' instead of '+(want.join(' ; ')||'none'))}
 if(journeyIssues.length)throw Error('journeys.html: '+journeyIssues.join(' | '));
 await page.setViewportSize({width:1280,height:800});await page.goto(states+'/index.html');await page.getByRole('navigation',{name:'设计页面'}).waitFor();
 await page.getByRole('button',{name:'33 胶片条展开 · C',exact:true}).click();await page.frameLocator('iframe').locator('.c-filmstrip').waitFor();
 if(screenshot)await page.screenshot({path:screenshot});
 await page.goto(design+'/prototypes/picsee-browser/viewer-v2.html');await page.getByTestId('large-viewer').waitFor();await page.keyboard.press('Escape');if(await page.locator('.photo-cell').count()!==12)throw Error('Interactive prototype regression');
 if(errors.length||failures.length)throw Error(JSON.stringify({errors,failures}));return{passed:true,stateCount:results.length,hashesPinned:catalog.states.length,viewerToolVariants,thumbnailSizeVariants,contrastTable,geometryTable,subcases:subcases.length+windowCases.length,journeys:journeyIds,branchPlays,canonicalPreview:true,legacy4313Preview:true,interactivePrototype:true,results,errors,failures};
};

// Direct invocation runs the same real browser verification as the supported npm runner.
if(require.main===module){
 const run=require('node:child_process').spawnSync(process.execPath,[require('node:path').join(__dirname,'design-check.mjs')],{stdio:'inherit'});
 process.exit(run.status??1);
}
