---
name: ci-linux-preflight
description: Run the supplementary Agent tooling Linux preflight before pushing portable tooling changes, or reproduce a Linux-only CI failure. GitHub CI remains the binding result.
---

# Linux CI preflight

Use this before pushing changes to Node, Python or shell code under `scripts/`, hooks, or platform-sensitive code using `/proc`, procps `ps`, git versions, zsh/bash or paths. Use it also to reproduce a Linux-only CI failure. The result is supplementary PR evidence; GitHub CI is the only binding result.

| CI job | GitHub runner | Linux server preflight |
|---|---|---|
| Agent tooling | `ubuntu-latest` | yes; prior measured test time 274 s, peak RSS about 84 MB with git ≥ 2.36 |
| Design check | `ubuntu-latest` | later, after a measured run |
| Native inputs, Package coverage, Walking skeleton | `ubuntu-latest` | no; classifiers or aggregators over macOS outputs |
| Package tests ×2, Ledger HTML check, App tests, App host comparison | `macos-26` | no; owner gates on the Mac cover these locally |

## Run

1. Commit the branch and pass local tests. The command requires the commit to equal `HEAD`.
2. Run `.agents/skills/ci-linux-preflight/scripts/preflight.sh <head-sha>`. Set `PICSEE_LINUX_HOST` only if the SSH alias differs from `tencent-ci`.
3. The script bundles the commit and transfers it with `rsync`; the host clones the bundle. It checks Node 22, git ≥ 2.36, Python 3 and zsh, then runs the `working-directory: pr-head` `run:` steps from the `agent-tests` job in `.github/workflows/pr-body.yml`. It never runs setup or installation steps on the host. It records each step, elapsed seconds, `/usr/bin/time -v` peak RSS when available, and Node TAP totals in `~/.picsee/ci-linux/<sha>-summary.txt`. It removes the remote `~/ci/<sha7>` work directory after writing the local summary.
4. Check a stored summary with `node .agents/skills/ci-linux-preflight/scripts/preflight.mjs summary-check <summary-file>`. A missing `DONE` is invalid.
5. Place the printed line outside the PR Gates table, for example `Linux-Preflight: abc1234 agent-tooling PASS 42/42 (0 skip)`. Include the summary or its path in the handoff. A FAIL or unavailable host stays visible as such.

## Never

- Treat the server pass as binding, skip a required GitHub check, or use `--admin` because it passed.
- Change CI configuration or add a self-hosted runner for this preflight.
- Put an IP address, key path, or personal host path in the repository.
- Use `StrictHostKeyChecking=no`.
- Clone from GitHub on the host; use the commit bundle.
