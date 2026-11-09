# WI-1 — DONE (#604 fix1)

Production: one line clears sidebarFailedReadFolder inside !preservingWatch in cancelSidebarTree. Standalone entry, empty restore, page26 entry/restore, no-root restore and window close already use this path; no extra restore edits needed. Preserving watch reload keeps its marker.

## Genuine RED / separation
Accepted receipt i604-fix1-WI-1-r3, app-red filter issue604LeaveThenReopenSameFolderStartsNormalL0Fallback. Before production change, exact previous Parent0/Locked1/Readable1 tree rejected against new Locked0 fallback, synchronously and during held listing/main scan.1failed test,2assertion issues,0.338s. Corrected fixture uses root-external standalone image with explicit fileGrant and reopens the EXACT failed row URL, including directory spelling.
One-line implementation then same-filter verify GREEN,SEPARATION-HELD. Final plugin fingerprint comparison identical,modified/removed/unknown empty.

Rejected fixture attempts are NOT regression evidence: r1 waited for cleared snapshot while in-root image auto-started Parent scan, causing180s test timeout (CLI incorrectly labeled assertion RED); r2 outside-root correction ran GREEN because path-equivalent rebuilt URL differed from actual directory row URL and already cleared marker. Both preserved in local logs/receipt copies, left unverified and excluded from trailers/proof. Production remained untouched until genuine r3 assertion RED. New fixture lines were corrected before valid r3; none changed afterward.

## Real-watch sensitivity
Actual PNG write under Parent and production FSEventSource/WatchHub deliver reload; rendered and adapter Parent count1→2 proves work completed, exact failed topology and dash retained. Baseline PASS1/1,0.548s.
Explicit authorized mutation: replace retention else-if with else (unconditional clear on reload). Mutant build succeeds, focused unchanged watch test FAIL1test,3issues,0.535s,0errors: Locked0 instead of Parent/Locked/Readable,Parentcountnil instead of2,real probe count assertion. Mutant KILLED by behavioral assertions,not timeout/compile failure.
Finally restored pre-mutation source byte-for-byte. SHA256 before/after7ad7620a539f833c28a6271d7008f22722a5af1b1aaaa7ae7611584c86faba6b. Restored build PASS,final watch test GREEN in combined run.

## Checks
Final issue604|issue507 App set ran ONCE,19testsPASS,0fail/error/skip,6.542s,no retry. No GUI/push. Package bytes unchanged; fresh prior fullunit1787tests/43suites/2knownissues and exact LCOV reused,independent coverage audit PASS. Ledger GRID-14 sentence spaces cleaned and limitations appended for new automated behavior; status/acceptance unchanged,HTML regenerated/html-check PASS.

Evidence: ~/.picsee/herdr/gpt-imple-2/i604-logs/fix1-{red-r3-app,red-r3-receipt,verify-r3,watch-baseline,mutant-build,mutant-app,restored-build,final-combined-app}.log; fix1-mutation-result.json; fix1-final-recorded-lines.json. Invalid evidence preserved separately.
