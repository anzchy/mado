#!/bin/bash
# Submit one file to Apple's notary service and wait. Fails unless the submission is Accepted,
# printing Apple's log so the run shows why. Credentials come from the environment (GitHub Secrets).
#
#   APPLE_ID=… APPLE_APP_SPECIFIC_PASSWORD=… DEVELOPMENT_TEAM=… scripts/release/notarize.sh Mado.zip
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  printf 'usage: notarize.sh <file to notarise>\n' >&2
  exit 2
fi
: "${APPLE_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}" "${DEVELOPMENT_TEAM:?}"

result=$(xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$DEVELOPMENT_TEAM" --wait --output-format json)
id=$(printf '%s' "$result" | /usr/bin/plutil -extract id raw -o - -)
status=$(printf '%s' "$result" | /usr/bin/plutil -extract status raw -o - -)
printf 'notarytool submission %s: %s\n' "$id" "$status"
if [[ "$status" != "Accepted" ]]; then
  xcrun notarytool log "$id" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$DEVELOPMENT_TEAM" >&2 || true
  exit 1
fi
