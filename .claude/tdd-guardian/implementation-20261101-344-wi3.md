# I344-WI-3 — DONE

Final evidence: package 1450 tests passed; selected compiled native menu test passed using two real controllers through the existing resolver, with unchanged source hash; Swift receipt SEPARATION-HELD; ledger HTML synchronized. Actual OS focus and signed-device behavior are not claimed. No commit or push occurred.

## Final implementation and evidence
Spec adversary SURVIVED the existing-resolver amendment; root persisted matrix/attack-r3 before implementation. Native fixture now uses two real CanvasWindowControllers and CommandMenu's existing injected windowController resolver to select context. It retains actual installed NSApp.mainMenu item dispatch, validation, title, enabled/check states, shared store/session outcomes, and disabled global check. Only unreliable OS focus prerequisites were removed before valid native RED. Production default resolver still reads NSApp.keyWindow, so compiled evidence is explicitly two-controller menu behavior, not OS focus/device evidence.

Valid supplemental native RED: `.build/i344/native-red-resolver.log`, one test failed with22 assertion issues in0.403s. RAM monitor confirms `END i344-native-red-resolver rc=1`. SHA256 `b8a2d8363e3da653d1689b40be2a16552713eacfd7369522039f1e3756ac9f49`, stored in `.build/i344/native-red-resolver-test.sha256`. Earlier timed-out focus fixtures are not counted as valid RED.

After both valid REDs, implemented owned production paths:

- FolderMenuPolicy: exact title `Loop Through Images`; loop enabled for folder or active preview/Finder context; checked state equals global value even disabled; unrelated folder-only actions unchanged. A final small cleanup folds loop availability into existing active/check switch to avoid duplicate unreachable loop handling.
- CommandMenu: loop toggles shared store before folder/preview early guards; validation reads store directly. Folder invoke/validation use existing controller resolver, preserving production's key-window default. Menu item position/identifier/selector/empty key equivalent retained. Other folder actions no longer rewrite the loop preference.
- Catalog: exact en `Loop Through Images`, zh-Hans `循环浏览`; removed old production key/translations. Existing bilingual catalog test expectation renamed with documented contract rationale.
- VIEW-10: only limitation appended, keeps acceptance/status and exact P3-01 clause. Generated HTML rebuilt and synchronization checked.

Final full configured unit lane PASS,1450 tests/36 suites; Swift51.484s, runLane55.937s. LCOV lines/statements14913/14913 and functions2890/2890 (100%); branches unmeasured. `.build/i344/wi3-final-unit.log`, `.build/i344/wi3-final-unit-result.json`, `coverage/lcov.info`. Full first green before tiny policy cleanup also passed; final report above supersedes it.

Native rebuild succeeded `.build/i344/native-green-build.log`; selected native GREEN PASS1 test0.174s `.build/i344/native-green.log`, monitor `END i344-native-green rc=0`. Unchanged hash check `.build/i344/native-green-test-hash-check.log` says OK. This is supplementary raw selected native RED/GREEN, not an app-red CLI receipt (that lane does not support a selected filter).

Swift `I344-WI-3` verify, same `issue344LoopMenu` filter, returned SEPARATION-HELD `.build/i344/wi3-verify.log`. Existing-source MEDIUM note refers to previously implemented WI1/WI2 and root-authorized Canvas removals present before menu RED; no WI3 production implementation was present at valid record. New package assertions unchanged from valid RED through GREEN.

All heavy work used foreground with-ram + heavy-lock, sequentially. `npm run ledger:build` and `npm run ledger:html-check` passed. Active catalog/ledger contain no old title. No further Canvas/Chrome changes, no commit/push/rebase. No heavy jobs remain active/queued. Root owns final coverage audit, review, gate refresh and handoff.

## Historical diagnostics — superseded intermediate states

The following records describe earlier failures and pauses only. Their references to tests-only preparation, absent production changes, or blocked status are historical; they do not describe the completed implementation above. Invalid attempts remain disclosed and are not counted as valid RED evidence.

Prepared new package `Issue344LoopMenuTests.swift` (three test functions) and native `AppTests/Issue344LoopMenuTests.swift` (installed real menu action/validation with two key windows, Grid/Preview/Finder contexts, disabled global checkmark). Migrated existing FolderMenuPolicyTests loop folder-only assumption and ViewerFolderReadingStateTests catalog key according to explicit #344 title/global ownership contract. No WI3 policy, menu, catalog or ledger production changes.

Swift receipt command used filter `issue344LoopMenu`, ID `I344-WI-3`, lane `swift-red`, fingerprint only new package test file, foreground through `with-ram.sh i344-wi3-red scripts/heavy-lock.sh node <receipt.js> record ...`.

Result: INVALID RED, `runner-error` classified environment. Log `.build/i344/wi3-red.log`; receipt records environment failure, not assertion evidence. Stopped at first gate failure as required. CLI does not retain compiler output in receipt or print it. Suspected cause requiring diagnostic confirmation: Swift Testing may not support the new test's three-array `@Test(arguments: ..., ..., ...)` overload. No implementation fix or additional heavy job started after failure; root informed.

Native raw RED also requires resolving Canvas's now-obsolete recovery loop call under explicit file ownership permission. No Canvas changes by this worker. Preserve native action RED opportunity: do not modify CommandMenu before native test builds/runs and records raw failure plus source hash. App-red CLI accepts no filter, so supplementary selected native evidence must remain identified as raw RED/GREEN, not an app-red receipt.

At this historical stop, WI1/WI2 were green and separation-held; WI3 had not yet reached valid RED or DONE. No commit, push or rebase occurred.

## Authorized same-stage runner diagnosis

Root authorized raw selected lane diagnostics, captured `.build/i344/wi3-red-diagnostic.log`. Compiler confirms unsupported three-collection `@Test` macro: incorrect labels `arguments:_:_:` and cannot convert `[Bool]` to `String`. Corrected only test parameterization to two Boolean collections plus inner preview false/true iteration. This preserves all eight combinations and identical assertions. No production change; the earlier invalid environment attempt is not RED evidence. Re-recording same ID/filter is the receipt CLI's explicit instructed recovery, not overwriting valid specification evidence.

Re-recording succeeded: assertion-failure3/3, `.build/i344/wi3-red-recovery.log`. WI3 package RED is now valid, but no production changes yet because native action RED remains outstanding.

## Native fixture diagnosis

Root received user authorization and removed exactly four obsolete Canvas recovery loop copies; worker preserved those edits. Native xcodegen and build-for-testing succeeded (`native-generate.log`, `native-red-build.log`). First selected raw native run emitted title mismatch then hung with NSApp.keyWindow nil, timed out180.163s,34issues (`native-red.log`). This is NOT accepted action RED. Root authorized fixture-only activation-policy/NSApp.activate additions preserving behavioral assertions; rebuilt successfully (`native-red-harness-build.log`). Second raw selected run again had nil keyWindow, timed out180.160s,34issues (`native-red-harness.log`). No production menu fix was made to chase either fixture failure; these are not valid action receipts. Corresponding native hashes are retained but not claimed as RED/GREEN separation evidence.

At that historical stop, no heavy job remained active. The worker requested a root/spec-adversary decision on the existing resolver seam rather than starting another blind focus run. The approved resolution and final evidence are above.
