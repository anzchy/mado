# #635 controlled-reproduction correction

The first controlled harness made a false lifecycle assumption: it let the failed-read sidebar recount finish, then armed a new Parent-count gate and clicked Retry expecting Retry to start another sidebar load. `ViewerStateHost`'s Retry action calls `session.retryFolderScan()`; it does not call `openFolder` or `loadSidebarTree`. Consequently no new Parent count reached that gate, and the harness ended only at the unchanged three-minute test limit. It did not reach the specific readiness/count assertions and is not accepted as genuine RED for #635.

The raw first run and plugin receipt `I635-WI-1` remain preserved by the root agent (`i635-controlled-r1-app.log`). The corrected controlled harness will use a separate receipt, `I635-WI-1-R2`; it does not overwrite or reclassify the original run.

The corrected ordering holds the actual **failed-read reload** count across Retry:

1. Complete the initial child Reading setup and drain its independent sidebar counts; keep the old Parent row identity.
2. Arm the real Parent image-count result before failing child scan attempt 1.
3. Observe the failed-read replacement row (different identity), actual real count 2 captured but held, blank Parent label, Child dash and Grandchild absent under the settled #604 failure projection.
4. Click Retry while that same failed-read loader count remains held. Observe scanner attempt 2 held, the same failed-read Parent row still blank, and then evaluate the actual scanner-only Retry-readiness predicate.
5. Check that readiness must remain false while the count is pending. If the old predicate returns true, invoke the existing Parent=2 assertions to expose the same blank/hidden/name-only triple as the CI failure. Release the count independently and use the same readiness predicate before the final native-row assertions.

No count-aware predicate guard has been applied yet. Existing behavior assertions and the three-minute test limit are unchanged; the wrapper still computes real filesystem counts, and teardown releases/drains every controlled count and scanner. The only changed assumptions are when the new reproduction arms its external count gate and which existing sidebar generation supplies that count. No product code, sleeps, retry policy or timeout changes were introduced.
