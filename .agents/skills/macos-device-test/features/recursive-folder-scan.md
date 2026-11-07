# Recursive folder scan and honest progress

The View menu can include nested folders in browsing. While Mado searches, it shows an indeterminate reading state; after completion, it shows the actual image count. This recipe covers P2-04 without assuming the HTML mockup's sample files or unavailable future grid controls exist in the App.

## Sub-features

- `FOLDER-04`: turn recursion on, reach nested images, finish a directory-cycle symlink without duplicates, then turn recursion off and exclude nested images.
- `FOLDER-05`: show reading without a percentage while the total is unknown; show the actual image count only after completion.
- `FOLDER-01`: capture the page 24 loading state, Cancel, and the first image after scanning. Its existing acceptance and limitations remain separate.
- `FOLDER-03`: check PNG filtering after a recursion change, including the current image and empty result. This is a regression entry, not a substitute for its full acceptance.

## How to get to it (user POV)

Use File → Open… to choose a folder. In View, switch **Include Subfolders** on or off while an image is displayed, then use Previous Image and Next Image to inspect the resulting set. While the folder is being read, use **Cancel Reading** (`取消读取`, AX `state.cancel-folder`); after a recoverable failure, use Retry.

## Driving it with computer use

Preconditions: follow the runbook's signed, sandboxed build, doctor and shared GUI lock. Use fresh folders outside the App container, selected through the real open panel. Prepare and hash-check two inputs under `$RUN_DIR/fixtures/`: (a) a small tree with a top-level image, a nested image, a deeper nested image, an inward directory-cycle symlink and an outside-root symlink; (b) a tree with only a nested image, to exercise empty flat rescans. For a reading-state capture, use the generated S2 set or another inventoried large tree. Record each tree's actual top-level, recursive and unique-image inventory before opening it. Do not pre-grant a folder or modify the App to prolong reading.

1. Open the small tree by File → Open…. Record the View menu's Include Subfolders title, unchecked state, empty shortcut and accessibility identifier in English and Chinese separately. Confirm nested images are absent from navigation when off. Record the displayed completed count against the inventoried flat set.
2. Turn Include Subfolders on through the View menu. Capture the checked state and navigate to the nested and deeper images. Confirm the cycle terminates, the outside-root target does not enter navigation, and aliases do not duplicate an image. Record the completed count against the unique recursive inventory. Toggle off while nested content is current: the displayed image and navigation must reconcile to a valid flat image, with no old nested batch returning.
3. With a real image already visible, toggle recursion on an inventoried large tree. Capture the **separate image-visible rescan state**: the image stays visible, viewer chrome says indeterminate Reading, and no percentage or stale completed count appears. Then capture the inventoried final count. Put this reachable state and its conditions in the premerge UI brief table with its own verdict. If scanning ends before the capture, mark this condition `NOT VERIFIED`; the page 24 folder-opening capture cannot substitute.
4. Open the nested-only tree, display its nested image with recursion on, then toggle off. When flat scanning completes empty, confirm the old nested image is no longer painted or navigable. Repeat with off → on → off before completion and with a recoverable failed off scan → Retry → empty success. Keep a screenshot or short capture of each action and settled result; a package-level state assertion cannot prove that the native image cleared.
5. Open the inventoried large tree and capture page 24 while the total is unknown. The App must show indeterminate Reading, no percentage and no guessed completed count. Capture the actual completed count and name-first image after scanning. If the transient reading state finishes before capture, mark that capture `NOT VERIFIED`; do not infer it from a static HTML page or an artificially slowed build. Activate **Cancel Reading** (`state.cancel-folder`) on a separate run and record the resulting settled state.
6. Check PNG-only filtering before and after a recursion toggle; confirm both the visible image and Next/Previous obey the filtered set. Exercise Retry only after a reproducible, normal-user-path failure; record the exact cause and partial count. If no such failure can be produced without altering sandbox grants or App internals, mark that path `NOT VERIFIED`.
7. For UI parity, pin page 24 `design/prototypes/picsee-browser/states/folder-loading.html` and its manifest hashes before the run. Render the HTML over HTTP and capture its raw 1280×800 light reference. Capture the signed App window at the same viewport/appearance and record backing scale, language, fixture, build SHA, signature/sandbox doctor and run ID. Predeclare measured regions, dynamic-data masks and cited native exceptions; compare original images and actual actions under `docs/agents/ui-parity-contract.md`. Run @1x on the mini and @2x only on a suitable Retina device. Report every unrun required condition `NOT VERIFIED`.

Save only run-owned screenshots, action logs, menu/AX observations, fixture inventory and image hashes under `$RUN_DIR`. Give each action and parity condition its own PASS, FAIL or NOT VERIFIED verdict. The independent verifier differs from the implementer; the active independent auditor (opus-auditor since 2026-10-25) reviews the original App and HTML captures before a UI PR merges.

## Gotchas

- The browser prototype's sidebar, grid, sample folder name and sample count are not proof that the current native viewer implements them. Compare the page 24 reading composition and documented native mapping; do not mask missing controls after seeing a difference.
- The 5,000-item S2 synthetic set proves enumeration, cancellation and count, not photographic decode performance. Do not report latency or memory numbers from it as real-photo benchmarks.
- A symlink may point outside the selected root; do not open that target separately before the boundary check, since a previous grant can conceal an access defect. Do not retarget links concurrently during this ordinary-path run.
- The Mac mini is @1x. A missing MacBook desktop/SSH path means @2x is `NOT VERIFIED`; @1x cannot substitute. A changed App/design/input SHA requires a new parity capture and review.
- Permission denial, VoiceOver speech, keyboard focus, Chinese menu text and alert dismissal require their own device observations. Do not promote ledger rows or mark the UI PR merge-ready from unit tests, unsigned builds or a static HTML reading.
