#!/bin/zsh -f
emulate -R zsh
setopt no_unset

failed=0
for tool in node git python3 zsh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print -- "$tool missing FAIL"
    failed=1
    continue
  fi
  case "$tool" in
    node) version=$(node --version 2>&1); [[ "$version" == v22.* ]] || failed=1 ;;
    git) version=$(git --version 2>&1); number=${version##* }; parts=(${(s:.:)number}); (( parts[1] > 2 || (parts[1] == 2 && parts[2] >= 36) )) || failed=1 ;;
    python3) version=$(python3 --version 2>&1) ;;
    zsh) version=$(zsh --version 2>&1) ;;
  esac
  if [[ "$tool" == node && "$version" != v22.* ]] || [[ "$tool" == git && ( ${parts[1]:-0} -lt 2 || ( ${parts[1]:-0} -eq 2 && ${parts[2]:-0} -lt 36 ) ) ]]; then
    print -- "$tool $version FAIL"
  else
    print -- "$tool $version OK"
  fi
done
exit $failed
