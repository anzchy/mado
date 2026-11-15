#!/bin/zsh -f
emulate -R zsh
if [[ -d /opt/node/bin ]]; then export PATH=/opt/node/bin:$PATH; fi

failed=0
for tool in node git python3 zsh ps; do
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
    ps) version=$(ps --version 2>&1); [[ "$version" == *procps* ]] || failed=1 ;;
  esac
  if [[ "$tool" == node && "$version" != v22.* ]] ||
     [[ "$tool" == git && ( ${parts[1]:-0} -lt 2 || ( ${parts[1]:-0} -eq 2 && ${parts[2]:-0} -lt 36 ) ) ]] ||
     [[ "$tool" == ps && "$version" != *procps* ]]; then
    print -- "$tool $version FAIL"
  else
    print -- "$tool $version OK"
  fi
done
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  print -- 'sudo passwordless FAIL'
  failed=1
else
  print -- 'sudo unavailable OK'
fi
exit $failed
