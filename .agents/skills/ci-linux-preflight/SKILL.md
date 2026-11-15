---
name: ci-linux-preflight
description: Run the supplementary Agent tooling Linux preflight before pushing portable tooling changes, or reproduce a Linux-only CI failure. GitHub CI remains the binding result.
---

# Linux CI preflight

Use this before pushing changes matching `scripts/**/*.{mjs,cjs,js,py,sh,zsh}`, `.github/workflows/pr-body.yml`, hooks, this skill, `package*.json`, or test fixtures under `scripts/**/tests/`. Use it when a GitHub Linux job fails but macOS passes, and rerun after a rebase touching those paths. The result is supplementary PR evidence; GitHub CI is the only binding result.

| CI job | GitHub runner | Linux server preflight |
|---|---|---|
| Agent tooling | `ubuntu-latest` | yes; prior measured compatibility run: 274 s test time and peak RSS about 84 MB with git ≥ 2.36 |
| Design check | `ubuntu-latest` | later, after a measured run |
| PR body Gates, Native inputs, Package coverage, Walking skeleton | `ubuntu-latest` | no; Gates uses trusted-base validation; the rest classify or aggregate macOS outputs |
| Package tests ×2, Ledger HTML check, App tests, App host comparison | `macos-26` | no; owner gates on the Mac cover these locally |

## Run

1. Run local tests and commit the branch. Pass that exact PR head SHA to `.agents/skills/ci-linux-preflight/scripts/preflight.sh <sha> [--step-timeout seconds] [--deadline seconds]`. The script refuses tracked dirt unless `--allow-dirty` is given directly to `preflight.mjs run`. It tests the PR head, as the Agent tooling job does, rather than a merge result. Run only a commit you wrote or reviewed.
2. The default SSH alias is `picsee-ci-linux`; `PICSEE_LINUX_HOST` may override it. The host is an unprivileged account with no sudo. The script makes a temporary ref and full-history bundle, transfers it with `rsync`, checks out the SHA detached, and verifies `HEAD`. On the host it maps checkout and setup-node to bundle and environment checks. It maps the workflow's package installation step to `provision-checked` and never executes its `sudo apt-get` command. It runs only `working-directory: pr-head` steps in workflow order under `bash -e {0}` with `env -i`.
3. Each attempt produces an immutable private summary under `~/.picsee/ci-linux/<sha>/<UTC timestamp>-summary.txt`, plus a private raw log and a `latest` symlink. The summary includes the ordered step inventory, per-step exit, duration, peak RSS (or `unknown`), Node TAP and Python unittest totals, and host versions. The remote run uses a lock, a unique `~/ci/run.*` directory, a cleanup trap, per-step timeout (default 600 seconds), and a whole-run deadline (default 1200 seconds).
4. Check a stored summary with `node .agents/skills/ci-linux-preflight/scripts/preflight.mjs summary-check <summary-file> --expect-head <full-sha>`. A missing or duplicate `DONE`, missing totals, stale head, or changed workflow is invalid. The checker prints the PR line only for the expected head.
5. Put that line outside the PR Gates table: `Linux-Preflight (supplementary; GitHub required checks remain binding): <sha7> agent-tooling PASS|FAIL|TIMEOUT|NOT VERIFIED <details>`. Refresh or drop it on every re-push. A Linux pass never explains away red GitHub CI.

The host is Ubuntu 22.04; GitHub `ubuntu-latest` is Ubuntu 24.04. The server's 274-second test run is diagnostic and does not claim CI timing parity; GitHub's Agent tooling job timeout is five minutes. An unreachable host produces `NOT VERIFIED` and never blocks a merge.

## Never

- Treat the server pass as binding, skip a required GitHub check, or use `--admin` because it passed.
- Change CI configuration or add a self-hosted runner for this preflight.
- Put an IP address, key path, or personal host path in the repository.
- Use `StrictHostKeyChecking=no`.
- Clone from GitHub on the host; use the commit bundle.
- Run a fork PR head or any commit you have not written or reviewed.
- Store tokens or credentials on the host, or bind test listeners outside loopback.
