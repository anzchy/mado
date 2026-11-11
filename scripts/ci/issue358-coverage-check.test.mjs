import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const targets = [
  ['Packages/MadoKit/Sources/MadoInfrastructure/FileAccess/FileAccess.swift', '$s18MadoInfrastructure10FileAccessC20persistedDestination'],
  ['Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift', '$s9MadoMacUI19ViewerChromeOverlayC7hitTestySo7CGPointVF'],
];

function runFixture(defect) {
  const dir = mkdtempSync(join(tmpdir(), 'issue358-coverage-'));
  try {
    const functions = targets.map(([file, name]) => ({
      name, filenames: [`/repo/${file}`], count: 1,
      regions: [[1, 1, 5, 1, 1, 0, 0, 0], [3, 10, 4, 19, 0, 0, 0]],
    }));
    const lcov = targets.map(([file], index) => `SF:/repo/${file}\n${[1, 2, 3, 4, 5]
      .filter((line) => !(defect?.kind === 'missing' && defect.target === index && defect.line === line))
      .map((line) => `DA:${line},${defect?.kind === 'wrapped' && defect.target === index && defect.line === line ? '18446744073709551615' : line === 3 || line === 4 ? 0 : 1}\n`).join('')}end_of_record\n`).join('');
    const lcovPath = join(dir, 'coverage.lcov'), textPath = join(dir, 'coverage.json');
    writeFileSync(lcovPath, lcov);
    writeFileSync(textPath, JSON.stringify({ data: [{ functions }] }));
    return spawnSync(process.execPath, [new URL('../coverage/issue358-check.mjs', import.meta.url).pathname, lcovPath, textPath], { encoding: 'utf8' });
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test('coverage checker accepts finite mapped post-loop lines', () => {
  assert.equal(runFixture(null).status, 0);
});

test('coverage checker fails if either post-loop DA line is absent', () => {
  for (const target of [0, 1]) for (const line of [3, 4]) {
    const result = runFixture({ kind: 'missing', target, line });
    assert.equal(result.status, 1, `target ${target}, line ${line}: ${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /post-loop/);
  }
});

test('coverage checker rejects wrapped post-loop DA counts', () => {
  for (const target of [0, 1]) {
    const result = runFixture({ kind: 'wrapped', target, line: 4 });
    assert.equal(result.status, 1, `target ${target}: ${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /post-loop DA=.*invalid/);
  }
});
