import assert from 'node:assert/strict';
import test from 'node:test';
import { classifyRelease, releaseContent } from './release-contents.mjs';

const entry = (filename, extra = {}) => ({ filename, status: 'modified', ...extra });
const pr = (...files) => classifyRelease({ event: 'pull_request', changedFiles: files.length, pages: [files] });

test('#861: inputs that decide the shipped app contents or entitlements are release content', () => {
  for (const file of ['project.yml', 'App/Resources/Mado.entitlements', 'App/CaptureHelper/CaptureHelper.entitlements',
    'Some/Other/New.entitlements', 'App/Info.plist', 'App/CaptureHelper/Info.plist', 'App/CaptureHelper/CaptureBarView.swift',
    'App/Resources/Localizable.xcstrings', 'App/Resources/Assets.xcassets/Contents.json', 'App/Resources/new-file.json',
    'App/Viewer/notes.txt', 'Packages/MadoKit/Package.swift', 'Packages/MadoKit/Package.resolved',
    'Packages/MadoKit/Sources/MadoMacUI/B4Samples/alley.jpg', 'Packages/MadoKit/Sources/MadoCore/data.json',
    'scripts/release/check-package.mjs', 'scripts/release/check-entitlements.mjs', 'scripts/release/release-build.sh',
    'scripts/release/release-contents.mjs', 'scripts/release/fixtures/release-layout-0.0.1.txt',
    'scripts/name-checks/built-product.mjs', 'scripts/name-checks/identity.json', 'scripts/ci/native-inputs.mjs',
    '.github/workflows/ci.yml', '.github/workflows/release.yml', '.github/actions/xcode-setup/action.yml']) {
    assert.equal(releaseContent(file), true, file);
  }
});

test('#861: app Swift sources, tests, docs and unrelated tooling are not release content', () => {
  for (const file of ['App/AppDelegate.swift', 'App/Viewer/ViewerView.swift', 'Packages/MadoKit/Sources/MadoCore/ItemID.swift',
    'Packages/MadoKit/Tests/MadoCoreTests/ItemIDTests.swift', 'Packages/MadoKit/Tests/MadoCoreTests/fixture.json',
    'AppTests/X.swift', 'UITests/X.swift', 'docs/release/README.md', 'AGENTS.md', 'scripts/ci/walking-skeleton.mjs',
    'scripts/agents/gates-rows.mjs', '.github/workflows/pr-body.yml', 'TestAssets/synthetic/a.png', 'package.json',
    'design/DESIGN.md', 'App', 'Appx/a.json', 'project.yml.bak']) {
    assert.equal(releaseContent(file), false, file);
  }
});

test('#861: path tricks count as release content (any doubt runs the build)', () => {
  for (const file of ['docs/../project.yml', '/project.yml', 'docs//a.md', './docs/a.md', 'docs\\..\\App', '', null, 7]) {
    assert.equal(releaseContent(file), true, String(file));
  }
});

test('#861: a pull request that touches the filter runs the Release build; one that does not skips it', () => {
  assert.equal(pr(entry('docs/a.md'), entry('App/Resources/Mado.entitlements')).release, true);
  assert.equal(pr(entry('docs/a.md'), entry('App/AppDelegate.swift')).release, false);
  assert.match(pr(entry('App/AppDelegate.swift')).reason, /no release-content input/);
  assert.match(pr(entry('project.yml')).reason, /release content changed: project\.yml/);
});

test('#861: a rename counts both ends', () => {
  assert.equal(pr(entry('docs/moved.json', { status: 'renamed', previous_filename: 'App/Resources/moved.json' })).release, true);
  assert.equal(pr(entry('App/Resources/new.json', { status: 'renamed', previous_filename: 'docs/new.json' })).release, true);
  assert.equal(pr(entry('docs/b.md', { status: 'renamed', previous_filename: 'docs/a.md' })).release, false);
});

test('#861: an incomplete or malformed file list runs the Release build', () => {
  const docs = entry('docs/a.md');
  for (const [name, result] of Object.entries({
    'count mismatch': classifyRelease({ event: 'pull_request', changedFiles: 2, pages: [[docs]] }),
    'missing changed_files': classifyRelease({ event: 'pull_request', pages: [[docs]] }),
    'no pages': classifyRelease({ event: 'pull_request', changedFiles: 1, pages: [] }),
    'malformed entry': classifyRelease({ event: 'pull_request', changedFiles: 1, pages: [[{ status: 'modified' }]] }),
    'rename without previous_filename': pr(entry('docs/b.md', { status: 'renamed' })),
    'error page': classifyRelease({ event: 'pull_request', changedFiles: 1, pages: [{ message: 'Not Found' }] }),
  })) {
    assert.equal(result.release, true, name);
  }
});

test('#861: pushes and dispatches never run the PR-time Release build', () => {
  for (const event of ['push', 'workflow_dispatch', 'merge_group']) {
    const result = classifyRelease({ event });
    assert.equal(result.release, false, event);
    assert.match(result.reason, /pull requests only/);
  }
});
