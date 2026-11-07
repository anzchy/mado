#!/usr/bin/env node
// #553: replay only the mechanical living-document rename. Acceptance names
// are intentionally a separate commit under amendment 1, not part of this CLI.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, lstatSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = execFileSync('git', ['-C', dirname(fileURLToPath(import.meta.url)), 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const paths = execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const note = '\n注：Picsee 是 Mado 的旧名（#547、ADR-0017）。\n';
function living(path) {
  return path.endsWith('.md') && !/^(?:docs\/(?:adr|validation|audit|test)\/|\.claude\/(?:skills|tdd-guardian)\/|evidence\/)/.test(path) &&
    !/(?:^|\/)(?:CHANGELOG|PROVENANCE)\.md$|^docs\/PICVIEW_|\/(?:fixtures|reviews)\//.test(path);
}
function rename(text) {
  // Paths, tool identifiers and repository names are stable until #554/#556.
  // Protect individual spans, never entire lines that may also contain live commands.
  text = text.replaceAll('io.github.anzchy.picsee', 'io.github.anzchy.mado');
  const saved = [];
  const protect = span => `\uE000${saved.push(span) - 1}\uE001`;
  let out = text.replace(/\bPicseeUiSystem_bb8eab\b|(?<=session `)picsee(?=`)|(?<=project=)picsee|picsee(?= flock| holder| 从不回收| never reclaims| doc gardener)|「[^」]*[Pp]icsee[^」]*」|(?:former name: Picsee|https?:\/\/|git@)[^\s<>`）)\]]*|(?:[\w.~$\/-]*\/)?(?:picsee-ui-system|picsee-browser|picsee-wt|\.picsee)(?:[\w.\/-]*)|\bpicsee-(?:delegator|doc-gardener|opus-auditor)\b|\bPICSEE_[A-Z0-9_*]+\b|\banzchy\/picsee\b|\bpicsee\.(?:pid|log)\b|\bpicsee-mbp\b|\bpicsee\//g, protect);
  out = out.replaceAll('io.github.anzchy.picsee', 'io.github.anzchy.mado')
    .replace(/Picsee[A-Za-z0-9]*/g, token => token.replace('Picsee', 'Mado'))
    .replace(/(?<![A-Za-z0-9_.\/-])picsee(?![A-Za-z0-9_\/-]|\.[A-Za-z0-9])/g, 'Mado');
  return out.replace(/\uE000(\d+)\uE001/g, (_, i) => saved[Number(i)]);
}
function ledger(text) {
  // Keep the history section verbatim. Preserve acceptance prefixes in this pass.
  let history = false;
  return text.split('\n').map(line => {
    if (/^## .*历史|^## .*变更|^## Part 3/.test(line)) history = true;
    if (history) return line;
    if (!/^\| [A-Z]+-\d+ \|/.test(line)) return rename(line);
    // The final column contains no unquoted separator; locate its start by
    // counting the first six separators outside inline code.
    let code = false, separators = 0, start = -1;
    for (let i = 0; i < line.length; i++) {
      if (line[i] === '`') code = !code;
      if (line[i] === '|' && !code && ++separators === 7) { start = i + 1; break; }
    }
    if (start < 0) throw new Error('malformed ledger row');
    const limit = line.indexOf('限制：', start);
    return rename(line.slice(0, start)) + (limit < 0 ? line.slice(start) : line.slice(start, limit) + rename(line.slice(limit)));
  }).join('\n');
}
let changed = 0;
for (const path of paths) {
  const file = resolve(root, path);
  if (lstatSync(file).isSymbolicLink()) continue;
  const frozen = /^docs\/(?:adr|validation)\/.*\.md$/.test(path);
  if (path === 'docs/release/notes-template.md') continue; // executable release input owned by #552
  if (path === 'scripts/name-checks/README.md') continue; // documents both identities deliberately
  if (!frozen && !living(path) && path !== 'scripts/ledger/build.mjs' && path !== '.codex/agents/picsee-doc-gardener.toml' && path !== '.github/ISSUE_TEMPLATE/bug_report.yml') continue;
  const old = readFileSync(file, 'utf8');
  let next;
  if (frozen) next = old.includes(note.trim()) ? old : old + note;
  else if (path === 'docs/feature-ledger.md') next = ledger(old);
  else if (path === 'scripts/ledger/build.mjs') next = old.replace('功能账簿 · picsee</title>', '功能账簿 · Mado</title>').replace('picsee · 功能账簿</span>', 'Mado · 功能账簿</span>');
  else next = rename(old);
  if (next !== old) { writeFileSync(file, next); changed++; }
}
// The native registry pins documentation bytes. Refresh hashes only; preserve
// schemas, token values, paths and every design behavior specification.
const registryPath = resolve(root, 'design/picsee-ui-system/native/TOKEN_REGISTRY.json');
const swiftPath = resolve(root, 'Packages/MadoKit/Sources/MadoMacUI/DesignSystem/Tokens/DesignRegistry.swift');
if (existsSync(registryPath)) {
  const oldJSON = readFileSync(registryPath, 'utf8');
  const registry = JSON.parse(oldJSON);
  let swift = existsSync(swiftPath) ? readFileSync(swiftPath, 'utf8') : null;
  const oldSwift = swift;
  const path = 'design/DESIGN.md';
  const oldHash = registry.sourcesSha256[path];
  if (typeof oldHash !== 'string') throw new Error('missing pinned design guide');
  const hash = createHash('sha256').update(readFileSync(resolve(root, path))).digest('hex');
  // Preserve JSON number formatting and all unrelated pinned source hashes.
  const json = oldJSON.replace(oldHash, hash);
  if (swift !== null) swift = swift.replaceAll(oldHash, hash);
  if (json !== oldJSON) { writeFileSync(registryPath, json); changed++; }
  if (swift !== oldSwift) { writeFileSync(swiftPath, swift); changed++; }
}
console.log(`${changed} tracked text files rewritten; regenerate HTML with npm run ledger:build`);
