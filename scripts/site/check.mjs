#!/usr/bin/env node
import { readdir, readFile, realpath, stat } from 'node:fs/promises';
import { dirname, extname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const defaultSite = resolve(dirname(fileURLToPath(import.meta.url)), '../../site');
const assets = new Set(['.css', '.js', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico', '.woff', '.woff2']);

async function filesIn(dir) {
  const files = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) files.push(...await filesIn(full));
    else files.push(full);
  }
  return files;
}

function decodeEntities(value) {
  return value.replace(/&#(?:x([0-9a-f]+)|([0-9]+));?/gi, (match, hex, decimal) => {
    const number = Number.parseInt(hex ?? decimal, hex ? 16 : 10);
    return number > 0 && number <= 0x10ffff ? String.fromCodePoint(number) : match;
  }).replace(/&(?:amp|quot|apos|lt|gt|nbsp);/gi, match => ({
    '&amp;': '&', '&quot;': '"', '&apos;': "'", '&lt;': '<', '&gt;': '>', '&nbsp;': ' ',
  })[match.toLowerCase()] ?? match);
}

// Read start tags through a quoted >. HTML permits bare, single-quoted and double-quoted values.
function* startTags(html) {
  for (let i = 0; i < html.length; i++) {
    if (html[i] !== '<' || !/[A-Za-z]/.test(html[i + 1] ?? '')) continue;
    let end = i + 1, quote = '';
    for (; end < html.length; end++) {
      const char = html[end];
      if (quote) { if (char === quote) quote = ''; }
      else if (char === '"' || char === "'") quote = char;
      else if (char === '>') break;
    }
    if (end >= html.length) break;
    const raw = html.slice(i + 1, end);
    const tag = /^[A-Za-z][\w:-]*/.exec(raw)?.[0]?.toLowerCase();
    if (!tag) continue;
    const attributes = new Map();
    const source = raw.slice(tag.length);
    const pattern = /([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'`=<>]+)))?/g;
    for (const match of source.matchAll(pattern)) {
      attributes.set(match[1].toLowerCase(), decodeEntities(match[2] ?? match[3] ?? match[4] ?? ''));
    }
    yield { tag, attributes };
    i = end;
  }
}

function visibleText(html) {
  // A labelled link to a public issue is useful user-facing text, not an internal ticket note.
  const withoutPublicIssues = html.replace(/<a\b([^>]*\bhref\s*=\s*["']?https:\/\/github\.com\/anzchy\/mado\/issues\/\d+[^>]*)>([^]*?)<\/a>/gi,
    (whole, attrs, body) => /^\s*Issue\s+#\d+\s*$/i.test(body.replace(/<[^>]+>/g, '')) ? `<a ${attrs}></a>` : whole);
  return decodeEntities(withoutPublicIssues.replace(/<!--[^]*?-->/g, ' ')
    .replace(/<(style|script)\b[^>]*>[^]*?<\/\1\s*>/gi, ' ')
    .replace(/<[^>]+>/g, ' '));
}

const forbidden = [
  [/内部(?:备注|说明|笔记)|(?:internal|implementation) notes?|TODO|FIXME|owner\s*confirm|待确认|\bTBD\b|\bWIP\b|原型|预览版|发布前|待核对|尚未.{0,12}核对/gi, 'internal note'],
  [/#\d+\b/g, 'ticket number'],
  [/云端识别/g, 'use 云识别'],
  [/recogniz[a-z]*/gi, 'use British spelling: Recognise'],
  [/organiz[a-z]*/gi, 'use British spelling: Organise'],
  [/[“”]/g, 'use 「」 for Chinese UI labels'],
  [/(?<!访问)密钥/g, 'use 访问密钥'],
];

function scanText(label, source, errors) {
  const hits = [];
  for (const [pattern, message] of forbidden) {
    for (const match of source.matchAll(pattern)) hits.push({ index: match.index, message, value: match[0] });
  }
  hits.sort((a, b) => a.index - b.index);
  for (const hit of hits) {
    const location = label.endsWith(': HTML comment') && hit.message === 'internal note'
      ? `${label.slice(0, -': HTML comment'.length)}: internal note in HTML comment`
      : `${label}: ${hit.message}`;
    const value = hit.message.includes('Recognise') ? `Recognize variant: ${hit.value}` : hit.value;
    errors.push(`${location} (${value})`);
  }
}

function scanDraftBanner(label, source, errors) {
  if (/(?:^|[\s。！？.!])(?:草稿|draft)\s*[:：]/i.test(source)) errors.push(`${label}: draft banner`);
}

function inside(site, target) {
  const rel = relative(site, target);
  return rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

async function localReferenceError(site, page, value, kind, tag, attributes) {
  if (/^(?:https?:|mailto:|tel:|data:|#)/i.test(value)) return null;
  let decoded;
  try { decoded = decodeURIComponent(value.split(/[?#]/, 1)[0]); }
  catch { return `invalid ${kind}: ${value}`; }
  if (!decoded) return null;
  if (/^[a-z][\w+.-]*:/i.test(decoded) || decoded.startsWith('//')) return `unsupported ${kind}: ${value}`;
  const sitePath = decoded === '/mado' ? '' : decoded.startsWith('/mado/') ? decoded.slice('/mado/'.length)
    : decoded.startsWith('/') ? decoded.slice(1) : null;
  let target = resolve(sitePath === null ? dirname(page) : site, sitePath ?? decoded);
  if (decoded.endsWith('/') || decoded === '/mado') target = join(target, 'index.html');
  if (!inside(site, target)) return `${kind} escapes site: ${value}`;
  let actual;
  try { actual = await realpath(target); }
  catch { return `unresolved internal ${kind}: ${value}`; }
  if (!inside(site, actual)) return `${kind} escapes site: ${value}`;
  if (!(await stat(actual)).isFile()) return `${kind} is not a file: ${value}`;
  if (kind === 'href' && extname(actual).toLowerCase() !== '.html') {
    const extension = extname(actual).toLowerCase();
    const rel = new Set((attributes.get('rel') ?? '').toLowerCase().split(/\s+/));
    const stylesheet = tag === 'link' && rel.has('stylesheet') && extension === '.css';
    const icon = tag === 'link' && rel.has('icon') && new Set(['.ico', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg']).has(extension);
    if (!stylesheet && !icon) return `link is not a page: ${value}`;
  }
  return null;
}

export async function checkSite(siteDir = defaultSite) {
  const site = await realpath(resolve(siteDir));
  const errors = [];
  const files = await filesIn(site);
  const pages = files.filter(file => extname(file).toLowerCase() === '.html');
  if (!pages.length) errors.push('site: no HTML pages');
  for (const file of files) {
    const label = relative(site, file);
    const extension = extname(file).toLowerCase();
    if (extension !== '.html' && !assets.has(extension)) errors.push(`${label}: file type is not a page or asset`);
    const actual = await realpath(file);
    if (!inside(site, actual)) errors.push(`${label}: file escapes site`);
  }
  for (const page of pages) {
    const html = await readFile(page, 'utf8');
    const label = relative(site, page);
    const text = visibleText(html);
    scanText(label, text, errors);
    if (/<h[1-6]\b[^>]*>\s*(?:草稿|draft)\s*<\/h[1-6]>/i.test(html))
      errors.push(`${label}: draft banner`);
    scanDraftBanner(label, text, errors);
    for (const comment of html.matchAll(/<!--([^]*?)-->/g)) {
      const source = decodeEntities(comment[1]);
      scanText(`${label}: HTML comment`, source, errors);
      scanDraftBanner(`${label}: HTML comment`, source, errors);
    }
    for (const block of html.matchAll(/<(style|script)\b[^>]*>([^]*?)<\/\1\s*>/gi))
      scanText(`${label}: ${block[1].toLowerCase()}`, decodeEntities(block[2]), errors);
    if (label === 'screen-recording.html' &&
        (!text.includes('录屏与系统录音') || !text.includes('Screen & System Audio Recording') || !text.includes('「Mado」一行')))
      errors.push(`${label}: name Screen & System Audio Recording and the Mado row to enable`);
    for (const { tag, attributes } of startTags(html)) {
      if (tag === 'meta' && attributes.get('name')?.toLowerCase() === 'robots' &&
          /(?:^|[\s,])noindex(?:$|[\s,])/i.test(attributes.get('content') ?? ''))
        errors.push(`${label}: robots noindex`);
      if (attributes.get('class')?.split(/\s+/).some(value => /^(?:proto|draft)$/i.test(value))) errors.push(`${label}: proto or draft banner class`);
      for (const name of ['content', 'alt', 'title', 'aria-label']) {
        if (attributes.has(name)) {
          scanText(`${label}: ${name}`, attributes.get(name), errors);
          scanDraftBanner(`${label}: ${name}`, attributes.get(name), errors);
        }
      }
      for (const kind of ['href', 'src']) {
        if (!attributes.has(kind)) continue;
        const value = attributes.get(kind);
        const error = await localReferenceError(site, page, value, kind, tag, attributes);
        if (error) errors.push(`${label}: ${error}`);
      }
    }
  }
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const errors = await checkSite(process.argv[2]);
    for (const error of errors) console.error(error);
    console.log(`site: ${errors.length ? 'FAIL' : 'PASS'} (${errors.length} errors)`);
    process.exitCode = errors.length ? 1 : 0;
  } catch (error) {
    console.error(`site: FAIL (${error.message})`);
    process.exitCode = 1;
  }
}
