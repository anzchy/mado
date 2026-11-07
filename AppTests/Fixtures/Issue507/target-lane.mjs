import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { parseAppResult } from '../../../scripts/tdd/app-lane.mjs';
// Run from the repository root. Only #507 tests are selected; validate full root-run completion.
mkdirSync('.build/i507', { recursive: true });
const id = 'PicseeAppTests.issue507FolderPathsComplete(legacyScanner:)';
const extra = 'PicseeAppTests.issue507EquivalentGrantsKeepOneRootAndRejectMissingTarget()';
const rows = [
  { id, kind: 'swift', label: 'issue507FolderPathsComplete(legacyScanner:)' },
  { id: extra, kind: 'swift', label: 'issue507EquivalentGrantsKeepOneRootAndRejectMissingTarget()' },
  { id: 'PicseeAppTests.issue507LinkedFirstGrantKeepsCanonicalRootIdentity()', kind: 'swift', label: 'issue507LinkedFirstGrantKeepsCanonicalRootIdentity()' },
  { id: 'PicseeAppTests.issue507FooterDirectoryBookmarkPreservesDirectoryHint(existing:)', kind: 'swift', label: 'issue507FooterDirectoryBookmarkPreservesDirectoryHint(existing:)' },
  { id: 'PicseeAppTests.issue507FooterBookmarkVerifiesRawSymlinkParentSelection()', kind: 'swift', label: 'issue507FooterBookmarkVerifiesRawSymlinkParentSelection()' },
  { id: 'PicseeAppTests.issue507DeliveredFoldersTakeTheFolderPanel(legacyScanner:)', kind: 'swift', label: 'issue507DeliveredFoldersTakeTheFolderPanel(legacyScanner:)' },
  { id: 'PicseeAppTests.issue507CancelledFolderPanelLeavesNoGrant()', kind: 'swift', label: 'issue507CancelledFolderPanelLeavesNoGrant()' },
  { id: 'PicseeAppTests.issue507UnreadableDeliveredFolderKeepsTheSelectedURLForThePrompt()', kind: 'swift', label: 'issue507UnreadableDeliveredFolderKeepsTheSelectedURLForThePrompt()' },
  { id: 'PicseeAppTests.issue507NonFolderInputNeverPromptsForAFolder(input:)', kind: 'swift', label: 'issue507NonFolderInputNeverPromptsForAFolder(input:)' }
];
const run = spawnSync('scripts/heavy-lock.sh', ['xcrun', 'xctest', '-XCTest', rows.map(row => row.id).join(','),
  '.build/dd-ci/Build/Products/Debug/PicseeAppTests.xctest'], {
  encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
  env: { ...process.env, SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: '1' }
});
process.stdout.write(run.stdout ?? '');
process.stderr.write(run.stderr ?? '');
const result = parseAppResult(run, { inventory: rows, retained: rows });
writeFileSync('.build/i507/target-result.json', JSON.stringify(result, null, 2));
if (result.reliable) console.log(`Tests run: ${result.count}, Failures: ${result.failed}, Errors: 0, Skipped: ${result.skipped}`);
else console.error('app-red: incomplete selected test output; environment failure');
process.exitCode = result.status;
