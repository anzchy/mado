# Merge queue evaluation for Mado (#771)

**Status:** evaluation only, 2026-11-20. No queue, workflow, protection, or repository setting was changed. **Recommendation:** prepare a rebase-method queue, but keep it disabled until the workflow changes and the temporary-repository validation below have passed and the owner explicitly confirms enablement.

## 1. Availability and present protection

The owner inspected **anzchy/mado → Settings → Rules** on 2026-11-18 and saw **Require merge queue** for this personal-account repository ([Step 0 comment](https://github.com/anzchy/mado/issues/771#issuecomment-6998974852)). This establishes UI availability for this repository; it is not a test of a functioning queue. The owner requested validation **only in a temporary repository, later**, and another confirmation before enabling anything in Mado (task brief). Read-only `gh api repos/anzchy/mado/branches/main/protection` on 2026-11-20 showed `strict: true` and five required GitHub Actions contexts: **Walking skeleton, PR body Gates, Agent tooling, App tests, Design check**. There was no ruleset in the issue's Step 0 inventory. The existing protection must remain effective during any future change.

GitHub's [queue guide](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue) says Actions workflows producing required checks must run on `merge_group`. The [Actions event reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#merge_group) says `GITHUB_SHA` and `GITHUB_REF` are the merge group's SHA and ref. Neither source proves Mado's exact settings combination or commit-message behavior; those need the temporary test.

## 2. Required-check behavior on a merge group

| Required context | Current source | Proposed queue behavior |
|---|---|---|
| Walking skeleton | `ci.yml` | Run on the merge-group SHA. Treat every group as native input, so both Package shards, coverage, full App build/tests, ledger and the Walking skeleton verdict run. Read the verdict script from protected `main`, never from the group tree. A docs-only group therefore pays for native jobs. |
| App tests | `ci.yml` | Run the full hosted App lane on the group SHA. Add `merge_group` to `scripts/ci/app-evidence.mjs`'s formal-event allowlist; otherwise the App job may succeed but Walking skeleton rejects its evidence as diagnostic. Extend the inline App minimum to `merge_group`. |
| Design check | `ci.yml` | Existing `if: github.event_name != 'workflow_dispatch'` runs it on the group SHA once `merge_group` triggers the workflow. |
| Agent tooling | `pr-body.yml` | Check out and test `github.sha` for a merge group; retain the PR head checkout on `pull_request`. Its Linux preflight parser currently accepts only the literal PR-head expression and must be taught this one exact additional expression, with tests, before this workflow change. |
| PR body Gates | `pr-body.yml` | Keep the same job/check name on both events. On `pull_request`, run today's trusted-base body lint. On `merge_group`, validate the queue event identity and report success **based on GitHub's prior required PR-head check**, rather than pretending the group payload contains one PR body/head. This is a policy choice: the queue step does not lint a body. The owner must accept that boundary, and the temporary test must prove that a failed or edited PR body cannot enter or remain in the queue without a fresh required PR check. If it cannot, build a fail-closed member-PR lookup before enabling. |

The current `pr-body.yml` group key uses `github.event.pull_request.number`; that field is absent for `merge_group`. Give each group run its own concurrency key so one queue group cannot cancel another. The `ci.yml` key already uses `github.run_id` for events other than `pull_request`.

### Proposed patch shape — **not applied**

These are the exact event and conditional changes to make in a later implementation PR. Surrounding test and parser updates are identified after the snippet. The queue-context step checks event fields, not PR-body content.

```diff
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
@@
 on:
   pull_request:
+  merge_group:
+    types: [checks_requested]
+    branches: [main]
   push:
@@
   changes:
     outputs:
-      native: ${{ steps.classify.outputs.native }}
+      native: ${{ steps.classify.outputs.native || steps.merge-native.outputs.native }}
@@
       - name: Checkout trusted base
+        if: github.event_name != 'merge_group'
@@
       - name: Classify changed files
         id: classify
+        if: github.event_name != 'merge_group'
@@
+      - name: Run native checks for merge group
+        id: merge-native
+        if: github.event_name == 'merge_group'
+        run: echo 'native=true' >> "$GITHUB_OUTPUT"
@@
   walking-skeleton:
@@
       - name: Checkout trusted base
@@
-          ref: ${{ github.event.pull_request.base.sha || github.sha }}
+          ref: ${{ github.event_name == 'merge_group' && 'main' || github.event.pull_request.base.sha || github.sha }}
@@
-          if [ "$NATIVE" = true ] && { [ "$EVENT_NAME" = pull_request ] || [ "$EVENT_NAME" = push ]; }; then
+          if [ "$NATIVE" = true ] && { [ "$EVENT_NAME" = pull_request ] || [ "$EVENT_NAME" = push ] || [ "$EVENT_NAME" = merge_group ]; }; then
diff --git a/.github/workflows/pr-body.yml b/.github/workflows/pr-body.yml
@@
 on:
   pull_request:
     types: [opened, edited, synchronize, reopened]
+  merge_group:
+    types: [checks_requested]
+    branches: [main]
@@
 concurrency:
-  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
-  cancel-in-progress: true
+  group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.event.pull_request.number || github.run_id }}
+  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
@@
   agent-tests:
@@
       - name: Checkout PR head
@@
-          ref: ${{ github.event.pull_request.head.sha }}
+          ref: ${{ github.event_name == 'merge_group' && github.sha || github.event.pull_request.head.sha }}
@@
   pr-body-gates:
     name: PR body Gates
-    if: github.event_name == 'pull_request'
@@
       - name: Checkout trusted base
+        if: github.event_name == 'pull_request'
@@
       - name: Checkout PR head
+        if: github.event_name == 'pull_request'
@@
       - name: Check PR body gates
+        if: github.event_name == 'pull_request'
@@
+      - name: Confirm merge-group context
+        if: github.event_name == 'merge_group'
+        env:
+          EXPECTED_SHA: ${{ github.sha }}
+        run: |
+          python3 - <<'PY'
+          import json, os
+          with open(os.environ['GITHUB_EVENT_PATH']) as source:
+              event = json.load(source)
+          group = event.get('merge_group') or {}
+          assert event.get('action') == 'checks_requested'
+          assert group.get('head_sha') == os.environ['EXPECTED_SHA']
+          assert group.get('base_ref') == 'refs/heads/main'
+          PY
diff --git a/scripts/ci/app-evidence.mjs b/scripts/ci/app-evidence.mjs
@@
-  const eventProvenance = ['push', 'pull_request'].includes(env.EVENT_NAME) ||
+  const eventProvenance = ['push', 'pull_request', 'merge_group'].includes(env.EVENT_NAME) ||
```

On `merge_group`, checking out protected `main` for Walking skeleton is a trust choice: `merge_group.base_sha` is described as the group's parent, which can include queued changes, so it is not automatically a trusted policy source. Using current protected `main` may be newer than the group's base; the temporary test must exercise a concurrent main advance. The native classifier's non-PR default would also choose `native=true`, but its current checkout would execute a classifier from the group tree; the explicit group branch above removes that trust ambiguity.

The implementation PR must update `.agents/skills/ci-linux-preflight/scripts/workflow.mjs`'s exact checkout mapping and `scripts/agents/ci-linux-preflight.test.mjs`, `scripts/agents/gates-rows.test.mjs`'s PR-only workflow assertions, `scripts/ci/ci-workflow.test.mjs`'s Walking skeleton trusted-ref, native-output and Changes checkout assertions (including a `merge_group` App-minimum verdict case), and App evidence tests. Keep `PR body Gates`' PR lint sourced from the trusted base. The current queue-context step is deliberately small; a body edited while queued is the decisive temporary-repository counterexample. Do not enable the queue if it permits a stale body check to be treated as current.

## 3. Merge method and commit evidence

The [GitHub queue guide](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue) explicitly offers **merge, rebase, and squash** as queue merge methods. The [merge reference](https://docs.github.com/en/pull-requests/reference/pull-request-merges) says merge commits retain the PR's commits, squash combines them into one configurable message, and rebase retains individual commits in a linear history. Its rebase summary says GitHub rewrites committer information and always creates new commit SHAs. Thus **rebase** is the closest fit to Mado's current rebase-merge history; merge commits would change topology, and squash would discard individual implementation commits.

Mado's `rebase-ledger.sh` sets `core.commentChar=';'` during **local** `git rebase` so commit-body lines beginning `#` (for issue/work-package IDs) survive. GitHub's queue docs do **not** say its rebase path uses that setting, nor do they promise byte-identical message bodies or `Implemented-by:` trailers. The individual-commit guarantee is documented; exact `#` lines, trailers and message order in a **queued rebase** remain **unverified**. Validate with `git log --format=%B` in the temporary repo before choosing rebase in Mado. A merge commit would preserve original commit objects and their messages but break the linear-history preference; squash message defaults are editable and do not guarantee individual trailers.

## 4. Measured CI cost and estimate

`gh run list` and `gh run view --json jobs` were read on 2026-11-20. Durations below are `completedAt - startedAt` for successful jobs, summed across macOS runners; they are **runner minutes**, not wall time. The Package jobs and App job run concurrently, so summing them is appropriate for consumption, while the whole run's elapsed time is shorter. These are observed runs, not an assumed price or a forecast of queue scheduling.

| CI run (head, event) | Package non-UI | Package MacUI | App tests | Ledger/macOS | macOS runner-min total |
|---|---:|---:|---:|---:|---:|
| [44704525848](https://github.com/anzchy/mado/actions/runs/44704525848), `923cfb9`, PR | 3:30 | 6:48 | 10:05 | 1:01 | **21:24** |
| [44691160830](https://github.com/anzchy/mado/actions/runs/44691160830), `ae98e8d`, PR | 2:36 | 5:02 | 13:36 | 0:49 | **22:03** |
| [44712965890](https://github.com/anzchy/mado/actions/runs/44712965890), `ee8128e`, PR | 6:40 | 8:05 | 11:38 | 0:51 | **27:14** |
| [44698741883](https://github.com/anzchy/mado/actions/runs/44698741883), `53777cb`, main push | 10:20 | 10:55 | 13:41 | 0:33 | **35:29** |

Separate `PR body` workflow samples show Agent tooling at 3:04–3:13 on Ubuntu and PR body Gates at 0:09–0:14 ([runs 44704525807](https://github.com/anzchy/mado/actions/runs/44704525807), [44691161033](https://github.com/anzchy/mado/actions/runs/44691161033), [44712965942](https://github.com/anzchy/mado/actions/runs/44712965942)); Design check took 1:32–1:51 in the corresponding CI runs. These are additional runner use, not part of the macOS totals.

**Estimate for one native PR:** today's first PR run costs roughly 21–27 macOS runner-min. Each strict-protection invalidation followed by a full rerun adds another roughly 21–27. A successful queue normally adds one full group run of roughly 21–27, with the post-merge main push still costing roughly 35 in the measured sample. Using the observed median 22:03: zero invalidations means about 57.5 macOS runner-min now versus 79.6 with a queue; one invalidation makes them about equal; four invalidations (as #764's history illustrates, though its exact CI bill was not reconstructed here) means about 145.7 now versus 79.6 with one successful group build. These are **scenario estimates**, not measured queue runs. The comparison assumes the queue removes strict-protection invalidation reruns. **UNVERIFIED:** with classic `strict: true` still on, a PR behind `main` may need its branch updated and its PR-head checks rerun before it can enter the queue. If so, those reruns remain costs in addition to the group build, and this comparison's queue savings do not hold. The temporary-repository test must decide this before using the estimates for rollout. A failed PR, changed queue order, or group rebuild adds builds; GitHub explicitly documents rebuilding followers after failure and after a jump. Conservative `native=true` also makes a docs-only queue group pay the full native cost even when its PR run skipped those jobs. Build concurrency caps simultaneous groups; merge limits do not combine their builds ([queue guide](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)).

## 5. Local evidence, audit, and red main

- **mado-verify:** the existing record and issue comment cover an audited **PR head**. The new #772 linked-record reuse is narrow: only a `CODE same` rebase, matching tested-input/toolchain/policy fingerprints, and a green old record can reuse `swift` and `lcov`; every other lane and the new-head comment/record rerun. A synthetic merge-group SHA includes earlier queued PRs, so it is **not** automatically a #772-reusable rebase head. Keep the PR-head record and audit; require the five GitHub required contexts on the group SHA as separate combined-tree evidence. Never relabel an old local PASS with the group SHA.
- **Audits and Device-Smoke:** existing audit and signed smoke claims remain bound to their reviewed patch/head; the `Device-Smoke:` line and `## Gates` SHA/source rules stay on the PR body. The group may combine another PR's behavior. Overlap or changed reachable UI requires a combination review and, when relevant, renewed smoke before enqueue; queue CI alone cannot prove the signed device flow. The owner must decide a precise overlap/withdrawal rule before rollout.
- **`merge-gate.sh` (#766):** currently shadow-only. It checks green main, PR-head checks, oldest-ready order, mado-verify, rebase identity and PR-body lint, then says `would-allow`/`would-refuse`; it neither enqueues nor merges. Use it before enqueue as diagnostic evidence, not as a replacement for group checks. Its audited-head comparison and older-ready logic need review for queue semantics before enforcement.
- **Red main:** `main-ci-status.sh` and the delegator's red-main stop rule still block enqueueing when latest main CI is red or pending. A queue on red main can fail every group; do not use repeated queue rebuilds to diagnose it. Main-push CI after merge remains binding for the new main head.

## 6. Recommendation, owner decisions, rollback, and validation

Prepare the workflow/test changes in a separate PR. **Do not enable in Mado yet.** If the temporary test confirms the assumptions, prefer **rebase** merge method, **Only merge non-failing pull requests**, initial build concurrency **1**, maximum merge limit **1**, no jump-ahead, and no protection bypass. Revisit concurrency after observed queue build times and runner availability. This prioritizes a small first rollout; it is not a measured optimal setting.

The owner must decide: (1) whether the group `PR body Gates` may rely on GitHub's prior required PR-head check or must independently resolve/revalidate every queued PR; (2) whether the docs-only native-build cost is acceptable or a trusted group classifier is required; (3) how audit and Device-Smoke evidence is withdrawn when queued changes interact; (4) rebase method after message/trailer validation; (5) how the current strict classic protection and any new ruleset overlap; and (6) the final enablement itself. The owner has already ruled out testing this in `anzchy/mado`.

**Temporary-repository plan (later, outside this ticket):**

1. Owner creates a separate temporary repository, configures protected `main` with the same five required context names, strict/up-to-date policy, and a merge-queue rule. Record the exact rule location and settings. Use lightweight stand-ins for macOS jobs; do not copy Mado secrets or publish the Mado workflow.
2. Add minimal `pull_request`/`merge_group` workflows with the proposed job names and event guards. Confirm every required context reports at both the PR head and group SHA, and that PR body Gates is neither missing nor falsely skipped. Capture the event payload's head/base refs and SHAs.
3. Open two PRs. Give one a commit body beginning `#771` and an `Implemented-by:` trailer. Select queue rebase, merge, and inspect individual commits with `git log --format=%B` and their new SHAs; check linear ancestry.
4. Make one PR's body invalid, first before enqueue and then after a successful check while queued. Confirm whether GitHub blocks or removes it until the PR-head Gates check is current. If not, replace the proposed group-context step with a fail-closed member-body validation design.
5. With classic `strict: true` still enabled, advance `main` so a checked PR head is behind it, then attempt to enqueue that PR. Record whether GitHub requires a branch update and fresh PR-head checks before enqueue, and whether the queue proceeds without them.
6. Fail the first PR's group check and observe removal/rebuilding of the second. Advance `main` while a group is queued and confirm that trusted-policy checkout and group rerun remain safe. Check that maximum merge limit and build concurrency behave as expected.
7. Disable **Require merge queue** in the enforcing rule, leave the five required contexts and strict protection enabled, and verify the ordinary PR path still works. Remove the temporary repository only when the owner authorizes cleanup.

This validates GitHub event wiring, queue settings and message preservation in a controlled repository. It cannot establish Mado's macOS cost, signed Device-Smoke/audit carry-over, or identical behavior under Mado's exact protection and workflow code. Before any later enablement, merge the tested workflow changes into Mado, confirm the five required group contexts can report, pause new enqueues, obtain the owner's explicit confirmation, and retain a rollback operator. If rollout fails, stop enqueueing, remove pending entries, turn off the queue requirement in its rule, verify strict protection and required contexts remain, and revert queue-only workflow paths only after outstanding groups have drained. Overlapping classic protection and a ruleset can impose both requirements; do not remove one by assumption.
