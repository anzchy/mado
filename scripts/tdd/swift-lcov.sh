#!/bin/sh
# Export MadoKit's Swift test coverage as LCOV for tdd-guardian's coverage gate.
# Run after `swift test --package-path Packages/MadoKit --enable-code-coverage`.
# The test bundle path is derived, not hardcoded, so renaming the package
# cannot silently leave the gate reading a stale profile.
set -eu

pkg=Packages/MadoKit
out=coverage/lcov.info
bin=$(swift build --package-path "$pkg" --show-bin-path)
profdata="$bin/codecov/default.profdata"
bundle=$(find "$bin" -maxdepth 1 -name '*PackageTests.xctest' | head -n 1)

if [ ! -f "$profdata" ] || [ -z "$bundle" ]; then
  echo "swift-lcov: no coverage profile under $bin; run swift test --enable-code-coverage first" >&2
  exit 1
fi

exe="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
mkdir -p "$(dirname "$out")"
xcrun llvm-cov export -format=lcov -instr-profile "$profdata" "$exe" \
  -ignore-filename-regex='(\.build/|/Tests/)' > "$out"
echo "swift-lcov: wrote $out"
