#!/usr/bin/env node
// Decides whether a CI run must run the native (macOS) jobs. Only a pull request whose complete changed-file list lies
// inside a reviewed allowlist of documentation and agent files skips them; anything else, and any doubt, is native.
// Push, workflow_dispatch and every other event always run everything.
//
//   node scripts/ci/native-inputs.mjs   (in GitHub Actions; writes native=true|false to $GITHUB_OUTPUT)
//
// Reads GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_REPOSITORY, GITHUB_API_URL, GH_TOKEN. Lists the files with
// GET /repos/{repo}/pulls/{n}/files (100 per page). The list is trusted only when every page parses, every entry is
// well formed and the count equals the event's pull_request.changed_files. GitHub returns at most 3000 files.
import { appendFileSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Paths no native build or test reads (reviewed 2026-11-04, docs/audit/20261104-github-actions-audit.md §4 F6).
// Keep this explicit: a root `*.md` glob would wrongly include THIRD_PARTY_NOTICES.md, which App tests read.
export const SKIP_PREFIXES = ['docs/', '.agents/', '.claude/', '.codex/', 'scripts/agents/', 'scripts/codex-rules/',
  'scripts/ledger/', '.github/ISSUE_TEMPLATE/'];
export const SKIP_FILES = ['AGENTS.md', 'CLAUDE.md', 'README.md', 'CHANGELOG.md', 'GLOSSARY.md',
  '.github/workflows/pr-body.yml', '.github/workflows/release.yml'];
export const PER_PAGE = 100;
export const MAX_FILES = 3000;
const STATUSES = new Set(['added', 'removed', 'modified', 'renamed', 'copied', 'changed', 'unchanged']);

export function skippable(file) {
  if (typeof file !== 'string' || !file || file.startsWith('/') || file.includes('\\') ||
      file.split('/').some(part => part === '' || part === '.' || part === '..')) return false;
  return SKIP_FILES.includes(file) || SKIP_PREFIXES.some(prefix => file.startsWith(prefix));
}

/** Pure decision. `pages` is the list of parsed page bodies, in order. */
export function classify({ event, changedFiles, pages }) {
  const native = reason => ({ native: true, reason });
  if (event !== 'pull_request') return native(`event ${event} always runs native jobs`);
  if (!Number.isInteger(changedFiles) || changedFiles <= 0) return native('pull_request.changed_files missing or zero');
  if (changedFiles >= MAX_FILES) return native(`changed_files ${changedFiles} reaches the ${MAX_FILES}-file API cap`);
  if (!Array.isArray(pages) || pages.length === 0) return native('no file list');
  const files = [];
  let counted = 0;
  for (const [index, page] of pages.entries()) {
    if (!Array.isArray(page)) return native(`page ${index + 1} is not a list`);
    if (page.length > PER_PAGE || (index < pages.length - 1 && page.length !== PER_PAGE)) {
      return native(`page ${index + 1} has ${page.length} entries`);
    }
    for (const entry of page) {
      if (!entry || typeof entry !== 'object' || typeof entry.filename !== 'string' || !STATUSES.has(entry.status)) {
        return native('malformed file entry');
      }
      const paths = [entry.filename];
      if (entry.status === 'renamed' || entry.status === 'copied') {
        if (typeof entry.previous_filename !== 'string') return native(`${entry.status} entry without previous_filename`);
        paths.push(entry.previous_filename);
      } else if (entry.previous_filename !== undefined) {
        return native('previous_filename on a non-rename entry');
      }
      counted++;
      files.push(...paths);
    }
  }
  if (counted !== changedFiles) return native(`listed ${counted} files, event says ${changedFiles}`);
  const outside = files.find(file => !skippable(file));
  if (outside !== undefined) return native(`native input changed: ${outside}`);
  return { native: false, reason: `all ${counted} changed files are documentation or agent files` };
}

/** Fetches every page until a short page; returns null on any HTTP or parse failure. */
export async function fetchPages({ api, repo, number, token, fetchImpl = fetch }) {
  const pages = [];
  for (let page = 1; page <= MAX_FILES / PER_PAGE; page++) {
    let body;
    try {
      const response = await fetchImpl(`${api}/repos/${repo}/pulls/${number}/files?per_page=${PER_PAGE}&page=${page}`, {
        headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${token}`, 'x-github-api-version': '2022-11-28' },
      });
      if (!response.ok) return null;
      body = JSON.parse(await response.text());
    } catch {
      return null;
    }
    pages.push(body);
    if (!Array.isArray(body) || body.length < PER_PAGE) return pages;
  }
  return pages;
}

export async function main(env = process.env, { fetchImpl = fetch, log = console.log } = {}) {
  let result;
  try {
    const event = env.GITHUB_EVENT_NAME;
    if (event !== 'pull_request') {
      result = classify({ event });
    } else {
      const payload = JSON.parse(readFileSync(env.GITHUB_EVENT_PATH, 'utf8'));
      const pr = payload.pull_request;
      const pages = await fetchPages({ api: env.GITHUB_API_URL || 'https://api.github.com', repo: env.GITHUB_REPOSITORY,
        number: pr?.number, token: env.GH_TOKEN, fetchImpl });
      result = pages ? classify({ event, changedFiles: pr?.changed_files, pages }) : { native: true, reason: 'file list request failed' };
    }
  } catch (error) {
    result = { native: true, reason: `classifier error: ${error.message}` };
  }
  log(`native-inputs: native=${result.native} (${result.reason})`);
  if (env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT, `native=${result.native}\n`);
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
