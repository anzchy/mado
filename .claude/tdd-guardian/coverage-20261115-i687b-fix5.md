# #687b fix round 5 coverage

PASS. Full Package (`node scripts/tdd/unit-lane.mjs`, tree at 3c87fcb5): 2,171 tests in 46 suites passed, 2 known
issues. Strict eligible coverage: Package lines 16,006/16,006, eligible functions 3,756/3,756, exact 100%
(`Coverage gate: PASS`). The round changes App code only; the Package is unchanged.

App: `issue687Fix5` 8/8; gate filter `issue687|issue692|ViewerRecogniseText|Annotate` 68/68.

RED receipts 687b-F5-1..7 and 687b-F5-M recorded assertion failures at ed919b82 plus stubs. Verify reports
SEPARATION-BROKEN for all eight because each receipt fingerprints the whole shared test file and three harness lines
changed after recording (F7 undo dispatch, two image-direction comparisons; plus `import MadoCore` and one added
arrow check). See tests-20261115-i687b-fix5.md "Specification changes after RED". The MEDIUM
implementation-already-present note is the expected stub case.

Review round: 687b-F5-R1 recorded a genuine assertion failure and verified "Specification held". App gate filter plus
`recogniseNotice` 75/75 after the fix.
