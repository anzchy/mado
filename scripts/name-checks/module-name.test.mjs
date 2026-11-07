import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { scanRepository } from './code-name.mjs';

test('tracked repository satisfies the Mado code identity with reviewed exceptions', () => {
  const exceptions = JSON.parse(readFileSync(new URL('./exceptions.json', import.meta.url), 'utf8'));
  const problems = scanRepository({ expectedName: 'Mado', exceptions });
  assert.equal(problems.length, 0, problems.slice(0, 20).join('\n'));
});

// The replay is an executable integration seam: use a real Git tree, not source-string assertions.
import { mkdtempSync, mkdirSync, writeFileSync, lstatSync, readlinkSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

test('replay from a subdirectory preserves paired fixtures, tool leases and legacy feed meaning', () => {
  const root = mkdtempSync(join(tmpdir(), 'mado-replay-contract-'));
  execFileSync('git', ['init', '-q', root]);
  const files = {
    'scripts/name-checks/rename-modules.mjs': readFileSync(new URL('./rename-modules.mjs', import.meta.url), 'utf8'),
    'Packages/PicseeKit/Sources/PicseeCore/Item.swift': 'import PicseeCore\n',
    'scripts/ledger/fixtures/garden-gate-ledger.md': '| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |\n| ACCESS-01 | grant | Partial | unit | P0-09 | `Config/Picsee.entitlements` | unchanged |\n',
    'Packages/PicseeKit/Tests/PicseeMacUITests/Issue499PrimaryFrameTests.swift': 'guard lines.contains("project=mado") else { return }\n',
    'AppTests/Issue220UpdateConfigurationTests.swift': 'let message = "Mado feed awaits #552; never use Mado’s frozen feed"\n',
    '.agents/skills/picsee-delegator/scripts/prefs.py': 'path = "io.github.anzchy.picsee/Data/Library/Preferences/io.github.anzchy.picsee.plist"\n',
  };
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  execFileSync('git', ['-C', root, 'add', '--', ...Object.keys(files)]);
  const script = join(root, 'scripts/name-checks/rename-modules.mjs');
  const before = readFileSync(script, 'utf8');
  const run = () => spawnSync(process.execPath, [script], { cwd: join(root, 'AppTests'), encoding: 'utf8' });
  const first = run();
  assert.equal(first.status, 0, first.stderr);
  assert.equal(existsSync(join(root, 'Packages/MadoKit/Sources/MadoCore/Item.swift')), true, 'replay must move the package even when invoked from a subdirectory');
  assert.equal(readFileSync(join(root, 'Packages/MadoKit/Sources/MadoCore/Item.swift'), 'utf8'), 'import MadoCore\n');
  assert.match(readFileSync(join(root, 'scripts/ledger/fixtures/garden-gate-ledger.md'), 'utf8'), /`Config\/Mado\.entitlements`/);
  assert.match(readFileSync(join(root, 'Packages/MadoKit/Tests/MadoMacUITests/Issue499PrimaryFrameTests.swift'), 'utf8'), /"project=picsee"/);
  assert.match(readFileSync(join(root, 'AppTests/Issue220UpdateConfigurationTests.swift'), 'utf8'), /never use the frozen legacy feed/);
  assert.equal(readFileSync(join(root, '.agents/skills/picsee-delegator/scripts/prefs.py'), 'utf8'), 'path = "io.github.anzchy.mado/Data/Library/Preferences/io.github.anzchy.mado.plist"\n');
  assert.equal(readFileSync(script, 'utf8'), before);
  const snapshot = () => execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean)
    .map(path => [path, lstatSync(join(root, path)).isSymbolicLink() ? readlinkSync(join(root, path)) : readFileSync(join(root, path)).toString('base64')]);
  const after = snapshot(), second = run();
  assert.equal(second.status, 0, second.stderr);
  assert.match(second.stdout, /0 tracked text files rewritten/);
  assert.deepEqual(snapshot(), after);
});
