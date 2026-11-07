#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

marketing_version=0.0.9
build_version=42
derived_data=.build/dd-version-override

source_marketing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)
source_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist)
if [ "$source_marketing" != '$(MARKETING_VERSION)' ] || [ "$source_build" != '$(CURRENT_PROJECT_VERSION)' ]; then
  printf 'App/Info.plist must use MARKETING_VERSION and CURRENT_PROJECT_VERSION placeholders\n' >&2
  exit 1
fi

xcodegen generate
xcodebuild build -scheme Mado -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath "$derived_data" \
  MARKETING_VERSION="$marketing_version" CURRENT_PROJECT_VERSION="$build_version"

plist="$derived_data/Build/Products/Debug/Mado.app/Contents/Info.plist"
actual_marketing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")

if [ "$actual_marketing" != "$marketing_version" ] || [ "$actual_build" != "$build_version" ]; then
  printf 'App version override failed: expected %s (%s), got %s (%s)\n' \
    "$marketing_version" "$build_version" "$actual_marketing" "$actual_build" >&2
  exit 1
fi

printf 'App version override passed: %s (%s)\n' "$actual_marketing" "$actual_build"
