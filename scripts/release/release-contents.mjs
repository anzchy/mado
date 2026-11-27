// The release-contents path filter (#861), defined once. A pull request that changes any of these paths can change
// what ends up in the shipped Mado.app or the embedded Capture helper, or their entitlements, or the build and checks
// that decide it. CI's PR-time Release build runs only then; it builds with scripts/release/release-build.sh, the
// same script the release workflow uses. scripts/ci/native-inputs.mjs applies this filter from the trusted base commit,
// so a pull request cannot loosen the rule that judges it. Any doubt (a malformed path or file list) counts as release
// content. Pushes and dispatches never run the PR-time build: the tag and rehearsal runs build signed instead.
// It imports nothing from the repository: native-inputs.mjs loads it from main() under a top-level await, so an import
// back into native-inputs.mjs would be a cycle that never settles (the entry script exited 13 with no output).

// The project definition, the app's Info.plist, the package manifest and pins, and the workflows and the composite
// action that set up and run the Release build.
export const RELEASE_FILES = ['project.yml', 'Packages/MadoKit/Package.swift', 'Packages/MadoKit/Package.resolved',
  '.github/workflows/ci.yml', '.github/workflows/release.yml', 'scripts/ci/native-inputs.mjs'];
// The Capture helper target (all of it), the release build and check scripts with their layout fixtures, the
// product-identity check, and the Xcode setup action.
export const RELEASE_PREFIXES = ['App/CaptureHelper/', 'scripts/release/', 'scripts/name-checks/', '.github/actions/xcode-setup/'];
// XcodeGen turns every non-Swift file under App/ into a bundle resource; a package target's resources live beside
// its sources.
const RESOURCE_ROOTS = ['App/', 'Packages/MadoKit/Sources/'];

/** True when the repository path can change the shipped app's contents or entitlements, or is not a clean path. */
export function releaseContent(file) {
  if (typeof file !== 'string' || !file || file.startsWith('/') || file.includes('\\') ||
      file.split('/').some(part => part === '' || part === '.' || part === '..')) return true;
  if (RELEASE_FILES.includes(file) || RELEASE_PREFIXES.some(prefix => file.startsWith(prefix))) return true;
  if (file.endsWith('.entitlements')) return true;
  return RESOURCE_ROOTS.some(root => file.startsWith(root)) && !file.endsWith('.swift');
}

/**
 * Pure decision for one CI run. `listed` is native-inputs.mjs's listChangedFiles result for the pull request:
 * `{ files, count }`, or `{ error }` when the file list cannot be trusted.
 */
export function classifyRelease({ event, listed } = {}) {
  if (event !== 'pull_request') return { release: false, reason: `event ${event}: the PR-time Release build runs on pull requests only` };
  if (!listed || listed.error || !Array.isArray(listed.files)) return { release: true, reason: listed?.error ?? 'no file list' };
  const hit = listed.files.find(releaseContent);
  if (hit !== undefined) return { release: true, reason: `release content changed: ${hit}` };
  return { release: false, reason: `no release-content input among ${listed.count} changed files` };
}
