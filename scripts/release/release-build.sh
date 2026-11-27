#!/bin/bash
# The Release build and its checks, defined once (#861). The release workflow (tag and rehearsal) runs it with the
# Developer ID identity; CI's PR-time Release build runs it ad-hoc signed, with no identity and no secrets. Each
# subcommand is one workflow step; values for later steps go to $GITHUB_ENV (when set) and are printed.
#
#   scripts/release/release-build.sh version                      VERSION (MARKETING_VERSION) and BUILD (commit count)
#   scripts/release/release-build.sh sparkle-tools                download Sparkle 2.10.0's tools, pinned by SHA-256
#   scripts/release/release-build.sh build developer-id|ad-hoc    xcodebuild the Release Mado.app into .build/dd-release
#   scripts/release/release-build.sh licence                      bundle Sparkle's LICENSE into the app
#   scripts/release/release-build.sh check-entitlements|check-identity|check-package
#
# build reads BUILD; developer-id also reads IDENTITY, KEYCHAIN and DEVELOPMENT_TEAM. licence reads APP and
# SPARKLE_TOOLS; the checks read APP, and check-package also VERSION and BUILD.
set -euo pipefail

SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
BUNDLE_ID=io.github.anzchy.mado
DERIVED_DATA=.build/dd-release

# What an ad-hoc build cannot show; printed to the log and the job summary.
AD_HOC_LIMIT="Ad-hoc signed Release build: no Developer ID identity and no secrets. Its entitlements, product identity and package layout are checked; not covered here: Developer ID signatures and their _CodeSignature entries, Sparkle's re-signed helpers, secure timestamps, notarisation, stapling and Gatekeeper. The signed release rehearsal (release.yml workflow_dispatch, #860) covers those."

export_value() {
  echo "$1=$2"
  if [[ -n "${GITHUB_ENV:-}" ]]; then echo "$1=$2" >> "$GITHUB_ENV"; fi
}
fail() { echo "::error::$1" >&2; exit 1; }
need() { [[ -n "${!1:-}" ]] || fail "release-build.sh $2 needs $1"; }

cmd_version() {
  local version
  version=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1)
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION in project.yml is not MAJOR.MINOR.PATCH: $version"
  export_value VERSION "$version"
  export_value BUILD "$(git rev-list --count HEAD)"
}

cmd_sparkle_tools() {
  local tools="${RUNNER_TEMP:?}/sparkle-$SPARKLE_VERSION" tarball="$RUNNER_TEMP/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl --fail --location --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    --output "$tarball"
  echo "$SPARKLE_SHA256  $tarball" | shasum -a 256 --check
  mkdir -p "$tools"
  tar -xJf "$tarball" -C "$tools"
  test -x "$tools/bin/sign_update"
  grep -q '^EXTERNAL LICENSES' "$tools/LICENSE"
  export_value SPARKLE_TOOLS "$tools"
}

cmd_build() {
  local signing="${1:-}"
  need BUILD build
  # Stripping removes the build machine's paths from the binary (check-package fails on them).
  local args=(build -scheme Mado -configuration Release -destination 'generic/platform=macOS'
    -derivedDataPath "$DERIVED_DATA" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES "CURRENT_PROJECT_VERSION=$BUILD" CODE_SIGN_STYLE=Manual)
  case "$signing" in
    developer-id)
      need IDENTITY "build developer-id"; need KEYCHAIN "build developer-id"; need DEVELOPMENT_TEAM "build developer-id"
      args+=("CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" "OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN --timestamp")
      ;;
    ad-hoc)
      # "-" signs without an identity, so codesign can still read the entitlements the build embedded.
      args+=("CODE_SIGN_IDENTITY=-" "DEVELOPMENT_TEAM=")
      echo "$AD_HOC_LIMIT"
      if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$AD_HOC_LIMIT" >> "$GITHUB_STEP_SUMMARY"; fi
      ;;
    *) echo "usage: release-build.sh build developer-id|ad-hoc" >&2; exit 2 ;;
  esac
  xcodebuild "${args[@]}"
  local app="$PWD/$DERIVED_DATA/Build/Products/Release/Mado.app"
  test -d "$app" || fail "xcodebuild did not produce $app"
  export_value APP "$app"
}

cmd_licence() {
  need APP licence; need SPARKLE_TOOLS licence
  # Sparkle's LICENSE carries its own MIT licence and its EXTERNAL LICENSES notices (#220 M2).
  local embedded
  embedded=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist")
  [[ "$embedded" == "$SPARKLE_VERSION" ]] || fail "embedded Sparkle is $embedded, licence is for $SPARKLE_VERSION"
  mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
  cp "$SPARKLE_TOOLS/LICENSE" "$APP/Contents/Resources/ThirdPartyNotices/Sparkle-$SPARKLE_VERSION-LICENSE.txt"
}

case "${1:-}" in
  version) cmd_version ;;
  sparkle-tools) cmd_sparkle_tools ;;
  build) cmd_build "${2:-}" ;;
  licence) cmd_licence ;;
  check-entitlements) need APP "$1"; node scripts/release/check-entitlements.mjs "$APP" --configuration release --expect-bundle-id "$BUNDLE_ID" ;;
  check-identity) need APP "$1"; node scripts/name-checks/built-product.mjs "$APP" --release ;;
  check-package)
    need APP "$1"; need VERSION "$1"; need BUILD "$1"
    node scripts/release/check-package.mjs "$APP" --require-sparkle-licence --expect-version "$VERSION" --expect-build "$BUILD"
    ;;
  *)
    echo "usage: release-build.sh version|sparkle-tools|build developer-id|ad-hoc|licence|check-entitlements|check-identity|check-package" >&2
    exit 2
    ;;
esac
