# Test Matrix — WI-1: Mado living docs, amendment 1

Plan: .claude/tdd-guardian/plan-i553-b.md. Use Node node:test and real filesystem/Git. No mocks. The finite baseline document/row sets are exhaustively compared; generated property-library inputs add no value to those complete domains. File replay is integration level; string policy predicates may be unit level.

## Unit: Living-document identity contract

**Law**: Every non-exempt current identity token in the complete tracked living-document domain names Mado; explicit historical/tooling references retain their meaning.

### Case: Living docs have current identities
- **Category**: property
- **Lane**: integration (manual docs-node receipt lane)
- **Spec level**: S4 — enumerate the entire tracked living-document set, not selected examples.
- **Input**: README, AGENTS, CLAUDE, GLOSSARY, TestAssets README, .agents/skills content, .claude/rules and agent docs, docs living prose and design docs; exclude ADR/validation from rewriting except notes, research evidence and frozen release history. Detect Packages/PicseeKit, Picsee modules/test targets, -scheme Picsee, Picsee.app/xcodeproj, io.github.anzchy.picsee, -Picsee flags and PicseeGitSHA.
- **Expected output**: Zero stale-identity findings, with explicit reasons for contextual tooling/repo/history/filename/legacy-feed exceptions. Do not exempt an entire line because another token on that line is tooling.
- **Observable side effect**: None; diagnostics name file and stale token.
- **Assertion strategy**: Level 1 — assert the real repository finding list is empty and not the document count.
- **Mock boundary**: none — real implementation and tracked files.
- **Refactor that would break this**: Changing public copied command identity or broadening exceptions until a wrong app identity escapes.

### Case: Narrow exceptions cannot hide a stale native command
- **Category**: failure
- **Lane**: unit
- **Spec level**: S3 — known over-broad-exemption failure mode.
- **Input**: Text containing legitimate ~/.picsee or PICSEE_* beside Packages/PicseeKit or -scheme Picsee; separate former-name Picsee prose and GitHub anzchy/picsee links.
- **Expected output**: Stale native command is reported while legitimate tooling/repo/former-name spans remain permitted.
- **Observable side effect**: None.
- **Assertion strategy**: Level 1 — compare actual findings with forbidden tokens and allowed-span absence.
- **Mock boundary**: none — real policy predicate.
- **Refactor that would break this**: Changing the externally promised exception boundary.

## Unit: Frozen historical records

**Law**: Removing exactly the one approved added note recovers each baseline record byte for byte.

### Case: All frozen records have only the former-name note
- **Category**: property
- **Lane**: integration (manual docs-node receipt lane)
- **Spec level**: S5 — preservation across the rename transition.
- **Input**: Complete ADR and validation record path set from bf5052b2 and working tree, note 注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
- **Expected output**: Same record set; exactly one note added to every record; stripping the one note plus deliberate adjoining newline recovers baseline bytes. Any changed/deleted original line or duplicate note fails.
- **Observable side effect**: None.
- **Assertion strategy**: Level 1 — strict equality per record after reversing only the allowed insertion; assert path-set equality and one-note cardinality.
- **Mock boundary**: none — real Git baseline and files.
- **Refactor that would break this**: Editing frozen prose, including ADR-0012/P2 flags, or changing note cardinality.

## Unit: Ledger acceptance contract

**Law**: Ledger IDs and acceptance are conserved, modulo only the four explicit app-name substitutions; limitations permit mechanical identity rename only.

### Case: Exhaustive baseline ledger comparison permits exactly the amendment
- **Category**: property
- **Lane**: integration (manual docs-node receipt lane)
- **Spec level**: S5 — full finite-domain preservation invariant.
- **Input**: Parsed row IDs and 怎么确认 cells from bf5052b2 and working tree. Allowed acceptance IDs exactly OPEN-03, CMD-05, WIN-02, EXT-03.
- **Expected output**: Identical row ID sets. Every non-allowed row's acceptance before the first 限制： is byte-identical. For the four allowed IDs, actual acceptance equals baseline with only picsee/Picsee→Mado and actually uses Mado. For every row's limitations, only mechanical identity substitutions are allowed; OPEN-08/CMD-01 rename is permitted. All other words, punctuation, steps and conditions remain unchanged.
- **Observable side effect**: None.
- **Assertion strategy**: Level 1 — strict equality per row/prefix and normalized limitation; do not normalize the entire cell for every row.
- **Mock boundary**: none — real Git baseline and Markdown parser.
- **Refactor that would break this**: Changing any observable acceptance condition, dropping a row or broadening the four-ID exception set.

## Unit: Mechanical documentation rewrite replay

**Law**: Rename preserves protected content and is idempotent: R(R(tree)) = R(tree).

### Case: Real replay performs rename once and preserves protected bytes
- **Category**: state
- **Lane**: integration (manual docs-node receipt lane)
- **Spec level**: S5 — real filesystem idempotence and preservation.
- **Input**: Temp tracked Git tree containing current command prose, design filenames/links, tooling and repo references, historical record with old flags, ledger acceptance and limitations; invoke CLI from a subdirectory.
- **Expected output**: Current identities become Mado; protected filenames/link destinations/tooling/repo/legacy-history keep original bytes; record receives exactly one note; second run leaves all file bytes unchanged; no extra files rewritten. Explicitly assert first-run renamed bytes so a no-op cannot pass idempotence alone.
- **Observable side effect**: Files rewritten in the temp repository only.
- **Assertion strategy**: Level 2 — read actual files after first/second runs, compare expected content, path set and byte snapshots.
- **Mock boundary**: none — real Git and filesystem.
- **Refactor that would break this**: Changing CLI replay semantics, root resolution or protected-content meaning.

## Coverage of the work item

| Acceptance criterion | Cases covering it |
|---|---|
| Current Mado docs/commands and narrow exceptions | Living docs have current identities; Narrow exceptions cannot hide a stale native command |
| Frozen records | All frozen records have only the former-name note |
| Ledger preservation and four substitutions | Exhaustive baseline ledger comparison permits exactly the amendment |
| Script correctness, scope and replay | Real replay performs rename once and preserves protected bytes |
| Glossary former-name definition | Assert Mado/former Picsee in actual GLOSSARY as part of living-doc contract |
| Generated HTML, design and native commands | Required brief gates with retained logs |
| Commit separation and handoff | Final review of commit file sets and handoff, after green workflow |

## Deferred

App behaviour, signed-device verification, release/repo/tooling rename are explicitly outside #553. No async retries or concurrency exist in this synchronous rewrite; sequential heavy-lock native gates verify copyable commands.

## Discovered regression cases (before corrective implementation)

- WI-2: Existing `designRegistryPinsSources` is Level 1 / S5, real filesystem, no mocks. Its RED rejects any modified guide bytes without matching JSON/Swift hash metadata and rejects a changed source byte. Only DESIGN.md pin may refresh; unrelated source mismatches must remain failures. Receipt i553-WI-2.
- WI-3: Real temporary Git repo includes `session` and GUI `project` protocol values and quoted owner text. Level 2 / S5 preservation; first run must rename heading only while keeping tooling/quote bytes. No mocks. Receipt i553-WI-3.
- Additional wrapper check: actual Codex description names Mado while its tooling name remains unchanged; Level 1, no mocks.
