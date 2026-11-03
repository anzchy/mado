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

const gateLanes = ['package-tests', 'package-coverage', 'app-tests', 'unsigned-build', 'node-tooling', 'ledger', 'diff-check', 'design-check', 'audit', 'device-smoke'];
const gateStatuses = new Set(['PASS', 'FAIL', 'NOT RUN', 'N/A', 'NOT VERIFIED']);

function stripFencedCodeBlocks(body) {
  const lines = [];
  let fence;
  for (const line of body.split(/\r?\n/)) {
    if (fence) {
      const closing = line.match(/^ {0,3}(`{3,}|~{3,})\s*$/);
      if (closing && closing[1][0] === fence[0] && closing[1].length >= fence.length) fence = undefined;
      continue;
    }
    const opening = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (opening) fence = opening[1];
    else lines.push(line);
  }
  return lines.join('\n');
}

export function checkGates(body, head) {
  const unfencedBody = stripFencedCodeBlocks(body);
  const headings = unfencedBody.match(/^#{1,6}\s+gates\b.*$/gmi) ?? [];
  const setextHeadings = [...unfencedBody.matchAll(/^([^\r\n]+)\r?\n[ \t]*(?:=+|-+)[ \t]*$/gmi)]
    .map(match => match[1].trim())
    .filter(heading => /^gates\b/i.test(heading));
  headings.push(...setextHeadings);
  if (headings.length === 0) return { ok: false, reason: 'missing ## Gates table' };
  const ambiguous = headings.find(heading => heading.trimEnd() !== '## Gates');
  if (ambiguous) return { ok: false, reason: `ambiguous Gates heading: ${ambiguous}` };
  if (headings.length > 1) return { ok: false, reason: 'duplicate ## Gates section' };
  const section = unfencedBody.match(/^## Gates\s*$([\s\S]*?)(?=^##\s|^[^\r\n]+\r?\n[ \t]*(?:=+|-+)[ \t]*$|$(?![\s\S]))/m)[1];
  const lines = section.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  let headerAt = -1;
  for (let i = 0; i + 2 < lines.length; i++) {
    const header = cells(lines[i]);
    const rule = cells(lines[i + 1]);
    if (header.length === 4 && header.every((value, index) => value === ['Lane', 'Status', 'SHA', 'Source'][index]) &&
        rule.length === 4 && rule.every(value => /^:?-{3,}:?$/.test(value))) {
      headerAt = i;
      break;
    }
  }
  if (headerAt < 0) return { ok: false, reason: 'missing ## Gates table' };

  const rows = [];
  const seen = new Set();
  let tableEnd = headerAt + 2;
  for (; tableEnd < lines.length && lines[tableEnd].startsWith('|'); tableEnd++) {
    const values = cells(lines[tableEnd]);
    if (values.length !== 4 || !values[0]) return { ok: false, reason: 'invalid ## Gates table row' };
    rows.push(values);
    const lane = values[0].toLowerCase();
    if (seen.has(lane)) return { ok: false, reason: `duplicate ${lane} lane` };
    seen.add(lane);
  }
  for (let i = 0; i < lines.length; i++) {
    if ((i < headerAt || i >= tableEnd) && /^\|.*\|$/.test(lines[i])) {
      return { ok: false, reason: 'unconsumed Gates row after the authoritative table' };
    }
  }
  for (const lane of gateLanes) {
    if (!seen.has(lane)) return { ok: false, reason: `missing ${lane} lane` };
  }

  for (const [printedLane, status, sha, source] of rows) {
    const lane = printedLane.toLowerCase();
    if (!gateStatuses.has(status)) return { ok: false, reason: `${lane} has invalid status ${status}` };
    if (status === 'PASS' || status === 'FAIL' || status === 'NOT VERIFIED') {
      if (!/^[0-9a-f]{7,40}$/i.test(sha)) return { ok: false, reason: `${lane} ${status} needs a 7-40 hex SHA` };
      if (!source) return { ok: false, reason: `${lane} ${status} needs a Source` };
    } else {
      if (sha !== '' && sha !== '—') return { ok: false, reason: `${lane} ${status} needs an empty or — SHA` };
      if (!source || source === '-' || source === '—') return { ok: false, reason: `${lane} ${status} needs a Source reason` };
    }
    if (status === 'FAIL') return { ok: false, reason: `${lane} is a FAIL row` };
    if (status === 'PASS' && !head.toLowerCase().startsWith(sha.toLowerCase()) &&
        !/\bCODE same [0-9a-f]{40}\b/.test(source)) {
      return { ok: false, reason: `${lane} PASS has a stale head without CODE same evidence` };
    }
  }

  const smokeLines = unfencedBody.split(/\r?\n/).filter(line => /^Device-Smoke:/.test(line));
  if (smokeLines.length > 0) {
    if (smokeLines.length !== 1) return { ok: false, reason: 'Device-Smoke lines must be unique and agree with the device-smoke row' };
    const smoke = smokeLines[0].match(/^Device-Smoke:\s*(PASS|NOT VERIFIED|n\/a)(?:\s+([0-9a-f]{7,40}))?\b/i);
    const deviceRow = rows.find(values => values[0].toLowerCase() === 'device-smoke');
    if (!smoke) return { ok: false, reason: 'Device-Smoke line does not agree with the device-smoke row' };
    const smokeStatus = smoke[1].toLowerCase() === 'n/a' ? 'N/A' : smoke[1].toUpperCase();
    if (deviceRow[1] !== smokeStatus) return { ok: false, reason: 'Device-Smoke status does not agree with the device-smoke row' };
    if (smokeStatus !== 'N/A' && (!smoke[2] || smoke[2].toLowerCase() !== deviceRow[2].toLowerCase())) {
      return { ok: false, reason: 'Device-Smoke SHA does not equal the device-smoke row SHA' };
    }
  }
  return { ok: true };
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
      let result = checkUIParity(body, files);
      if (result.ok && (files.some(isUIFile) || /^Device-Smoke:/m.test(body)) && !validSmoke(body)) {
        result.ok = false;
        result.reason = 'UI files changed; PR body needs a Device-Smoke: line for the changed path';
      }
      if (result.ok) {
        const head = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
        result = checkGates(body, head);
      }
      if (!result.ok) { console.error(result.reason); process.exitCode = 1; }
      else console.log('UI-Parity PR body: PASS');
    } catch (error) {
      console.error(error.message);
      process.exitCode = 2;
    }
  }
}
