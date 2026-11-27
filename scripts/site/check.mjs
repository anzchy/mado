#!/usr/bin/env node
import { readdir, readFile, stat } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const defaultSite = resolve(dirname(fileURLToPath(import.meta.url)), '../../site');

async function pagesIn(dir) {
  const pages = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) pages.push(...await pagesIn(full));
    else if (entry.isFile() && entry.name.endsWith('.html')) pages.push(full);
  }
  return pages;
}

function visibleText(html) {
  return html.replace(/<!--[^]*?-->/g, ' ')
    .replace(/<(style|script)\b[^>]*>[^]*?<\/\1\s*>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/gi, '&').replace(/&(?:nbsp|quot);/gi, ' ');
}

const forbidden = [
  [/草稿|\bdraft\b/i, 'draft banner'],
  [/内部(?:备注|说明|笔记)|(?:internal|implementation) notes?|TODO|FIXME/i, 'internal note'],
  [/#\d+\b/, 'ticket number'],
  [/发布前|待核对|尚未.{0,12}核对/, 'internal publication note'],
  [/云端识别/, 'use 云识别'],
  [/Recogniz(?:e|ed|ing)\b/, 'use British spelling: Recognise'],
  [/[“”]/, 'use 「」 for Chinese UI labels'],
  [/(?<!访问)密钥/, 'use 访问密钥'],
];

async function linkError(site, page, href) {
  if (/^(?:https?:|mailto:|tel:|#)/i.test(href)) return null;
  let decoded;
  try { decoded = decodeURIComponent(href.split(/[?#]/, 1)[0]); }
  catch { return `invalid link: ${href}`; }
  if (!decoded) return null;
  if (/^[a-z][\w+.-]*:/i.test(decoded) || decoded.startsWith('//')) return `unsupported link: ${href}`;
  const sitePath = decoded.startsWith('/mado/') ? decoded.slice('/mado/'.length)
    : decoded.startsWith('/') ? decoded.slice(1) : null;
  let target = resolve(sitePath === null ? dirname(page) : site, sitePath ?? decoded);
  if (decoded.endsWith('/')) target = join(target, 'index.html');
  const rel = relative(site, target);
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return `link escapes site: ${href}`;
  try {
    if (!(await stat(target)).isFile() || !target.endsWith('.html')) return `link is not a page: ${href}`;
  } catch { return `unresolved internal link: ${href}`; }
  return null;
}

export async function checkSite(siteDir = defaultSite) {
  const site = resolve(siteDir);
  const errors = [];
  const pages = await pagesIn(site);
  if (!pages.length) return ['site: no HTML pages'];
  for (const page of pages) {
    const html = await readFile(page, 'utf8');
    const label = relative(site, page);
    const text = visibleText(html);
    for (const [pattern, message] of forbidden) {
      if (pattern.test(text)) errors.push(`${label}: ${message} (${pattern.exec(text)?.[0]})`);
    }
    for (const comment of html.matchAll(/<!--([^]*?)-->/g)) {
      for (const [pattern, message] of forbidden.slice(0, 4)) {
        if (pattern.test(comment[1])) errors.push(`${label}: ${message} in HTML comment`);
      }
    }
    if (label === 'screen-recording.html' &&
        (!text.includes('录屏与系统录音') || !text.includes('Screen & System Audio Recording') ||
         !text.includes('「Mado」一行'))) {
      errors.push(`${label}: name Screen & System Audio Recording and the Mado row to enable`);
    }
    for (const match of html.matchAll(/\bhref\s*=\s*(["'])(.*?)\1/gi)) {
      const error = await linkError(site, page, match[2].replace(/&amp;/g, '&'));
      if (error) errors.push(`${label}: ${error}`);
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
