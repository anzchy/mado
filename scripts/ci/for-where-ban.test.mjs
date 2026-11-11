import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findForWhere, scanTree } from './for-where-ban.mjs';

test('Swift source has no for-where loops (issue #358)', () => {
  const root = process.env.PICSEE_FOR_WHERE_SOURCE_ROOT ?? new URL('../../Packages/MadoKit/Sources/', import.meta.url).pathname;
  const hits = scanTree(root);
  assert.deepEqual(hits, [], `issue #358: replace for … where with a leading guard: ${hits.join(', ')}`);
});

test('gate handles multiline and for-case, ignoring comments and string literals', () => {
  assert.deepEqual(findForWhere('for case let .some(x) in values\n where x > 0 { use(x) }'), [1]);
  assert.deepEqual(findForWhere('for x in xs\n where x > 0 { use(x) }'), [1]);
  assert.deepEqual(findForWhere('// for x in xs where true {}\n/* for x in xs where true {} */\nlet s = "for x in xs where true {}"\nfor x in xs { use(x) }'), []);
  assert.deepEqual(findForWhere('for x in xs { if xs.contains(where: { $0 == x }) {} }'), []);
  assert.deepEqual(findForWhere('/* outer /* for x in xs where true {} */ still comment */\nfor x in xs { use(x) }'), []);
  assert.deepEqual(findForWhere('let raw = #"for x in xs where true {}"#\nlet multi = """\nfor x in xs where true {}\n"""'), []);
  assert.deepEqual(findForWhere('/// for x in xs where true {}\nstruct Box<T> where T: Sendable {}'), []);

});

test('gate discovers a loop in a newly added source file', () => {
  const root = mkdtempSync(join(tmpdir(), 'issue358-ban-'));
  try {
    mkdirSync(join(root, 'New'));
    writeFileSync(join(root, 'New', 'Code.swift'), '// for x in xs where false {}\nfor x in xs\nwhere x > 0 { use(x) }\n');
    assert.deepEqual(scanTree(root), ['New/Code.swift:2']);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
