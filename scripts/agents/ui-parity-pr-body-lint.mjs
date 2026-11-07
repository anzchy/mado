#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { posix } from 'node:path';

const isUIFile = file => file.startsWith('App/') ||
  file.startsWith('Packages/MadoKit/Sources/MadoMacUI/');

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

const codeInputs = ['App/', 'AppTests/', 'Packages/', 'UITests/', 'project.yml',
  'TestAssets/', 'design/', 'scripts/perf/fixtures/', 'THIRD_PARTY_NOTICES.md',
  '.github/workflows/ci.yml', '.github/actions/', 'scripts/ci/', 'scripts/tdd/', 'scripts/heavy-lock.sh'];
const ledgerInputs = ['docs/feature-ledger.md', 'docs/feature-ledger.html', 'scripts/ledger/',
  'package.json', '.github/workflows/ci.yml'];
// Conservative input supersets of the jobs in ci.yml and pr-body.yml. Null means
// file equality alone cannot reliably establish that lane's evidence is current.
const gateInputs = {
  'package-tests': codeInputs,
  'package-macui-tests': codeInputs,
  'app-tests': codeInputs,
  // These also depend on the generated-ledger check, which Walking skeleton requires (now its own Ledger HTML check job).
  'unsigned-build': [...codeInputs, ...ledgerInputs],
  'walking-skeleton': [...codeInputs, ...ledgerInputs],
  // Agent/perf tests read documents, templates and repository references too.
  'node-tooling': ['.'],
  ledger: ledgerInputs,
  'design-check': ['App/', 'Packages/', 'design/', 'scripts/', 'package.json', 'package-lock.json', '.github/workflows/ci.yml'],
  // Swift coverage also reads its runner, LCOV exporter/aggregator and gate config.
  'package-coverage': [...codeInputs, '.agents/skills/picsee-delegator/scripts/', '.claude/tdd-guardian/config.json'],
  'diff-check': null,
  audit: null,
  'device-smoke': null,
  gardener: null,
};

function ancestorInputsChanged(git, lane, sha, head) {
  const inputs = Object.hasOwn(gateInputs, lane) ? gateInputs[lane] : null;
  if (!inputs || !git) return undefined;
  try {
    if (git.isAncestor(sha, head) === true) return git.inputsChanged(sha, head, inputs);
  } catch {
    // An unavailable revision or failed git operation proves neither equality nor change.
  }
  return undefined;
}

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

// Match pre-push checker_changed pathspecs, including an exact-path replacement.
// Kept here because the trusted hook is standalone shell; sharing would change
// its execution/dependency boundary rather than just its deferral messages.
const checkerPaths = { ledger: 'scripts/ledger', design: 'scripts/design' };

// Syntax/identity checks catch mistaken citations; reviewers establish existence,
// independence and coverage. Fragments never make one report into two reports.
function auditReferenceIdentity(ref) {
  if (/^https:\/\/github\.com\/anzchy\/picsee\/pull\/[1-9]\d*#(?:pullrequestreview|issuecomment)-[1-9]\d*$/.test(ref)) return ref;
  if (!ref.startsWith('~/.picsee/herdr/') || /\s/.test(ref)) return undefined;
  const [path, fragment, ...extra] = ref.split('#');
  if (extra.length || (fragment !== undefined && !/^[\w-]+$/.test(fragment))) return undefined;
  const normalized = posix.normalize(path);
  if (/(?:^|[./_-])(?:tbd|none|todo|x|n[/-]a)(?=$|[./_-])/i.test(normalized)) return undefined;
  if (!/^~\/\.picsee\/herdr\/[a-z0-9]+(?:-[a-z0-9]+)*-auditor\/[A-Za-z0-9][A-Za-z0-9._-]*-(?:audit|confirm)[A-Za-z0-9._-]*\.md$/.test(normalized)) return undefined;
  return normalized;
}

function checkCheckerChange(body, files, head) {
  const changed = Object.entries(checkerPaths)
    .filter(([, path]) => files.some(file => file === path || file.startsWith(path + '/')))
    .map(([family]) => family);
  // A stray acknowledgement is harmless on a PR outside these checker families.
  if (changed.length === 0) return { ok: true };
  const lines = stripFencedCodeBlocks(body).replace(/<!--[\s\S]*?(?:-->|$)/g, '')
    .split(/\r?\n/).filter(line => /^Checker-Change:/.test(line));
  const fail = reason => ({ ok: false, reason: `Checker-Change: ${reason}` });
  if (lines.length === 0) return fail(`required for changed checker families: ${changed.join(',')}`);
  if (lines.length !== 1) return fail('exactly one acknowledgement line is required');
  const match = lines[0].match(/^Checker-Change:[ \t]+([0-9a-f]{40})[ \t]+families=([a-z,]+)[ \t]+—[ \t]+([^\r\n]*?)[ \t]+—[ \t]+audits:[ \t]*([^\r\n]*)$/i);
  if (!match) return fail('invalid format; expected <40-hex head SHA> families=ledger,design — <rationale> — audits: <ref>,<ref>');
  const [, sha, listed, rationale, audits] = match;
  if (sha.toLowerCase() !== head.toLowerCase()) return fail('head SHA must equal the full current PR head SHA');
  const families = listed.split(',');
  if (families.some(family => !Object.hasOwn(checkerPaths, family)) || new Set(families).size !== families.length)
    return fail('families must be unique known names: ledger,design');
  const missing = changed.filter(family => !families.includes(family));
  if (missing.length) return fail(`missing changed checker families: ${missing.join(',')}`);
  if (!rationale.replace(/[\s—–-]/g, '')) return fail('a nonempty rationale beyond separators is required');
  const refs = audits.split(',').map(ref => auditReferenceIdentity(ref.trim()));
  if (refs.length < 2 || refs.some(ref => ref === undefined) || new Set(refs).size !== refs.length)
    return fail('audits need at least two distinct normalized herdr auditor report paths or anzchy/picsee PR review/comment URLs; no placeholders; reviewers verify independence and coverage');
  return { ok: true };
}

export function checkGates(body, head, git) {
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
    if (status === 'PASS' && !head.toLowerCase().startsWith(sha.toLowerCase())) {
      const changed = ancestorInputsChanged(git, lane, sha, head);
      if (changed === true && /\bCODE same [0-9a-f]{40}\b/.test(source)) {
        return { ok: false, reason: `${lane} PASS has a stale head: inputs changed since ${sha}` };
      }
      if (changed === true || (changed !== false && !/\bCODE same [0-9a-f]{40}\b/.test(source))) {
        return { ok: false, reason: `${lane} PASS has a stale head without CODE same evidence` };
      }
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

// Only the CLI touches git; checkGates receives evidence through this boundary.
function gitAdapter() {
  const cwd = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  const options = { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] };
  const resolve = sha => {
    // Match object IDs uniquely, without peeling annotated tags into commits.
    const matches = execFileSync('git', ['rev-parse', `--disambiguate=${sha.toLowerCase()}`], options).trim().split('\n');
    if (matches.length !== 1 || !matches[0] ||
        execFileSync('git', ['cat-file', '-t', matches[0]], options).trim() !== 'commit') {
      throw Error('SHA must uniquely name a commit object');
    }
    return matches[0];
  };
  const quiet = args => {
    try {
      execFileSync('git', args, options);
      return 0;
    } catch (error) {
      if (error.status === 1) return 1;
      throw error;
    }
  };
  return {
    isAncestor: (sha, head) => quiet(['merge-base', '--is-ancestor', resolve(sha), resolve(head)]) === 0,
    inputsChanged: (sha, head, inputs) => quiet(['diff', '--quiet', resolve(sha), resolve(head), '--', ...inputs]) === 1,
  };
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
      const files = execFileSync('git', ['diff', '--no-renames', '--name-only', '-z', '--diff-filter=ACMRDT', `${base}..HEAD`], { encoding: 'utf8' }).split('\0').filter(Boolean);
      const body = readFileSync(args[bodyAt + 1], 'utf8');
      let result = checkUIParity(body, files);
      if (result.ok && (files.some(isUIFile) || /^Device-Smoke:/m.test(body)) && !validSmoke(body)) {
        result.ok = false;
        result.reason = 'UI files changed; PR body needs a Device-Smoke: line for the changed path';
      }
      if (result.ok) {
        const head = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
        result = checkGates(body, head, gitAdapter());
        if (result.ok) result = checkCheckerChange(body, files, head);
      }
      if (!result.ok) { console.error(result.reason); process.exitCode = 1; }
      else console.log('UI-Parity PR body: PASS');
    } catch (error) {
      console.error(error.message);
      process.exitCode = 2;
    }
  }
}
