#!/usr/bin/env node
// A review aid: findings require explanation, not an automatic failure.
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const base = args[args.indexOf('--base') + 1] || 'origin/main';
function git(...argv) {
  const r = spawnSync('git', argv, { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr.trim() || `git ${argv[0]} failed`);
  return r.stdout;
}
function count(text) {
  return (text.match(/\b(?:func\s+test\w+\s*\(|@Test\b|test\s*\()/g) || []).length;
}
const isTestFile = file => /(?:^|\/)(?:[^/]+\.test\.[cm]?js|[^/]+\.test\.swift|test_[^/]+\.py|[^/]+Tests?\.swift|[^/]+Spec\.swift|app-quarantine\.json)$/i.test(file);
const rules = [
  ['skip', /(?:\.disabled\b|XCTSkip\b|\bskip\b|quarantine)/i],
  ['retry', /\bretr(?:y|ies)\b|retry-tests-on-failure/i],
  ['timeout', /\btimeout\b|\btimeLimit\b|\bwaitForExpectations\b/i],
  ['exit-zero', /\b(?:process\.)?exit\s*\(\s*0\s*\)|sys\.exit\s*\(\s*0\s*\)/i],
];
try {
  const files = git('diff', '--name-only', '-z', `${base}..HEAD`).split('\0').filter(Boolean).filter(isTestFile);
  function countTree(ref) {
    return git('ls-tree', '-r', '--name-only', '-z', ref).split('\0').filter(isTestFile)
      .reduce((total, file) => {
        const shown = spawnSync('git', ['show', `${ref}:${file}`], { encoding: 'utf8', maxBuffer: 10_000_000 });
        return total + (shown.status === 0 ? count(shown.stdout) : 0);
      }, 0);
  }
  const hits = []; const before = countTree(base), after = countTree('HEAD');
  for (const file of files) {
    const diff = git('diff', '--unified=0', `${base}..HEAD`, '--', file);
    let line = 0;
    for (const row of diff.split('\n')) {
      const hunk = row.match(/^@@ .* \+(\d+)/); if (hunk) { line = Number(hunk[1]); continue; }
      if (row.startsWith('---') || row.startsWith('+++')) continue;
      if (row.startsWith('-') && /#expect\b|XCTAssert\w*\b/.test(row)) hits.push({ type: 'assertion-removed', file, line: null, text: row.slice(1).trim() });
      if (row.startsWith('+')) {
        const text = row.slice(1).trim();
        for (const [type, regex] of rules) if (regex.test(text)) hits.push({ type, file, line, text });
        if (/#expect\s*\(\s*(?:true|1\s*==\s*1|true\s*==\s*true)\s*\)|XCTAssertTrue\s*\(\s*true\s*\)/.test(text)) hits.push({ type: 'weak-assertion', file, line, text });
        line++;
      } else if (row.startsWith(' ')) line++;
    }
  }
  const receiptPath = '.claude/tdd-guardian/receipts.json';
  const receipts = [];
  if (fs.existsSync(receiptPath)) {
    const data = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
    for (const r of data.receipts || []) receipts.push({ id: r.id, red: Boolean(r.red?.red), verdict: r.verdict || 'UNRECORDED', status: !r.red?.red ? 'MISSING-RED' : r.verdict || 'MISSING-SEPARATION' });
  }
  if (receipts.length === 0) receipts.push({ status: 'MISSING-RED', verdict: 'MISSING-SEPARATION' });
  console.log(JSON.stringify({ base, head: git('rev-parse', 'HEAD').trim(), testCounts: { before, after }, hits, receipts }, null, 2));
} catch (error) { console.error(error.message); process.exitCode = 1; }
