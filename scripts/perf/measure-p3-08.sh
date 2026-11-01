#!/bin/zsh
set -eu
# P3-08 (#146) measurement on a signed Release Picsee. Device step only: it launches the App and runs your
# --driver command; it never runs in CI. Usage and the run recipe: docs/validation/P3.md「P3-08 测量方法」.
exec node "${0:A:h}/p308.mjs" "$@"
