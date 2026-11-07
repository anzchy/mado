import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { parseAppResult } from '../../../scripts/tdd/app-lane.mjs';
// Run from the repository root. Only this test is selected; the repository parser validates full completion.
mkdirSync('.build/i507', { recursive: true });
const id = 'PicseeAppTests.issue507FolderPathsComplete(legacyScanner:)';
const row = { id, kind: 'swift', label: 'issue507FolderPathsComplete(legacyScanner:)' };
const run = spawnSync('scripts/heavy-lock.sh', ['xcrun', 'xctest', '-XCTest', id,
  '.build/dd-ci/Build/Products/Debug/PicseeAppTests.xctest'], {
  encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
  env: { ...process.env, SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: '1' }
});
process.stdout.write(run.stdout ?? '');
process.stderr.write(run.stderr ?? '');
const result = parseAppResult(run, { inventory: [row], retained: [row] });
writeFileSync('.build/i507/target-result.json', JSON.stringify(result, null, 2));
if (result.reliable) console.log(`Tests run: ${result.count}, Failures: ${result.failed}, Errors: 0, Skipped: ${result.skipped}`);
else console.error('app-red: incomplete selected test output; environment failure');
process.exitCode = result.status;
