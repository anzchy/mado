#!/usr/bin/env node
// Issue 734: one hash over the App build inputs of a commit, so a device smoke verdict follows those inputs instead of
// the head SHA (owner 2026-11-16: 「4 smoke 跟 App 输入走」). Same hash at the smoke head and at the candidate head -> the
// smoke verdict carries over; different, or not computable -> redo the smoke for the changed paths.
//
//   node scripts/ci/app-inputs-hash.mjs [--rev <commit>] [--list] [--verify-host]
//
// Prints the 64-hex hash (or, with --list, the toolchain line and every hashed tree entry) and exits 0. Any failure
// prints the reason on stderr, nothing on stdout, and exits 1 (2 for usage); there is never a fallback hash.
// - The hash covers the Git tree of the commit (default HEAD): mode, object type, blob ID and path of every App input,
//   in byte order of the path, plus the toolchain pinned in .github/actions/xcode-setup/action.yml. A rename, deletion
//   or mode change of an input changes it; history and file creation order do not.
// - Without --rev the worktree is checked too: a modified, staged, deleted or untracked (not ignored) App input refuses,
//   because the build would not be the commit. --rev <commit> hashes only that commit (the PR-body lint's mode).
// - --verify-host also requires the host `xcodebuild -version` to match the pinned Xcode and build version.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// The App build inputs. Keep these explicit; any doubt belongs here (a false "changed" only costs a smoke).
// - App/ is globbed whole by project.yml's targets; Packages/ holds MadoKit (sources, resources, Package.swift/resolved).
// - project.yml carries the targets, signing settings (style, identity, team), Sparkle pin and the build-phase script.
// - The pin file selects Xcode and XcodeGen for every build (also parsed into the toolchain string below).
// - Localization, entitlements, build configuration, privacy manifests and Info.plist count wherever they live.
// Not inputs (not in the app bundle or not read by its build): docs, design, agent files, test targets
// (AppTests/, UITests/, TestAssets/), CI and release tooling (scripts/, .github/workflows/), THIRD_PARTY_NOTICES.md.
export const INPUT_PREFIXES = ['App/', 'Packages/'];
export const PIN_FILE = '.github/actions/xcode-setup/action.yml';
export const INPUT_FILES = ['project.yml', PIN_FILE];
export const INPUT_SUFFIXES = ['.xcconfig', '.entitlements', '.xcstrings', '.xcprivacy'];
export const INPUT_BASENAMES = ['Info.plist'];
const FORMAT = 'mado-app-inputs v1';

export class InputsError extends Error {}

/** True for an App build input. A malformed path is treated as an input (fail towards "changed"). */
export function isAppInput(file) {
  if (typeof file !== 'string' || !file || file.startsWith('/') || file.includes('\\') ||
      file.split('/').some(part => part === '' || part === '.' || part === '..')) return true;
  const parts = file.split('/');
  const base = parts.at(-1);
  return INPUT_FILES.includes(file) || INPUT_PREFIXES.some(prefix => file.startsWith(prefix)) ||
    INPUT_SUFFIXES.some(suffix => base.endsWith(suffix)) || INPUT_BASENAMES.includes(base) ||
    parts.slice(0, -1).some(part => part.endsWith('.lproj'));
}

function git(cwd, args) {
  const result = spawnSync('git', args, { cwd, maxBuffer: 512 * 1024 * 1024 });
  if (result.error) throw new InputsError(`git ${args.join(' ')}: ${result.error.message}`);
  if (result.status !== 0) {
    throw new InputsError(`git ${args.join(' ')} failed: ${result.stderr.toString('utf8').trim() || `exit ${result.status}`}`);
  }
  return result.stdout;
}

/** Splits NUL-terminated Git output into Buffers. */
function fields(buffer) {
  const out = [];
  let start = 0;
  for (let index = buffer.indexOf(0); index !== -1; index = buffer.indexOf(0, start)) {
    out.push(buffer.subarray(start, index));
    start = index + 1;
  }
  if (start < buffer.length) throw new InputsError('git output is not NUL-terminated');
  return out;
}

/** A path decoded for matching; bytes that are not UTF-8 make the entry an input (doubt -> changes the hash). */
function name(raw) {
  const text = raw.toString('utf8');
  return Buffer.from(text, 'utf8').equals(raw) ? text : '';
}

/** "Xcode <v> (<build>); XcodeGen <v>" from the pin file at `commit`; a missing or partial pin refuses. */
export function pinnedToolchain(root, commit) {
  let text;
  try {
    text = git(root, ['cat-file', 'blob', `${commit}:${PIN_FILE}`]).toString('utf8');
  } catch (error) {
    throw new InputsError(`toolchain pin ${PIN_FILE} unreadable at ${commit}: ${error.message}`);
  }
  const one = (pattern, label) => {
    const found = [...text.matchAll(pattern)].map(match => match[1]);
    if (new Set(found).size !== 1) throw new InputsError(`toolchain pin ${PIN_FILE} needs exactly one ${label}; found ${found.length}`);
    return found[0];
  };
  const xcode = one(/grep -Fx 'Xcode ([^']+)'/g, "'Xcode <version>' line");
  const build = one(/grep -Fx 'Build version ([^']+)'/g, "'Build version <build>' line");
  const xcodegen = one(/grep -Fx 'Version: ([^']+)'/g, "XcodeGen 'Version: <version>' line");
  return { xcode, build, xcodegen, text: `Xcode ${xcode} (${build}); XcodeGen ${xcodegen}` };
}

function verifyHost(pin) {
  const result = spawnSync('xcodebuild', ['-version'], { encoding: 'utf8', timeout: 30000 });
  if (result.error || result.status !== 0) {
    throw new InputsError(`xcodebuild -version failed: ${result.error?.message ?? (result.stderr.trim() || `exit ${result.status}`)}`);
  }
  const xcode = /^Xcode (\S+)$/m.exec(result.stdout)?.[1];
  const build = /^Build version (\S+)$/m.exec(result.stdout)?.[1];
  if (xcode !== pin.xcode || build !== pin.build) {
    throw new InputsError(`host toolchain Xcode ${xcode ?? '?'} (${build ?? '?'}) differs from the pin ${pin.text}`);
  }
}

/**
 * The App-inputs hash of `rev` (default HEAD) in the repository at `cwd`; the boundary the PR-body lint calls (issue
 * 734, Phase 2). `checkWorktree` refuses uncommitted App inputs; `verifyHostToolchain` compares the host Xcode with the
 * pin. Throws InputsError on any failure; never returns a hash it could not compute.
 */
export function appInputsHash({ cwd = process.cwd(), rev = 'HEAD', checkWorktree = false, verifyHostToolchain = false } = {}) {
  const root = git(cwd, ['rev-parse', '--show-toplevel']).toString('utf8').trim();
  let commit;
  try {
    commit = git(root, ['rev-parse', '--verify', '--quiet', '--end-of-options', `${rev}^{commit}`]).toString('utf8').trim();
  } catch {
    throw new InputsError(`unknown commit: ${rev}`);
  }
  if (!/^[0-9a-f]{40,64}$/.test(commit)) throw new InputsError(`unknown commit: ${rev}`);
  if (checkWorktree) {
    const dirty = fields(git(root, ['status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames']))
      .map(entry => name(entry.subarray(3))).filter(isAppInput);
    if (dirty.length) {
      throw new InputsError(`App inputs not committed: ${dirty.slice(0, 10).join(', ')}` +
        `${dirty.length > 10 ? ` (+${dirty.length - 10} more)` : ''}; commit or clean them, or pass --rev <commit>`);
    }
  }
  const pin = pinnedToolchain(root, commit);
  if (verifyHostToolchain) verifyHost(pin);
  const entries = [];
  for (const entry of fields(git(root, ['ls-tree', '-r', '-z', '--full-tree', commit]))) {
    const tab = entry.indexOf(9);
    if (tab < 0) throw new InputsError('malformed git ls-tree entry');
    const meta = entry.subarray(0, tab).toString('utf8');
    if (!/^[0-7]{6} (blob|commit) [0-9a-f]{40,64}$/.test(meta)) throw new InputsError(`malformed git ls-tree entry: ${meta}`);
    const raw = entry.subarray(tab + 1);
    if (isAppInput(name(raw))) entries.push({ meta, raw, path: raw.toString('utf8') });
  }
  entries.sort((a, b) => Buffer.compare(a.raw, b.raw));
  const digest = createHash('sha256').update(`${FORMAT}\0toolchain=${pin.text}\0`);
  for (const entry of entries) digest.update(Buffer.concat([Buffer.from(`${entry.meta}\t`), entry.raw, Buffer.from([0])]));
  return { hash: digest.digest('hex'), commit, toolchain: pin.text, entries };
}

export function main(argv = process.argv.slice(2), { out = process.stdout, err = process.stderr } = {}) {
  const usage = 'usage: app-inputs-hash.mjs [--rev <commit>] [--list] [--verify-host]';
  const options = { rev: undefined, list: false, verifyHost: false };
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === '--rev' && options.rev === undefined && argv[index + 1] && !argv[index + 1].startsWith('--')) {
      options.rev = argv[++index];
    } else if (flag === '--list' && !options.list) options.list = true;
    else if (flag === '--verify-host' && !options.verifyHost) options.verifyHost = true;
    else { err.write(`${usage}\n`); return 2; }
  }
  try {
    const result = appInputsHash({ rev: options.rev ?? 'HEAD', checkWorktree: options.rev === undefined,
      verifyHostToolchain: options.verifyHost });
    out.write(options.list ? [`toolchain ${result.toolchain}`, ...result.entries.map(e => `${e.meta}\t${e.path}`), ''].join('\n')
      : `${result.hash}\n`);
    return 0;
  } catch (error) {
    err.write(`app-inputs-hash: ${error instanceof InputsError ? error.message : `unexpected error: ${error.stack ?? error}`}\n`);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main();
