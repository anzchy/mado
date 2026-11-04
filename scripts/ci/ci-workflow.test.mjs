// Structural checks on .github/workflows/ci.yml that keep the required checks and the main-branch guarantees intact.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const jobBlock = id => {
  const match = workflow.match(new RegExp(`^  ${id}:\\n([\\s\\S]*?)(?=^  [a-z][a-z0-9-]*:\\n|(?![\\s\\S]))`, 'm'));
  assert.ok(match, `job ${id} exists`);
  return match[1];
};

test('main pushes and dispatches never share a concurrency group; pull requests cancel older runs', () => {
  assert.match(workflow, /^  group: \$\{\{ github\.workflow \}\}-\$\{\{ github\.event_name == 'pull_request' && github\.ref \|\| github\.run_id \}\}$/m);
  assert.match(workflow, /^  cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}$/m);
});

test('the App tests job keeps the exact unsigned build as its own step, and Walking skeleton reads that step', () => {
  assert.doesNotMatch(workflow, /^  unsigned-build:$/m, 'no separate unsigned-build job');
  const app = jobBlock('app-tests');
  const steps = app.split(/^      - name: /m);
  const build = steps.find(step => step.startsWith('Build unsigned app\n'));
  assert.ok(build, 'Build unsigned app step exists');
  assert.match(build, /^        id: unsigned-build$/m);
  assert.match(build, /^        run: xcodebuild build -scheme Picsee -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath \.build\/dd-ci\b/m);
  assert.doesNotMatch(build, /^        if:/m, 'the unsigned build runs on every event');
  assert.match(app, /^      unsigned_build: \$\{\{ steps\.unsigned-build\.outcome \}\}$/m);
  assert.ok(app.indexOf('Build unsigned app\n') < app.indexOf('Build App tests\n'), 'build runs before build-for-testing');
  const skeleton = jobBlock('walking-skeleton');
  assert.match(skeleton, /^    if: always\(\)$/m);
  for (const need of ['ledger-check', 'package-tests', 'package-macui-tests', 'app-tests']) {
    assert.match(skeleton, new RegExp(`^    needs: \\[.*\\b${need}\\b.*\\]$`, 'm'), need);
  }
  assert.match(skeleton, /^          UNSIGNED_BUILD: \$\{\{ needs\.app-tests\.outputs\.unsigned_build \}\}$/m);
  assert.match(skeleton, /^        run: node scripts\/ci\/walking-skeleton\.mjs$/m);
});

test('the ledger check runs on Ubuntu', () => {
  const ledger = jobBlock('ledger-check');
  assert.match(ledger, /^    runs-on: ubuntu-latest$/m);
  assert.match(ledger, /^        run: node scripts\/ledger\/build\.mjs --check$/m);
  assert.doesNotMatch(ledger, /^    if:/m);
});

test('native jobs run only on the classifier saying so; Walking skeleton always reports and reads the classifier', () => {
  const changes = jobBlock('changes');
  assert.match(changes, /^    runs-on: ubuntu-latest$/m);
  assert.doesNotMatch(changes, /^    if:/m, 'the classifier runs on every event');
  assert.match(changes, /^      native: \$\{\{ steps\.classify\.outputs\.native \}\}$/m);
  assert.match(changes, /ref: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.sha \}\}\n          path: trusted/);
  assert.match(changes, /^            node trusted\/scripts\/ci\/native-inputs\.mjs$/m);
  assert.match(changes, /^            echo 'native=true' >> "\$GITHUB_OUTPUT"$/m, 'a base without the classifier runs native jobs');
  assert.match(changes, /^      pull-requests: read$/m);
  for (const id of ['package-tests', 'package-macui-tests', 'app-tests']) {
    const job = jobBlock(id);
    assert.match(job, /^    needs: changes$/m, id);
    assert.match(job, /^    if: needs\.changes\.outputs\.native == 'true'$/m, id);
  }
  const skeleton = jobBlock('walking-skeleton');
  assert.match(skeleton, /^    needs: \[changes, /m);
  assert.match(skeleton, /^          CHANGES: \$\{\{ needs\.changes\.result \}\}$/m);
  assert.match(skeleton, /^          NATIVE: \$\{\{ needs\.changes\.outputs\.native \}\}$/m);
  assert.doesNotMatch(workflow, /paths-ignore:|^\s+paths:/m, 'no workflow-level path filters: required checks must report');
});
