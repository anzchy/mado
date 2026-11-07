# Releasing Mado

A release is a tag push. [`.github/workflows/release.yml`](../../.github/workflows/release.yml) builds, signs, notarises and packages Mado. It then opens a **draft** GitHub release and an **appcast pull request**. Nothing reaches users until the owner publishes the draft and merges the PR (spec #212, #222).

## Before the first release

- The secrets wizard has run: `.agents/skills/apple-developer-setup/scripts/setup-secrets-wizard.sh`. That puts these into GitHub Secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` and `SPARKLE_ED_PRIVATE_KEY`. It also sets the repository variable `DEVELOPMENT_TEAM`. The workflow reads nothing else. See the [apple-developer-setup skill](../../.agents/skills/apple-developer-setup/SKILL.md).
- `MARKETING_VERSION` in `project.yml` is the version you are releasing (0.0.1).
- The commit to release is on `main`, and CI is green on it.

## Cut a release candidate

```sh
git switch main && git pull
git tag -a v0.0.1-rc.1 -m "Mado 0.0.1 rc.1"
git push origin v0.0.1-rc.1
```

Only `v0.0.1-rc.N` and `v0.0.1` start the workflow. The run fails before building if:
- the tag isn't on `main`;
- the tag's version differs from `MARKETING_VERSION`;
- `DEVELOPMENT_TEAM` is unset.

The build number is the tag commit's commit count (`git rev-list --count`), so builds increase with `main`.

## Credentials on the runner

The six secrets reach only the steps that use them, through step environment variables. GitHub masks their values in logs. Four of them, the Apple ID and three passwords, still appear as **process arguments** while a command runs, because the tools take them no other way in a non-interactive job:
- The Apple ID and the app-specific password reach the process arguments of `xcrun notarytool submit` and `notarytool log`. That is the Apple ID + app-specific password contract chosen for #222. Without `--password`, notarytool prompts on a terminal, which a runner doesn't have. A keychain profile would need the same password on the command line to create it.
- The keychain password and the .p12 password reach the process arguments of `security create-keychain`, `unlock-keychain`, `import` and `set-key-partition-list`.

Another process on the same machine could read them from the process list while those commands run. The GitHub-hosted macOS runner is single-tenant and ephemeral: one job per fresh virtual machine, discarded afterwards. So the exposure is limited to this job's own processes, and the workflow runs only on tags pushed to this repository, never on pull requests.

Other measures:
- The Sparkle EdDSA key never appears in arguments: `sign_update` reads it on standard input.
- Temporary files (the decoded .p12, the keychain, the notarisation zip) are created with `umask 077`.
- The .p12 is deleted right after import.
- Each secret variable is unset right after its last use, so later commands in its step don't inherit it: `DEVELOPER_ID_P12_BASE64` after decoding, `DEVELOPER_ID_P12_PASSWORD` after import, `KEYCHAIN_PASSWORD` after `set-key-partition-list`, `APPLE_ID` and `APPLE_APP_SPECIFIC_PASSWORD` after `notarize.sh` (before stapling and `spctl`), and `SPARKLE_ED_PRIVATE_KEY` after `sign_update` (before git, node and gh).
- The last step deletes the keychain and fails the run if it can't.
- A runner that is killed outright skips that step; its virtual machine is discarded anyway.

## What the run does

1. **Release build:**
   - Signed with the team's Developer ID Application certificate, from a temporary keychain that is deleted at the end of every run.
   - Hardened runtime on.
   - `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, so there is no `get-task-allow`.
   - Stripped, so the binary carries no build-machine paths.
2. Sparkle 2.10.0's `LICENSE` is copied to `Contents/Resources/ThirdPartyNotices/Sparkle-2.10.0-LICENSE.txt`. It comes from the release tools tarball pinned by SHA-256 and includes Sparkle's external licences.
3. **Re-signing:** Sparkle's helpers are re-signed with Developer ID in the order Sparkle's sandboxing documentation gives: Installer.xpc, Downloader.xpc, Autoupdate, Updater.app, then the framework. The app is signed last, followed by `codesign --verify --deep --strict`.
4. **Checks on the signed app, before anything is sent to Apple:**
   - `node scripts/release/check-entitlements.mjs <app> --configuration release`: exactly ADR-015's five entitlements.
   - `node scripts/release/check-package.mjs <app> --require-sparkle-licence --expect-version … --expect-build …`. It fails on research, prototype or evidence files, credentials, private photos, scripts, documents or build paths. It also checks that the Sparkle Info.plist keys keep the second-launch question and send no system profile, that the version and build are right, and that the licence is present.
5. **App notarisation:** the app is notarised (`notarytool submit --wait`, Apple ID with an app-specific password), stapled and validated.
6. **DMG:**
   - The DMG holds the stapled app and an Applications link (`hdiutil`, APFS, lzfse).
   - It is signed, notarised, stapled and validated.
   - `spctl` assesses both the DMG and the app.
7. **Draft release** `v0.0.1-rc.N`:
   - Assets: `Mado-0.0.1.dmg` and `Mado-0.0.1.dmg.sha256`.
   - Notes from [`notes-template.md`](notes-template.md): checksum, privacy statement, a placeholder for what's new.
   - rc tags are marked pre-release.
8. **Appcast PR:**
   - The DMG is signed with Sparkle's EdDSA key, which reaches `sign_update` only on standard input.
   - `scripts/release/appcast.mjs` adds the item to `appcast.xml` on a new branch `appcast/<tag>`.
   - A PR to `main` is opened.

To check a local build before tagging (unsigned, so skip the licence and entitlement checks):

```sh
xcodebuild build -scheme Mado -configuration Release CODE_SIGNING_ALLOWED=NO \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES -derivedDataPath .build/dd-rel
node scripts/release/check-package.mjs .build/dd-rel/Build/Products/Release/Mado.app
```

## What the owner does

1. **Check the draft on the MacBook test user:**
   - Download the DMG from the draft release.
   - Check `shasum -a 256` against the notes.
   - Open the DMG, drag Mado into Applications and launch it. Gatekeeper must not warn.
   - Edit the notes' "What is in this version".
2. **Publish the draft.** The appcast's enclosure URL only works once the release is public.
3. **Decide on the appcast PR.** Merging an appcast PR offers that build to every installed copy that has update checks on, as soon as `appcast.xml` lands on `main` (the feed in `SUFeedURL`). There is one feed, and GitHub's pre-release flag does not filter it. For a release candidate, close the appcast PR unless you mean a general rollout. For a build meant for everyone, merge it after publishing.
4. **Promote to final:** when an rc is good, tag `v0.0.1` on the same or a later `main` commit and repeat.

The appcast PR is opened with the workflow's token, so GitHub does not run CI on it. It changes only `appcast.xml`.

## When a run fails

The run stops at the first failing step and always tries to delete its keychain. Nothing a run creates is ever published. What exists on GitHub afterwards depends on where it stopped:

| Stopped at | Draft release `<tag>` | Branch `appcast/<tag>` | Appcast PR |
|---|---|---|---|
| anything before "Create the draft release" (version check, build, signing, checks, notarisation, DMG, checksum) | no | no | no |
| "Create the draft release" | maybe: a draft with missing assets if an upload failed | no | no |
| "Sign the update and open the appcast PR", before the push | yes | no | no |
| the same step, after the push (e.g. PR creation refused) | yes | yes | no |
| finished | yes | yes | yes |

Apple keeps the notarisation submissions; they need no clean-up.

**Same tag, same commit** (a flaky step, an expired credential you have since replaced):

1. If a **draft** `<tag>` exists, delete it. Never do this to a published release:
   ```sh
   gh release view <tag> --json isDraft --jq .isDraft   # must print true
   gh release delete <tag> --yes                        # keeps the git tag
   ```
2. Leave `appcast/<tag>` and its PR as they are. The rerun rebuilds the branch from `main` with the new DMG's signature. It replaces only that branch, with `--force-with-lease` pinned to what it just read, and updates the open PR instead of opening a second one.
3. In Actions, open the failed run and choose **Re-run all jobs**. That reruns the same tag and commit.

**Same tag, new commit** (the fix had to land on `main` first):

1. Delete the draft as above.
2. Move the tag:
   ```sh
   git push --delete origin <tag> && git tag -d <tag>
   git tag -a <tag> -m "…" <fixed commit on main>
   git push origin <tag>
   ```
3. `appcast/<tag>` and its PR may stay; the new run replaces the branch and reuses the PR. To remove them instead: `gh pr close <number>`, then `git push --delete origin appcast/<tag>`.

**Or skip the tag:** cut `rc.N+1`, then close the old appcast PR and delete its branch. This is the safest choice for a release candidate. For the one final `v0.0.1` tag, use the same-tag path.

Never edit or delete a **published** release's DMG: Sparkle verifies the EdDSA signature in the appcast against it. A bad published build is replaced by a newer one.
