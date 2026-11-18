#!/usr/bin/env node
// A review aid: findings require explanation, not an automatic failure.
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const base = args[args.indexOf('--base') + 1] || 'origin/main';
const head = args.includes('--head') ? args[args.indexOf('--head') + 1] : 'HEAD';
function git(...argv) {
  const r = spawnSync('git', argv, { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr.trim() || `git ${argv[0]} failed`);
  return r.stdout;
}
function count(text) {
  const source = text.split(/\r?\n/).map(codeOnly).join('\n');
  return (source.match(/\bfunc\s+test\w+\s*\(|@Test\b|\btest\s*\(/g) || []).length;
}
const isTestFile = file => /(?:^|\/)(?:[^/]+\.test\.[cm]?js|[^/]+\.test\.swift|test_[^/]+\.py|[^/]+Tests?\.swift|[^/]+Spec\.swift|app-quarantine\.json)$/i.test(file);
function codeOnly(line) {
  let result = '';
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (char === '/' && line[i + 1] === '/' || char === '#' && !line.slice(i).startsWith('#expect')) break;
    if (char === '"' || char === "'" || char === '`') {
      result += '""';
      while (++i < line.length) {
        if (line[i] === '\\') { i++; continue; }
        if (line[i] === char) break;
      }
      continue;
    }
    result += char;
  }
  return result;
}
const assertion = /#expect\s*\(|XCTAssert\w*\s*\(/;
const timeLimit = /\.timeLimit\s*\(/;
const numericTimeout = /\btimeout\s*:\s*(\d+(?:\.\d+)?)/;
function timeLimitValue(line) {
  const m = line.match(/\.timeLimit\s*\(\s*\.(seconds|milliseconds|minutes)\s*\(\s*(\d+(?:\.\d+)?)/);
  return m ? Number(m[2]) * ({ milliseconds: .001, seconds: 1, minutes: 60 })[m[1]] : null;
}
try {
  const files = git('diff', '--name-only', '-z', `${base}..${head}`).split('\0').filter(Boolean).filter(isTestFile);
  function countTree(ref) {
    return git('ls-tree', '-r', '--name-only', '-z', ref).split('\0').filter(isTestFile)
      .reduce((total, file) => {
        const shown = spawnSync('git', ['show', `${ref}:${file}`], { encoding: 'utf8', maxBuffer: 10_000_000 });
        return total + (shown.status === 0 ? count(shown.stdout) : 0);
      }, 0);
  }
  const hits = []; const seen = new Map(); const before = countTree(base), after = countTree(head);
  function add(type, file, line, text) {
    const key = `${type}\0${text}`;
    const location = { file, line };
    if (seen.has(key)) { seen.get(key).locations.push(location); return; }
    const hit = { type, file, line, text, locations: [location] };
    seen.set(key, hit); hits.push(hit);
  }
  for (const file of files) {
    const diff = git('diff', '--unified=0', `${base}..${head}`, '--', file);
    let line = 0; let removed = []; let added = [];
    function flush() {
      const old = removed.map(x => codeOnly(x.text));
      const current = added.map(x => codeOnly(x.text));
      for (let i = 0; i < removed.length; i++) {
        if (assertion.test(old[i]) && !current.includes(old[i])) add('assertion-removed', file, null, removed[i].text);
        if (timeLimit.test(old[i])) {
          const prior = timeLimitValue(old[i]);
          const next = current.map(timeLimitValue).find(x => x !== null);
          if (next === undefined || (prior !== null && next > prior)) add('timeout', file, null, removed[i].text);
        }
        const priorTimeout = old[i].match(numericTimeout);
        if (priorTimeout && /(?:@Test|\btest\s*\(|\bit\s*\()/.test(old[i])) {
          const next = current.map(x => x.match(numericTimeout)).find(Boolean);
          if (!next || Number(next[1]) < Number(priorTimeout[1])) add('timeout', file, null, removed[i].text);
        }
      }
      if (old.some(x => /\.enabled\s*\(\s*if\s*:\s*true\b/.test(x)) && current.some(x => /\.enabled\s*\(\s*if\s*:\s*false\b/.test(x))) {
        const changed = added.find(x => /\.enabled\s*\(\s*if\s*:\s*false\b/.test(codeOnly(x.text)));
        add('skip', file, changed.line, changed.text);
      }
      removed = []; added = [];
    }
    for (const row of diff.split('\n')) {
      const hunk = row.match(/^@@ .* \+(\d+)/); if (hunk) { flush(); line = Number(hunk[1]); continue; }
      if (row.startsWith('---') || row.startsWith('+++')) continue;
      if (row.startsWith('-')) removed.push({ text: row.slice(1).trim() });
      if (row.startsWith('+')) {
        const text = row.slice(1).trim();
        added.push({ text, line });
        const code = codeOnly(text);
        if (/\.disabled\s*\(|\b(?:throw\s+)?XCTSkip\w*\s*\(|\{\s*skip\s*:/.test(code)) add('skip', file, line, text);
        if (/\bretr(?:y|ies)\s*[:=(]|retry-tests-on-failure/.test(code)) add('retry', file, line, text);
        if (/\b(?:process\.)?exit\s*\(\s*0\s*\)|sys\.exit\s*\(\s*0\s*\)/.test(code)) add('exit-zero', file, line, text);
        if (/#expect\s*\(\s*(?:true|1\s*==\s*1|true\s*==\s*true)\s*\)|XCTAssertTrue\s*\(\s*true\s*\)/.test(code)) add('weak-assertion', file, line, text);
        line++;
      } else if (row.startsWith(' ')) line++;
    }
    flush();
  }
  const receiptPath = '.claude/tdd-guardian/receipts.json';
  const receipts = [];
  if (fs.existsSync(receiptPath)) {
    const data = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
    for (const r of data.receipts || []) receipts.push({ id: r.id, red: Boolean(r.red?.red), verdict: r.verdict || 'UNRECORDED', status: !r.red?.red ? 'MISSING-RED' : r.verdict || 'MISSING-SEPARATION' });
  }
  if (receipts.length === 0) receipts.push({ status: 'MISSING-RED', verdict: 'MISSING-SEPARATION' });
  console.log(JSON.stringify({ base, head: git('rev-parse', head).trim(), testCounts: { before, after }, hits, receipts }, null, 2));
} catch (error) { console.error(error.message); process.exitCode = 1; }
