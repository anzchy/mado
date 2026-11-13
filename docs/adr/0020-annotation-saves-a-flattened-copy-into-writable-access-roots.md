---
status: accepted
date: 2026-11-13
---

# ADR-020: Annotation saves a flattened Annotated Copy, and Access Roots become writable

The owner has decided that annotation is done inside Mado, applies to any image that is open, and saves a copy without overwriting the original ([grilling record](../plans/20261113-capture-annotation-ocr-grilling.md) 0.3, 4.1–4.8). This continues [ADR-007](0007-save-as-by-default-no-overwrite-in-v1.md)'s default of saving a copy, and changes [ADR-008](0008-folder-access-read-only-app-scoped-bookmarks.md)'s read-only folder access.

## Decision

- **Annotate Mode:** the same window switches between viewing and annotating, with ⌘E or the Annotate button. Arrow-key navigation is off in this mode. Esc exits, and asks first if there are unsaved changes.
- **Saving:**
  - ⌘S writes `<original name>-annotated.<original extension>` in the same folder and never overwrites the original. The original format is kept; only formats Mado cannot write are saved as PNG.
  - On a name clash, a sequence number is appended, following the naming rule for Captures.
  - ⌘C copies the annotated image without saving it.
- **Flattened:** saving merges the annotations into the pixels. There is no project file, no private metadata and no re-editing after the save. Inside Annotate Mode, undo, redo and adjusting marks remain available.
- **Write access:** following P5-04, the entitlement changes from `files.user-selected.read-only` to `files.user-selected.read-write`. Inside a folder the user granted (an Access Root), ⌘S writes directly. Anywhere else, a save panel appears. The rules in ADR-007 still apply: never write over the source file, and write through a temporary location followed by an atomic replace.
- **Tools (v1):** arrow, rectangle, text, highlighter, pen, redaction, crop and numbered markers. Redaction defaults to mosaic with adjustable strength, and a solid box is also offered.

## Considered options

- **Keep folders read-only and show a save panel every time:** narrower permission, but every save takes an extra step. Rejected.
- **Let a fresh Capture overwrite itself:** saves one file, but breaks ADR-007 and adds an exception. Rejected.
- **A re-editable project file or sidecar:** the most frequent complaint in Snagit-style tools is an extra file next to every image ([annotation and user-journey research](../research/20261113-capture-annotation-ux.md)). Rejected for v1.

## Consequences

- Access Roots become read-write, so every write path must take a lease first and must not write outside the grant. Whether bookmarks created under the read-only entitlement become writable automatically is unverified, and needs a device test after the entitlement change.
- Weak mosaic can be reversed to recover the text underneath. The owner chose mosaic as the default anyway. The minimum strength, and whether to show a hint about this, are decided in the spec.
- Ledger rows for annotation and saving (EDIT-03 / EDIT-06 and any new rows) follow this ADR.
