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
