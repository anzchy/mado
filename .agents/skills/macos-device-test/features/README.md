# Mado verification map

The run recipes for device-testing Mado, one file per feature, keyed by feature-ledger row IDs. The ledger
(`docs/feature-ledger.md`) says **whether** a capability works and what proves it; these files say **how to
drive it** to get that proof. Read this index before a run, then use the matching feature file.

These recipes began as plan drafts. Some paths have since been exercised; check the relevant
`docs/validation/` record and the current UI before a run. Correct a stale recipe when the real app
differs, and record the deviation.

## Baseline preconditions

- Machine and display as the brief names ([runbook](../references/device-runbook.md) §2): @1x runs locally on the mini; @2x rows run on the
  MacBook over SSH through its desktop-started tmux session, or are NOT VERIFIED until that path is set up.
- A fresh build of the code under test, signed by team `GRT84NAK4T`, launched by this run ([runbook](../references/device-runbook.md) §4–5).
- Doctor passes every line ([runbook](../references/device-runbook.md) §6).
- No Mado instance this run didn't start; the shared desktop GUI lock belongs to this run ([runbook](../references/device-runbook.md) §3).
- Fixtures copied from `TestAssets/` into `$RUN_DIR/fixtures/` and hash-checked against the manifest.
- Sandbox container state as the brief says: either "existing" (left alone) or "fresh" (deleted with the
  user's approval, recorded).
- Input source ABC.

## Driving conventions

- Start every recipe from the baseline unless its preconditions say otherwise.
- Prefer keyboard shortcuts, then accessibility identifiers, then menu titles; coordinates last.
- Prefer a verified accessibility identifier when one exists; otherwise use the current menu or a
  documented keyboard command.
- Treat every key and menu name in a recipe as literal.
- Use `key.sh` only for one printable character. Named keys go through `kc.sh`: Tab `48`, Esc `53`, Return
  `36`, Left/Right/Down/Up `123`–`126`, and Space `49`.
- Drag-in from Finder (OPEN-04): computer-use drags did not arrive. A CGEvent drag did: mouse-moved, then
  left-down on a Finder list-view row, a 0.4 s hold, small then ~60 `leftMouseDragged` steps, a 0.6 s pause
  over the target, then left-up, with Finder frontmost (P1-02 run `20261024-025857`). Record it as synthetic
  input. Drag a file the app has never opened: an earlier `open -a` of the same path gives the process access
  and hides access defects. Keep the drag source outside `fixtures/`, because Finder writes `.DS_Store` there.
- Undo what a recipe changes (preferences, granted folders) when the brief asks for a clean machine
  afterwards; never delete evidence.

## Proof and skip reporting

- Capture the action and the resulting state, not only the final screen.
- Drive every entry point a row's 怎么确认 lists. Report each entry point on its own verdict line; an entry
  point you didn't drive is NOT VERIFIED and is never reported as verified through another one.
- Check anything persisted by quitting and relaunching; check anything written by reading the file.
- Name every artifact `<ledger-id>-<entry-point>-<state>.<ext>`, in `$RUN_DIR/shots/`.
- Report an unreachable path with the attempted action and the unmet precondition.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behaviour. It then
has exactly four H2 sections, in this order:

1. `Sub-features` lists the ledger row IDs it covers, one line each.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with computer use` starts with `Preconditions:` and pairs each user action with what to do
   and the observable result, as labelled bullets.
4. `Gotchas` lists traps that can waste or invalidate a run.

Keep implementation details out. Name only user paths, stable handles, required state and observable proof.
A recipe is written when its first row moves to `Partial`; a row can't reach 真机 without one.

## Known tool behaviour

Record here what a real run found out about the tools, so the next run doesn't rediscover it.

- Computer-use Escape on a native app: unverified (mdpro's WebView got only a key-up).
- Trackpad pinch: computer use has no pinch gesture; pinch entry points are a user step or NOT VERIFIED.

## Features

- [Actual pixels and anchored zoom](./canvas-pixels.md) covers 1:1 display and cursor-anchored zoom.
- [Open and grant a folder](./open-and-grant.md) covers a File Grant, the folder-grant prompt, restore after
  relaunch, and release on close.
- [Decode real images](./decode-images.md) covers formats, orientation, transparency, large images and broken
  files.
- [Keyboard and command routing](./keyboard-commands.md) covers the basic shortcuts and input-field and menu
  priority.
- [Chrome show, hide and interaction locks](./chrome-show-hide.md) covers immersive toolbar/window chrome,
  edge and Tab recall, lock states, responsive layout, and window closing.
- [Recursive folder scan and honest progress](./recursive-folder-scan.md) covers P2-04 nested browsing,
  cycle boundaries, indeterminate reading, completed counts, and page 24 Prototype comparison.
