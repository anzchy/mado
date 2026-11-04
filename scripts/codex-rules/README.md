# Codex worktree roles

`picsee.rules` contains shared safety restrictions. Codex prefix rules cannot inspect the
agent role or an option after the remote. Direct `git push` is therefore forbidden in all
roles: a third-token-only force ban misses `git push origin --force`. The appointed delegator
uses `python3 scripts/codex-rules/push-guard.py` instead. This checked entry point accepts
only the current topic branch and exactly one approved `origin` push URL, with an optional
exact lease OID for an authorized rebase push. It passes that validated URL directly to
Git, so extra remote push URLs cannot become extra destinations. It never accepts
arbitrary Git options or refspecs.

The local ignored `picsee-role.rules` adds PR bans for implementors and auditors. Their
push-guard calls fail its own role check. The delegator overlay declares its role; it cannot
override a forbidden common rule. Release/workflow, destructive, sandbox and other
pre-existing restrictions remain in the common file. Like the prior prefix rules, the
role marker is a workflow guardrail, not authentication against an agent that changes files
or invokes another executable.

Before starting Codex in **every** new worktree:

```sh
python3 scripts/codex-rules/install-role.py --worktree /absolute/worktree --role implementor
```

Use `auditor` for audit worktrees. Omitted role defaults to implementor. Only the appointed
delegator may be provisioned with `--role delegator`, under explicit user authorization.
Missing overlay means incomplete provisioning; do not launch agents until installed.
This is orchestration-enforced provisioning, not automatic role detection or a security
boundary against an agent editing its own rules. Existing AGENTS.md ownership rules apply.

The installer writes atomically, rejects unknown roles and a symlink target, and never
changes common rules. An old worktree with common unconditional push bans remains restricted
until it updates to the common rules split. A new allow entry cannot override an existing
forbidden match. Install restricted overlays before distributing the new common file.

Run `npm run rules:check`: policy commands are passed as data to `codex execpolicy check`,
never executed. Python tests mock the final push and exercise the guard's branch, role,
remote and lease checks. Tests compose both common and role rules. Project-local rules
load only when the project `.codex/` layer is trusted. Existing sessions must restart to
reload changed rules. In the restarted delegator session, a direct
`git push --dry-run origin HEAD` must be rejected by the common rule; the guard's
`--dry-run` must succeed on a topic branch. A successful guard run alone does not prove
that the common rule loaded. Check both observations without an actual remote write.

For an ordinary topic push: `python3 scripts/codex-rules/push-guard.py`.
After rebasing an owned unmerged PR branch, obtain the exact current remote tip and use
`python3 scripts/codex-rules/push-guard.py --expected-remote-oid <full-oid>`. The lease
must be the observed tip; never use the guarded force option on `main`.

Optional mdpro interop tests use `PICSEE_MDPRO_SCRIPT` for mdpro’s `scripts/heavy-lock.sh`
(Node heavy-lock tests) and `PICSEE_MDPRO_GUI_SCRIPT` for mdpro’s
`.agents/skills/mdpro-delegator/scripts/gui-lock.sh` (Python GUI-lock tests).
Run the GUI script in its repository so its heavy-lock dependency is available; only an
unset GUI variable skips, while a configured invalid script or dependency fails.

Opt in to the light pre-push checks using a trusted base containing the #449 installer protocol.
An older base is rejected explicitly; fetch and wait for #449 to land before installing:

```sh
(
  set -eu
  hook_bootstrap=$(mktemp "${TMPDIR:-/tmp}/picsee-base-pre-push.XXXXXXXX")
  trap 'rm -f "$hook_bootstrap"' 0
  git show origin/main:scripts/git-hooks/pre-push > "$hook_bootstrap"
  if [ "$(sh "$hook_bootstrap" --install-capability </dev/null)" != picsee-pre-push-installer-v1 ]; then
    echo 'pre-push: base lacks installer support; fetch a base containing #449 before installing' >&2
    exit 2
  fi
  sh "$hook_bootstrap" --install origin/main </dev/null
  installed=$(git config --local --get core.hooksPath)
  case "$installed" in
    /*) ;;
    *) echo 'pre-push: installer did not set an absolute core.hooksPath' >&2; exit 2 ;;
  esac
  [ -x "$installed/pre-push" ] || { echo 'pre-push: installed hook is missing or not executable' >&2; exit 2; }
)
```

Inspect `git config --get core.hooksPath` first: installation replaces the repository-local
setting, which applies to linked worktrees too. The installer archives the base under the
Git common directory and sets an absolute hooksPath into that snapshot. The hook, lint runner,
and checker code run from that frozen base; pushed OIDs supply the checked data. When a pushed
commit changes `scripts/ledger/` or `scripts/design/` relative to that installed base, the hook
prints “checker changed in topic — CI decides” and defers only that checker to CI. This allows
checker data and renderer updates in the same PR without executing topic checker code locally.
The unchanged checker and the trusted PR-body validator still run. A local deferred result is
not a CI pass; require the relevant CI checks before landing. Fetch and reinstall to adopt a
newer base. Installation removes its archive; it retains the current and previous selections
and snapshots from the last seven days, then prunes older snapshots. Recent snapshots remain
available for concurrent short pushes.
A relative `core.hooksPath=scripts/git-hooks` executes topic code; a worktree whose branch
predates `scripts/git-hooks/pre-push` runs no hook at all with that shared relative setting.
An absolute hooksPath also silently runs no hook if its snapshot is deleted or the repository
moves. After moving the repository, reinstall from the trusted base; preserve the configured
snapshot and verify `test -x "$(git config --get core.hooksPath)/pre-push"` before relying on it.

Git invokes the hook during the push started by `push-guard.py`, after that guard checks role
and destination. Set `PICSEE_PR_BODY=/absolute/path/to/body.md` to also lint the body against
the exact local OID Git is pushing. It blocks a supplied body when the pushed commit is not
HEAD. Deletion records skip body lint. No Swift, Xcode or browser design suite runs.

For a direct lint run, use
`node "$(git config --get core.hooksPath)/../agents/local-pr-lint.mjs" --body-file /path/to/body.md --expect <pushed-SHA>`
(optionally `--base origin/main`). Without `--expect`, HEAD must match the upstream branch's
locally stored tip; fetch as appropriate, since this check does not contact the remote.
The runner extracts a temporary base snapshot so the validator and its imports come from
that ref, then checks the current worktree's HEAD and removes the snapshot.

Git's `--no-verify` bypasses the hook; CI remains the authority. This opt-in hook adds no
new options or permission to `push-guard.py`, and does not replace role/destination checks.
