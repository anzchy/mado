---
name: apple-developer-setup
description: Set up and maintain Mado's Apple Developer distribution: program agreements, the Developer ID Application certificate, the notarisation Apple ID and app-specific password, the Sparkle update-signing key, and the GitHub Secrets the release workflow reads. Use when setting up release signing for the first time, renewing or replacing the certificate, rotating the notarisation password or Sparkle key, checking that signing and notarisation credentials are in place, or diagnosing Xcode or notarytool errors such as "PLA Update available", a missing Developer ID identity, or App Store Connect compliance screening. Not for building or publishing a release (the release workflow, #222) or for App sandbox and entitlement decisions (ADRs).
---

# Apple Developer setup for Mado

Mado ships outside the Mac App Store as a notarised DMG on GitHub Releases. It updates through Sparkle 2 (ADR-015, spec #212). The release workflow, run on a GitHub Actions macOS runner, needs a few credentials, and only the human who owns the Apple Developer team can create them. This skill covers getting those credentials, storing them, checking them and renewing them. The wizard [scripts/setup-secrets-wizard.sh](scripts/setup-secrets-wizard.sh) performs the storage part.

Decisions this follows, from the user on 2026-10-28:
- 「公证 DMG，GitHub Releases」
- 「GitHub Actions 自动发布」
- 「推 tag → 生成草稿 Release，你点发布」
- 「Sparkle 自动更新」
- 「B，改成 app 专用密码」: notarise with an app-specific password, not an App Store Connect API key.

## What only the human can do

Each of these needs the owner's Apple ID with two-factor authentication. The agent explains them and waits; it never asks for passwords or keys in chat.
1. Accept the latest agreements on developer.apple.com: the Program License Agreement, and on App Store Connect any agreement under Business. While one is pending, Xcode reports "PLA Update available" and certificate creation fails.
2. Create the Developer ID Application certificate. Only the team's Account Holder can, or an Admin the Account Holder has granted access to cloud-managed Developer ID certificates.
3. Create the app-specific password on account.apple.com.
4. Run the wizard in their own terminal. It is interactive, so `!` inside an agent session won't work.

## The workflow

1. **Agreements.** Sign in at https://developer.apple.com/account and accept any updated agreement shown in the banner. Then check App Store Connect → Business.
2. **Certificate.** In Xcode → Settings → Accounts → (team GRT84NAK4T) → Manage Certificates… → + → Developer ID Application. Check it:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application:.*(GRT84NAK4T)"
   security find-certificate -c "Developer ID Application: Yong Cheng" -p | openssl x509 -noout -subject -enddate
   ```
   If Xcode reuses an older certificate, it may expire soon. Note the `notAfter` date; see Renewal below.
3. **Wizard.** From the repository root, run:
   ```sh
   .agents/skills/apple-developer-setup/scripts/setup-secrets-wizard.sh
   ```
   It has six stages:
   1. checks that the gh login can write secrets;
   2. waits for the certificate;
   3. has you export it as a .p12 from Keychain Access;
   4. takes the Apple ID and app-specific password and checks them with `xcrun notarytool history`;
   5. generates the Sparkle EdDSA key with the latest Sparkle `generate_keys`;
   6. sets the team variable and securely deletes its temporary files.

   Stages 3–5 offer to keep secrets that already exist, so a re-run after an interruption only redoes what is missing.
4. **Check the result**, without reading any secret:
   ```sh
   gh secret list -R anzchy/picsee
   gh variable list -R anzchy/picsee
   cat ~/.picsee/release/sparkle-public-ed-key.txt   # public key, 44 base64 characters
   ```
   Expected secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`. Expected variable: `DEVELOPMENT_TEAM=GRT84NAK4T`. No `ASC_*` secrets.
5. **End-to-end proof** comes from CI, not from this machine. The first `v0.0.1-rc.N` tag run of the release workflow (#222) imports the .p12, signs, notarises and staples. Until then, record "credentials stored, end-to-end NOT VERIFIED". Don't sign a test file locally just to check: macOS asks the user to allow `codesign` to use the private key.

## The contract with the release workflow

The workflow (#222) reads exactly the secret and variable names above.
- It imports `DEVELOPER_ID_P12_BASE64` and its password into a temporary keychain protected by `KEYCHAIN_PASSWORD`.
- It signs with hardened runtime and no get-task-allow, then checks the signed app with `node scripts/release/check-entitlements.mjs <Mado.app> --configuration release`. This fails on any entitlement beyond ADR-015's five or a wrong `-spks`/`-spki` name.
- It notarises with `xcrun notarytool submit --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$DEVELOPMENT_TEAM" --wait`, then staples and validates with spctl.
- It signs the appcast with `SPARKLE_ED_PRIVATE_KEY`.
- The app's Info.plist carries the public key as `SUPublicEDKey` (#220).

Renaming a secret means changing the wizard, this skill and the workflow in one PR.

## Renewal and rotation

- **Certificate:** a Developer ID Application certificate lasts up to five years. The current one expires 2027-02-01. Before then, create a new one (step 2), re-run the wizard and answer **n** at stage 3 to replace the stored .p12. Apps already notarised keep opening after expiry; new builds can't be signed with the old certificate.
- **App-specific password:** revoke it on account.apple.com if it leaks, then generate a new one and re-run stage 4 by answering **n** to "keep".
- **Sparkle key:** never rotate it casually. Installed copies only trust the public key they shipped with. A new key needs a release signed with the old key that carries the new public key first.

## Rules

- Secrets go only into GitHub Secrets. Never into the repository, a `.env`, chat, a report, a PR body or an issue.
- Don't change system or privacy settings and don't pre-grant anything. A dialog belongs to the user.
- A team-level problem (agreements, roles, compliance screening) is the user's call. Explain it and give options.

Troubleshooting for the errors seen so far: [references/troubleshooting.md](references/troubleshooting.md).
