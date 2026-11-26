#!/bin/bash
# #901 (owner 2026-11-25): one task, one worktree. Creates ~/Documents/mac-app/picsee-wt/<issue>-<slug> and its branch
# from <base> (default origin/main), installs the Codex implementor role overlay with --codex, writes the dispatch
# marker in the pane home through mark-target.mjs, and prints the paths and the dispatch lines.
# The delegator runs it from its own checkout: this script's mark-target.mjs and install-role.py are the ones used.
set -u
usage='usage: new-task-worktree.sh <issue> <slug> [<base>] --pane-home <path> --task <Report-Task> --handoff <absolute-path> [--branch <name>] [--existing-branch] [--codex] [--pane <wN:pM>] [--brief <path>] [--root <dir>]'
die() { echo "new-task-worktree: $*" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd -P)
mark_target="$here/../../mado-verify/scripts/mark-target.mjs"
install_role="$here/../../../../scripts/codex-rules/install-role.py"

positional=() pane_home='' task='' handoff='' branch='' existing=0 codex=0 pane='<pane>' brief='<brief>'
root="$HOME/Documents/mac-app/picsee-wt"
while (( $# )); do
  case "$1" in
    --pane-home|--task|--handoff|--branch|--pane|--brief|--root)
      (( $# >= 2 )) || die "$1 needs a value; $usage"
      case "$1" in
        --pane-home) pane_home=$2 ;; --task) task=$2 ;; --handoff) handoff=$2 ;; --branch) branch=$2 ;;
        --pane) pane=$2 ;; --brief) brief=$2 ;; --root) root=$2 ;;
      esac
      shift 2 ;;
    --existing-branch) existing=1; shift ;;
    --codex) codex=1; shift ;;
    -*) die "unknown option $1; $usage" ;;
    *) positional+=("$1"); shift ;;
  esac
done
(( ${#positional[@]} >= 2 && ${#positional[@]} <= 3 )) || die "$usage"
issue=${positional[0]} slug=${positional[1]} base=${positional[2]:-origin/main}
[[ $issue =~ ^[1-9][0-9]*$ ]] || die "issue must be a positive number, got '$issue'"
[[ $slug =~ ^[a-z0-9][a-z0-9.-]*$ && $slug != *..* ]] || die "slug must be lowercase letters, digits, '.' or '-', got '$slug'"
[[ -n $pane_home && -n $task && -n $handoff ]] || die "--pane-home, --task and --handoff are required; $usage"
[[ $handoff == /* ]] || die "--handoff must be an absolute path"
[[ -d $root ]] || die "root $root is not a directory"
root=$(cd "$root" && pwd -P)
target="$root/$issue-$slug"
branch=${branch:-task/$issue-$slug}

# The task worktree is never the pane home (pane homes hold the pane identity and the dispatch marker only).
home_abs=$pane_home
[[ -d $pane_home ]] && home_abs=$(cd "$pane_home" && pwd -P)
[[ $home_abs != "$target" ]] || die "$target is the pane home $pane_home; pane homes hold the pane identity only, a task needs its own worktree"
[[ ! -e $target && ! -L $target ]] || die "$target already exists; a new task gets a new worktree (a fix round continues in its own task worktree without this helper)"
[[ -d $pane_home ]] || die "pane home $pane_home is not a directory"
top=$(git -C "$home_abs" rev-parse --show-toplevel 2>/dev/null) || die "pane home $pane_home is not a git worktree"
[[ $(cd "$top" && pwd -P) == "$home_abs" ]] || die "pane home $pane_home is not a worktree root"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch name $branch"

if git -C "$home_abs" show-ref --verify --quiet "refs/heads/$branch"; then
  (( existing )) || die "branch $branch already exists; pass --existing-branch to move that task's fix round into $target, or choose another --branch"
  add=(worktree add -q "$target" "$branch")
else
  (( ! existing )) || die "--existing-branch given but branch $branch does not exist"
  git -C "$home_abs" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base $base is not a commit (git fetch origin first for origin/main)"
  # A dirty base: the base is a local branch whose worktree has uncommitted tracked changes the new task would miss.
  if git -C "$home_abs" show-ref --verify --quiet "refs/heads/$base"; then
    wt=''
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt=${line#worktree } ;;
        "branch refs/heads/$base")
          [[ -z $(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null) ]] \
            || die "base $base has uncommitted changes in $wt; commit them or pick another base" ;;
      esac
    done < <(git -C "$home_abs" worktree list --porcelain)
  fi
  add=(worktree add -q -b "$branch" "$target" "$base")
fi
git -C "$home_abs" "${add[@]}" || die "git worktree add failed for $target"

if (( codex )); then
  python3 "$install_role" --worktree "$target" --role implementor >/dev/null \
    || die "role overlay install failed in $target; the worktree exists, fix the overlay and run mark-target.mjs by hand"
fi
marker=$(node "$mark_target" "$home_abs" "$target" "$issue" "$task" "$handoff" "$branch") \
  || die "mark-target.mjs refused $target (above); the worktree exists, fix the cause and run mark-target.mjs again"

# Every printed argument is shell-quoted so a line copied as printed parses back to the same arguments (paths with
# spaces, a brief path with a quote); plain tokens stay bare.
q() {
  if [[ $1 =~ ^[A-Za-z0-9_./:@%+=,-]+$ ]]; then printf '%s' "$1"
  else local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; fi
}
name=$(basename "$home_abs")
prompt="New task: Worktree: $target (branch $branch; one task, one worktree, work only there). Read and follow $brief. Do not push."
echo "worktree: $target"
echo "branch: $branch"
echo "marker: $marker"
if (( codex )); then
  echo "overlay: $target/.codex/rules/picsee-role.rules"
  echo "dispatch (Codex): .agents/skills/mado-delegator/scripts/start-fresh-codex.sh $(q "$pane") $(q "$name") --cwd $(q "$home_abs") --task-worktree $(q "$target") --prompt $(q "$prompt")"
else
  echo "dispatch (Claude): herdr pane send-text $(q "$pane") '/clear' && herdr pane send-keys $(q "$pane") Enter; confirm Context 0%; then herdr pane send-text $(q "$pane") $(q "$prompt") && herdr pane send-keys $(q "$pane") Enter"
fi
