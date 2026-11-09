# WI-1 — DONE

First RED: i604-WI-1, app-red filter issue604FailedChildKeepsParentAndReadableSibling. Actual topology [Locked:0:true] rejected by expected Parent:0:false, Locked:1:true, Readable:1:false. Genuine assertion failure 1/1, no production edits at record. Receipt verify passed; SEPARATION-HELD, recorded test lines unchanged (only additive synchronization/partial-batch setup).

Implementation: failure-specific parent listing under existing AccessRoot boundary; explicit optional siblings presentation contract; main failure hook cancels/replaces earlier child loading; failed tree persists until complete main snapshot restores normal projection. No scan admission/recovery refactor. Scope guard confirms successful child still omits siblings.

Verification: selected App run 6/6 green, including three new #604 cases and existing lost-sidebar regressions. Fresh full configured unit command with coverage passed 1787 tests in43 suites,2 existing known issues; test phase96.034s. Fresh LCOV exported, independently parsed by root: lines/statements16701/16701, functions3212/3212, branches unmeasured (threshold0). Package contract S5 tests cover sibling depths/selection, count update/masking, baseline reset, clear and lost/root guards.

Logs: ~/.picsee/herdr/gpt-imple-2/i604-logs/wi1-{red-build,red-receipt,red-app,green-build,green-build2,green-app,green-app2,unit,lcov,verify}.log (see actual directory for exact filenames). No push/commit/GUI runs.
