#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$repo_root"
out="${1:-$repo_root/.build/issue358-coverage}"
mkdir -p "$out"
before="$(date +%s)"
head="$(git rev-parse HEAD)"
export PICSEE_HEAVY_LOCK_WAIT_SECS="${PICSEE_HEAVY_LOCK_WAIT_SECS:-7200}"

scripts/heavy-lock.sh swift test --package-path Packages/MadoKit --enable-code-coverage --jobs 4 > "$out/tests.log" 2>&1
binary="Packages/MadoKit/.build/arm64-apple-macosx/debug/MadoKitPackageTests.xctest/Contents/MacOS/MadoKitPackageTests"
profile="Packages/MadoKit/.build/arm64-apple-macosx/debug/codecov/default.profdata"
test -s "$binary" && test -s "$profile"
test "$(stat -f %m "$profile")" -ge "$before"
test "$(git rev-parse HEAD)" = "$head"
scripts/heavy-lock.sh xcrun llvm-cov export "$binary" "-instr-profile=$profile" -format=lcov > "$out/coverage.lcov"
scripts/heavy-lock.sh xcrun llvm-cov export "$binary" "-instr-profile=$profile" -format=text > "$out/coverage.json"
{
  printf 'commit=%s\n' "$head"
  xcodebuild -version
  swift --version
  xcrun llvm-cov --version
  shasum -a 256 "$binary" "$profile" "$out/coverage.lcov" "$out/coverage.json"
} > "$out/provenance.txt"
node scripts/coverage/issue358-check.mjs "$out/coverage.lcov" "$out/coverage.json"
