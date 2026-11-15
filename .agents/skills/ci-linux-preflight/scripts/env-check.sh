#!/bin/bash
set -u
if [[ -d /opt/node/bin ]]; then export PATH=/opt/node/bin:$PATH; fi

failed=0
for tool in node git python3 zsh ps; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%s missing FAIL\n' "$tool"
    failed=1
    continue
  fi
  version=$("$tool" --version 2>&1)
  ok=1
  case "$tool" in
    node) [[ "$version" == v22.* ]] || ok=0 ;;
    git)
      number=${version##* }
      IFS=. read -r major minor _ <<< "$number"
      if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] ||
         (( major < 2 || (major == 2 && minor < 36) )); then ok=0; fi ;;
    ps) [[ "$version" == *procps* ]] || ok=0 ;;
  esac
  if (( ok )); then
    printf '%s %s OK\n' "$tool" "$version"
  else
    printf '%s %s FAIL\n' "$tool" "$version"
    failed=1
  fi
done
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  printf '%s\n' 'sudo passwordless FAIL'
  failed=1
else
  printf '%s\n' 'sudo unavailable OK'
fi
exit "$failed"
