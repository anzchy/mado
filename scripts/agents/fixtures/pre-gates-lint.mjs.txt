#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const isUIFile = file => file.startsWith('App/') ||
  file.startsWith('Packages/PicseeKit/Sources/PicseeMacUI/');

const cells = line => line.split('|').slice(1, -1).map(value => value.trim());
const validStatus = value => /^(?:AUTO-PASS|NOT VERIFIED|PENDING\([A-Za-z0-9-]+\))$/.test(value);

function validSmoke(body) {
  const lines = body.split(/\r?\n/).filter(line => /^Device-Smoke:/.test(line));
  if (lines.length !== 1) return false;
  return /^Device-Smoke:\s*n\/a\s+—\s*\S.*$/i.test(lines[0]) ||
    /^Device-Smoke:\s*(?:PASS|NOT VERIFIED)\s+[0-9a-f]{7,40}\s+run=\S+\s+—\s+\S.*$/.test(lines[0]);
}

export function checkUIParity(body, files) {
  if (!files.some(isUIFile)) return { ok: true };
  const section = body.match(/^## UI-Parity\s*$([\s\S]*?)(?=^##\s|$(?![\s\S]))/m)?.[1] ?? '';
  const lines = section.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  for (let i = 0; i + 2 < lines.length; i++) {
    const header = cells(lines[i]);
    const rule = cells(lines[i + 1]);
    const row = cells(lines[i + 2]);
    if (header.length >= 2 && rule.length === header.length && row.length === header.length &&
        rule.every(value => /^:?-{3,}:?$/.test(value)) && row.every(Boolean)) {
      const status = header.findIndex(value => value.toLowerCase() === 'status');
      if (status < 0) return { ok: false, reason: 'UI-Parity table needs a Status column' };
      for (let j = i + 2; j < lines.length && lines[j].startsWith('|'); j++) {
        const values = cells(lines[j]);
        if (values.length !== header.length || !values.every(Boolean) || !validStatus(values[status]))
          return { ok: false, reason: 'UI-Parity table has an invalid or FAIL state status' };
      }
      return { ok: true };
    }
  }
  return { ok: false, reason: 'UI files changed; PR body needs a populated ## UI-Parity table' };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const args = process.argv.slice(2);
  const bodyAt = args.indexOf('--body-file');
  const baseAt = args.indexOf('--base');
  if (bodyAt < 0 || !args[bodyAt + 1] || baseAt < 0 || !args[baseAt + 1] ||
      !/^[A-Za-z0-9._/-]+$/.test(args[baseAt + 1]) || args[baseAt + 1].includes('..')) {
    console.error('usage: node scripts/agents/ui-parity-pr-body-lint.mjs --base main --body-file /path/to/body.md');
    process.exitCode = 2;
  } else {
    try {
      const base = execFileSync('git', ['merge-base', args[baseAt + 1], 'HEAD'], { encoding: 'utf8' }).trim();
      const files = execFileSync('git', ['diff', '--no-renames', '--name-only', '--diff-filter=ACMRD', `${base}..HEAD`], { encoding: 'utf8' }).trim().split('\n');
      const body = readFileSync(args[bodyAt + 1], 'utf8');
      const result = checkUIParity(body, files);
      if (result.ok && (files.some(isUIFile) || /^Device-Smoke:/m.test(body)) && !validSmoke(body)) {
        result.ok = false;
        result.reason = 'UI files changed; PR body needs a Device-Smoke: line for the changed path';
      }
      if (!result.ok) { console.error(result.reason); process.exitCode = 1; }
      else console.log('UI-Parity PR body: PASS');
    } catch (error) {
      console.error(error.message);
      process.exitCode = 2;
    }
  }
}
