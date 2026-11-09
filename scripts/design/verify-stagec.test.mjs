// Stage C verification only (#411/#587): this draft PR must show Design check red and be blocked. Never merge.
import test from 'node:test';
import assert from 'node:assert/strict';
test('stage C: Design check failure blocks merge', () => { assert.fail('deliberate Design check failure'); });
