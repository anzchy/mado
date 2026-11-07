# Rename to Mado with a new identity, accepting a fresh start for Picsee installs

The owner renamed the app from Picsee to Mado (2026-11-07: 「下一件事是改名，我要将app改名为`Mado`,列一个github issue」) and chose a full rename: the user-visible name, bundle ID (`io.github.anzchy.picsee` → `…mado`), Xcode project, Swift package and modules, and the GitHub repo. A new bundle ID gives Mado a new sandbox container and a new identity for macOS and Sparkle. A sandboxed Mado cannot read Picsee's container, and the sandbox rule rules out entitlement workarounds, so nothing carries over. Mado installs as a new app and Picsee v0.0.1 users start with empty settings, recent folders and folder grants. The release notes say so. Picsee's update feed is frozen with its existing entries, so installed Picsee sees no update. Mado starts again at 0.0.1, tagged `mado-v0.0.1` because `v0.0.1` stays Picsee's release (#543).

## Considered Options

- **Keep the bundle ID and change only the name**: rejected by the owner, who wanted a clean identity. It would have kept the container and Sparkle updates for Picsee users.
- **A last Picsee update pointing to Mado, or a settings export/import**: rejected. Data would still not carry over (folder grants cannot move between apps), and both cost extra work in two apps for a small installed base.

## Consequences

- The Sparkle mach-lookup exceptions follow the bundle ID (`<bundle id>-spks`/`-spki`, ADR-015), and Mado's feed URL points at the renamed repo.
- After the repo rename, the old raw appcast URL must be checked on the real URL: it must keep serving Picsee's frozen appcast or fail harmlessly.
- ADRs and validation records keep the name Picsee as written; living docs say Mado.

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
