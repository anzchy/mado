#!/usr/bin/env node
/** #551: replay on the current integration base with `node scripts/name-checks/rename-modules.mjs`.
 * Uses the tracked tree, never a frozen copy of source; safe to repeat after a rebase.
 * Run npm run ledger:build afterward. Commit this script separately from its output.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, lstatSync, readFileSync, writeFileSync } from 'node:fs';
import { isUtf8 } from 'node:buffer';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const self = fileURLToPath(import.meta.url);
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
const tracked = () => git('ls-files', '-z').split('\0').filter(Boolean);
const modules = text => text.replaceAll('PicseeKit', 'MadoKit')
  .replaceAll('PicseeCore', 'MadoCore').replaceAll('PicseeApplication', 'MadoApplication')
  .replaceAll('PicseeInfrastructure', 'MadoInfrastructure').replaceAll('PicseeMacUI', 'MadoMacUI');
const targets = text => modules(text).replaceAll('PicseeApp', 'MadoApp').replaceAll('PicseeUITests', 'MadoUITests');
function move(from, to) {
  if (!existsSync(from)) return;
  if (existsSync(to)) throw new Error(`refusing to overwrite ${to}`);
  git('mv', '--', from, to);
}
move('Packages/PicseeKit', 'Packages/MadoKit');
for (const base of ['Sources', 'Tests']) {
  for (const module of ['Core', 'Application', 'Infrastructure', 'MacUI']) {
    const suffix = base === 'Tests' ? 'Tests' : '';
    move(`Packages/MadoKit/${base}/Picsee${module}${suffix}`, `Packages/MadoKit/${base}/Mado${module}${suffix}`);
  }
}
for (const path of tracked()) {
  if (/^(App|AppTests|UITests|Packages)\//.test(path) && path.includes('Picsee')) {
    move(path, targets(path).replaceAll('Picsee', 'Mado'));
  }
}
// Keep explicit future-ticket contracts and historical identity fixtures intact.
const protectedSpans = /picsee-(?:ui-system|browser)\b|io\.github\.anzchy\.picsee(?=['"]\s*,\s*SUBSYSTEM)|Rows cut from a real `log show --signpost --style ndjson` of a Picsee build|PICSEE_[A-Z0-9_]+|(?:anzchy|anzchy\\)\/picsee|\.picsee\b|picsee-wt\b|picsee-(?:delegator|doc-gardener)\b|picsee\.pid\b|design\/[^\s"'`<>)]*|picsee\.native-design-spec\/v1/g;
function rename(text, { lower = false } = {}) {
  const saved = [];
  let value = text.replace(protectedSpans, match => `__I551_KEEP_${saved.push(match) - 1}__`);
  value = targets(value).replaceAll('Picsee', 'Mado');
  if (lower) value = value.replaceAll('picsee', 'mado');
  return value.replace(/__I551_KEEP_(\d+)__/g, (_, index) => saved[Number(index)]);
}
let changed = 0;
for (const path of tracked()) {
  if (resolve(path) === self || lstatSync(path).isSymbolicLink() || path.includes('/B4PinnedDesign/') || path.startsWith('scripts/release/fixtures/')) continue;
  const buffer = readFileSync(path);
  if (buffer.includes(0) || !isUtf8(buffer)) continue;
  const before = buffer.toString('utf8');
  let after = before;
  if (path === 'docs/feature-ledger.md') {
    after = before.split('\n').map(line => {
      if (!line.startsWith('|')) return line;
      const cells = line.split('|');
      if (cells.length >= 9) cells[6] = targets(cells[6]).replaceAll('Picsee', 'Mado');
      return cells.join('|');
    }).join('\n');
  } else if (/^(App|AppTests|UITests|Packages)\//.test(path) && !path.endsWith('.md')) {
    after = rename(before, { lower: true });
    after = after.replaceAll('com.picsee.app', 'io.github.anzchy.mado').replaceAll('com.mado.app', 'io.github.anzchy.mado');
  } else if (path === 'project.yml' || path === '.claude/tdd-guardian/config.json') {
    after = rename(before);
  } else if ((path.startsWith('scripts/') || path.startsWith('.github/') ||
      /^\.agents\/skills\/[^/]+\/scripts\//.test(path)) && !path.endsWith('.md')) {
    // The checker's own fixtures deliberately exercise the forbidden identity.
    if (path.startsWith('scripts/name-checks/')) continue;
    // Frozen release identity fixtures and tooling get module-path substitutions only.
    const fixture = path === '.github/workflows/release.yml' || /\/fixtures\//.test(path) || /^scripts\/release\/.*\.test\.mjs$/.test(path);
    const tooling = /^scripts\/(agents|codex-rules|git-hooks|testassets)\//.test(path) ||
      /(?:heavy-lock|archive-receipts)/.test(path) ||
      /^\.agents\/skills\/[^/]+\/scripts\//.test(path);
    after = fixture || tooling ? before.split('\n').map(line => line.includes('.replaceAll("PicseeKit_PicseeMacUI", "MadoKit_MadoMacUI")') ? line : targets(line)).join('\n') : rename(before, {
      lower: /^scripts\/(perf|device|tdd|ci)\//.test(path) || path === '.github/workflows/ci.yml',
    });
    if (path === 'scripts/release/check-package.test.mjs' && !after.includes('.replaceAll("PicseeKit_PicseeMacUI", "MadoKit_MadoMacUI")')) {
      after = after.replace('.replaceAll("MacOS/Picsee", "MacOS/Mado")', '.replaceAll("MacOS/Picsee", "MacOS/Mado")\n  .replaceAll("PicseeKit_PicseeMacUI", "MadoKit_MadoMacUI")');
    }
    // Existing owner gates must actually build the renamed scheme.
    if (path.endsWith('/owner-gates.sh')) after = after.replaceAll('-scheme Picsee', '-scheme Mado');
  }
  if (after !== before) { writeFileSync(path, after); changed++; }
}
console.log(`Mado module replay: ${changed} tracked text files rewritten`);
