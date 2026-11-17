Report-Task: i688-selection-research
# How open-source OCR and text-layer apps map a drag on an image to the selected text (research for Mado #688)

Researched 2026-11-16 by two independent, blind researchers (an Opus subagent and Codex), each given the same brief. The owner asked for this before any further fix of #688 (「分别让subagent+opus和 codex搜索相关OCR开源app最佳实践，Edge case有哪些，test是怎么写的，尽可能收集全，形成一个文档 保存到 @docs/research 再动手决定怎么修复」).

Labels in the appendices: CONFIRMED = primary source read on 2026-11-16 (source code at a tag or commit, official docs); INFERRED = reasoned from evidence; UNCONFIRMED = could not verify. Static evidence only; nothing here was run on a device.

How this document was made: sections 1–8 are the delegator's synthesis of the two notes and add no new research. Appendix A (Opus) and Appendix B (Codex) are the two notes verbatim except that their headings are demoted one level. Codex's sandbox was read-only, so its note came back in its reply and was saved unchanged. The Opus numbers (for example "779 of 4000") come from its own Python scratch port, which is not in the repository; the delegator has not reproduced them. Source line numbers and test names were not re-checked by the delegator.

## 1. Answer

- **Root cause (both notes, same conclusion).** The current code (`endpointOutsideBoxes`, `App/TextRecognition/ImageTextSelection.swift` at cf71cc0e) picks one *seed* box, then takes every box that overlaps the seed as "the row". A tall box overlaps two visual rows, so a tall seed merges them. That one step explains the price layout (CE1), the tall variant (CE2) and the device failure. A second defect, pairing neighbours in a list sorted by `minX`, explains the nested-box case (CE3).
- **Neither note found an engine that works this way.** MuPDF, PDFium/Chromium PDF, pdf.js, Blink, Poppler, Okular, pdfminer and OCRmyPDF pick the line from vertical position first and the place in the line from horizontal position only; none builds a row from a single seed box.
- **Both recommend the same shape.** (1) Build rows once per recognised-line snapshot, and keep a box that overlaps two rows that do not overlap each other (a "bridge" in Opus's words, a "spanner" in Codex's) out of row building; it can still be hit when the pointer is inside it. (2) For a pointer outside every box, pick the row by perpendicular distance only. (3) Inside the row, find neighbours by extreme edges (largest right edge on the left, smallest left edge on the right), not by list adjacency, so nested boxes are safe. (4) A gap on the anchor's row clamps to the anchor's side. (5) Work in the text's own frame (inverse of the canvas transform) so rotation and flips drop out of the rule.
- **Both recommend the same test shape.** Keep a named regression table that sweeps the neighbourhood of each counterexample (the existing tests only probed y=12 and y=55, not the y=21 and y=62 points the auditors used), and add generated layouts that check invariants, plus frozen real Vision boxes.
- **Nothing is validated on a device.** The 0.5 overlap threshold, Vision's line order, and what Apple Live Text does for a drag ending in empty space are unverified in both notes.

## 2. Where the two notes agree

| Point | Opus | Codex |
|---|---|---|
| Seed-then-overlap is the defect | D1: three structural defects, reproduced by a port (CE1 "November\nMonday", CE2 "\n", CE3 "wide\nshort") | Answer: confirmed by reading the code (lines 138–157) |
| Spanners and bridges stay out of rows | Non-bridge lines form rows; the bridge is still hittable | Process shortest to tallest; a box that fits two rows is a spanner and joins neither |
| Row chosen by vertical distance only | `dv` to the row band; `p.u` not consulted until the row is fixed | Row score contains no `u` |
| Nested boxes | Neighbours by `max u1` / `min u0`, as Blink does | Interval union with a running maximum, boundary owned by the box that exposes it |
| Gap on the anchor's row | Candidates are the two edges facing the gap; pick the one nearer the anchor in reading order | Pick the boundary on the anchor's side |
| Work in the text frame | Inverse of `ImageTextGeometry`; removes the rotation branch | Invert the canvas transform; do not derive direction from rotated bounding boxes |
| In-box hit unchanged | First containing box by index, offset by `u` | Preserve the current first-containing-box result |
| Tests: invariants over generated layouts | Metamorphic invariants I1–I10 | Oracle plus required-properties table |
| Frozen real Vision fixtures | Keep `mixed.png` and `mixed-orientation-6.jpg` device tests | Freeze recognised strings and boxes from those fixtures, record the environment |
| Open items | 0.5 threshold, Vision order, above-first / below-last | 0.5 threshold, Apple behaviour undocumented |

## 3. Where they differ

| Topic | Opus | Codex | Why it matters |
|---|---|---|---|
| Row membership rule | Connected components of non-bridge lines under "overlap > 0.5 × shorter height" (transitive among non-bridges; the note argues it is an equivalence relation). Fallback to all lines if every line is a bridge. | Shortest-first; a box joins a row only if it overlaps *every* member by more than half the shorter height and the row's core band stays non-empty; ambiguous boxes become spanners. | Codex's is stricter (no chains at all) and quadratic; Opus's is simpler and has a proof sketch. Which handles slightly misaligned real Vision boxes better is untested in both. |
| Gap choice | Two facing-edge candidates; take the one nearer the anchor in reading order; if the candidates straddle the anchor (Vision order disagrees with geometry), use the anchor's geometric side. | If the anchor is in the row, the anchor-side boundary; otherwise cross-row logical direction. If original indices interleave, flag the layout as ambiguous with a deterministic fallback. | Both treat interleaved reading order as a known gap; Opus handles it with a rule, Codex by flagging it. |
| Drag that starts in a spanner | Not discussed separately (a bridge can still be the anchor line by index). | Treated as having no anchor row; ordinary row-distance and cross-row rules. Codex says this fallback is not evidence that it matches user expectations. | A new case the owner has not ruled on. |
| Oracle for tests | Warns that an oracle built from the same spec as the code is not independent; the metamorphic invariants (I2–I5) are the independent check. | Generator supplies the true row membership directly, and the oracle must not call the production row builder; row detection is tested separately against that truth. | Complementary: Opus's invariants need no ground truth, Codex's oracle gives exact expected positions. |
| Generator content | Rows of 1–3 lines, ±2 pt jitter, mixed heights, bridges, nested lines, side-by-side labels; endpoints at edge ± ε. | Adds graphemes (ASCII, Chinese, combining sequences, emoji), quarter-turns, flips, zoom, translation, both anchor sides and directions. | Codex's covers the `Character`-offset side of the problem. |
| Reverse-drag symmetry | I9 only for in-box endpoints; not for gap endpoints. | Same restriction (conditional reversal). | Agree. |
| Edge-continuity check | I2: moving the endpoint from just inside an edge to 1 pt outside must not change the text. Opus found it alone does not catch the current code on a plain generator; bridges and nesting must be in the generator. | Exact boundary sweeps around every edge, midpoint and gap. | Same idea; Opus measured why bridges and nesting must be generated. |
| Performance | Not discussed. | Cache rows per snapshot; complete-membership construction is quadratic; benchmark before optimising; no timings were measured. | Open. |
| Confidence threshold | Not discussed. | Filtering low-confidence observations would also change reading order and copied text; out of scope for this fix. | Keep out of this fix. |

## 4. Why three fix rounds kept failing (from both notes)

- Each round repaired the previous round's counterexample points and re-created the same class of bug nearby. The existing tests probe the target line's own band (y=12, y=55, y=10); the failing points are 1–2 pt outside it (y=21, y=62), where a tall box is the only one that contains the coordinate. Codex confirmed this by reading the tests (`issue688PriceLayoutKeepsUpperLineAtBothOvershoots` tests y=12; `issue688TallLineDoesNotPullLowerOvershootToUpper` tests y=55; `issue688RowEndUsesLargestMaxX` has no following `C` box).
- The code treats a heuristic (overlap with a seed) as if it were a partition. Neither note found an upstream engine that does.
- Opus: OCRmyPDF explicitly expects OCR line boxes to stretch into the neighbouring line (`STRETCHED_LINE_RATIO = 1.5`, `renderer.py`), so tall Vision boxes are an expected input, not a rare one.
- Opus: Apple's Vision documentation says nothing about the order of results, so reading order cannot be assumed to follow geometry.

## 5. Decisions the owner or a device run must make before the next fix

1. **Row-building rule**: Opus's connected components of non-bridges, or Codex's shortest-first complete-membership construction. The shared core (spanners excluded, vertical first, extreme-edge neighbours, anchor-side gap) is the same either way.
2. **Reading order**: keep "multi-line reading order unchanged" (the current rule) and handle disagreement with a fallback, or sort lines into rows × inline order once (Opus D4). The second changes an approved rule.
3. **Above the first line and below the last**: Blink on Mac goes to the start or end of the line; MuPDF uses the band; Mado today uses the inline coordinate. The owner has not ruled on it.
4. **Ties exactly at the midpoint between two rows**: Opus resolves toward the anchor (select less); that is its choice, not the owner's.
5. **A drag that starts inside a spanner or drop-cap-like tall box**: no evidence on what users expect (Codex).
6. **The 0.5 overlap threshold** against real Vision boxes (descenders can create false bridges; OCRmyPDF's 1.5× median-height ratio is an alternative). Needs frozen real boxes or a device run.

## 6. Test strategy, merged

Keep the existing device tests on `mixed.png` and `mixed-orientation-6.jpg` for real Vision geometry, and add:

1. **Named regression table** (table-driven, Swift Testing arguments): CE1 price at (330,21) and its neighbourhood (330,2), (280,22); CE2 tall at (600,62) and (600,80), (250,80); CE3 nested with a following `C` box, drag to (350,10); CE4 side-by-side labels; CE5 margins, overshoot, reverse, rotated. Sweep the coordinates around each edge, not only the single point that failed.
2. **Seeded generated layouts** (a small fixed-seed generator; print seed and layout on failure), including tall bridge lines, nested short lines, side-by-side labels, mixed heights, jitter, grapheme-rich text, and all four quarter-turns and flips.
3. **Invariants.** Metamorphic (no ground truth needed): edge continuity; adding a tall line beside everything leaves the result unchanged; adding a short line inside another leaves the result unchanged; transform covariance. Oracle-based (independent of production code): inside-hit dominance, perpendicular priority, valid offsets, whole-range copy, contiguity, and conditional monotonicity within a row. Symmetry (A→B equals B→A) only for in-box endpoints.
4. **Row-detector tests separate from selection tests**: the generator supplies true row membership; a separate test measures whether the detector recovers it.
5. **Frozen Vision fixtures** recorded with the recognition environment, so geometry regressions are distinguishable from recognition changes.

Opus's measurements (its own scratch port, not reproduced): against the current code, "adding a tall line" failed 779 of 4000 generated checks and "adding a nested short line" failed 1854 of 4000; its recommended rule failed 0 in both. Edge continuity alone did not catch the current code until bridges and nesting were in the generator.

## 7. What the research found about tests in other projects

Real tests exist for hit-testing and ordering (PDFium, pdf.js, Blink, WebKit, PDFBox, pdfminer, Tesseract, docTR, Kraken, PdfPig, NormCap, Text-Grab; the full list with file and line is in Appendix B section C). Opus found no property-based or fuzz tests for selection in any project it read; Codex found no verified upstream test asserting full-range copy, pointer monotonicity, reversed outside-gap drags and inside-box dominance together (and marks that UNCONFIRMED for the projects whose tests it could not read). The closest precedents are Tesseract's exhaustive enumeration of all 4^7 direction sequences for line ordering, and Blink and WebKit's coordinate sweeps. pdf.js's "doesn't jump when moving selection" uses a tolerance that should not be copied into exact Mado assertions (Codex).

## 8. Limits of this research

- **Not verified by either note**: how Apple Live Text or `ImageAnalysisOverlayView` handles a drag in empty space (undocumented); Capture2Text's and Textractor's source-level selection behaviour; several projects' selection-specific tests (names confirmed, contents not read).
- **Opus did not read**: Tesseract's internal line finding, Kraken, Surya, docTR, LayoutParser internals, WebKit and Gecko caret-from-point, Blink's web-test contents, Text-Grab's test contents, the CSSOM spec past its first steps.
- **Device tests use real Vision boxes** from `mixed.png`; neither researcher could run them. Opus modelled them with hand-built boxes. The 0.5 threshold has not been checked against real Vision output.
- **Codex's execution exception**: two of its research subagents tried read-only HTTP access through the system `python3`, and Apple's developer-tool shim emitted `xcodebuild` diagnostics. They stopped that path and continued through web and GitHub tools. No project build or test was intentionally started, but Codex cannot claim that no Xcode-related process ran.
- **Delegator checks**: only that both notes exist and begin with the right `Report-Task` line. Citations were not re-opened.


---

# Appendix A — Opus researcher note (verbatim; source: Report-Task i688-selection-opus)


## How open-source text-layer / OCR apps map a drag to selected text, and what Mado #688 should do

Researcher: Opus subagent, 2026-11-16. Read-only on the repo. Mado code read at worktree `picsee-wt/gpt-imple-1-688`, commit cf71cc0e: `App/TextRecognition/ImageTextSelection.swift` (lines 99-175) and `AppTests/Issue688SelectTextTests.swift` (247 lines). I did not read the other researcher's note or any auditor file.

Labels: **CONFIRMED** means I read the primary source today at the pinned commit or doc page. **INFERRED** means my reasoning from confirmed sources. **UNCONFIRMED** means I did not read a primary source.

### Answer (10 lines)

1. None of the engines I read builds a "row" by seeding from one box and then collecting every box that overlaps it. That seed step is the root of all five failures: a tall box becomes the seed and merges two rows (CE1, CE2), and pairing neighbours sorted by `minX` mishandles nested boxes (CE3).
2. Browsers (Blink) pick the line only by block-axis (vertical) position, then pick inside the line only by inline-axis position. The x coordinate never chooses the line. This is the owner rule. CONFIRMED.
3. Okular snaps a start point in empty space forward and an end point backward ("inward"). pdf.js limits a jump over empty space to the span being modified. Chromium's PDF viewer leaves the selection unchanged over empty space. All three keep the selection from growing across a gap the pointer has not crossed. CONFIRMED.
4. Recommendation:
   - (a) Mark a line as a **bridge** when it overlaps two lines that do not overlap each other. Bridges never define a row and never resolve an outside point; they still win in-box hits.
   - (b) The remaining lines form rows (equivalence classes). Pick the row by vertical distance to its band.
   - (c) Inside the row, the left neighbour is `argmax maxX < u` and the right neighbour is `argmin minX > u`, so nesting is safe.
   - (d) When the point is in a gap between them, take the candidate nearer the anchor in reading order: the "inward" rule.
5. A Python prototype of (4) passes all five counterexamples and every current #688 test case I modelled. A port of cf71cc0e reproduces CE1-CE3 exactly ("November\nMonday", "\n", "wide\nshort").
6. Test strategy: keep the named regression table, and add seeded generated layouts with metamorphic invariants. Bridge insertion caught the cf71cc0e port in 779 of 4000 checks. Nested-line insertion caught it in 1854 of 4000. Both found 0 failures against the recommended rule. Edge continuity and transform invariance are also included.
7. Uncertain: Vision's within-row line order; the threshold for "overlap"; the owner's wanted behaviour above the first line and below the last.

---

### A. Algorithms (per implementation)

#### A1. MuPDF structured text: `fz_highlight_selection`, `fz_copy_selection`, `fz_snap_selection`. CONFIRMED

Source: `source/fitz/stext-search.c` and `source/fitz/stext-device.c`, ArtifexSoftware/mupdf master @ `131220bea34f854eecefbf849257aec515ca1450`.
https://github.com/ArtifexSoftware/mupdf/blob/131220bea34f854eecefbf849257aec515ca1450/source/fitz/stext-search.c

1. **Line grouping** (stext-device.c 767-1014; constants 85-88). Each glyph is compared with the pen position:
   - `base_offset` is the perpendicular offset divided by the font size. If `|base_offset| < BASE_MAX_DIST` (0.8), the glyph stays on the same line, provided the spacing along the line is within `SPACE_MAX_DIST` (0.8).
   - Otherwise a new line starts. A new paragraph starts when `|base_offset| > PARAGRAPH_DIST` (1.5).
   - Lines are built incrementally in content-stream order, not by box overlap.
2. **Outside point** (`find_closest_in_page`, 183-266). Each endpoint is resolved **independently, with no anchor context**:
   - For each line, `vdist` is the signed distance from the mid-line, and the half band is `hsize = largest char size / 2`, not the box height.
   - If the point is inside the band and between the line's end points, that line is the hit.
   - If the point is inside the band but past an end ("within extended line", 238-246), MuPDF takes the line with the smallest along-line distance to an end point.
   - Otherwise ("outside line", 248-256) it takes the line with the smallest `|vdist|`. The code comment says `// TODO: closest column?` (line 250).
   - A within-band candidate sets `closest_vdist = 0`, so it always beats every outside-band line.
3. **Offset in the chosen line** (`find_closest_in_line`, 128-181). Above the band gives the line start; below the band gives the line end (147-150). Inside the band, MuPDF takes the nearest char edge, using `lr`/`ll` swapped for bidi-odd chars (bidi handling, 155-165).
4. **Ordering and direction** (`fz_enumerate_selection`, 279-316). Both points become global char indexes in block/line order. They are swapped if `start > end` (289). Selection is a contiguous index range. Copy appends `\n` (or `\r\n`) after each line (`on_copy_line_*`).
5. **Highlight quads** merge glyphs with `hfuzz = 0.5`, `vfuzz = 0.1` times the char size (459-460).

Relevance to Mado (INFERRED):
- The band per line is the line's own glyph size. A tall OCR box would therefore get a tall band and win the within-band branch, the same failure as CE1.
- The "extended line" branch picks among lines by horizontal distance, which the owner rule forbids.
- What Mado should keep: "above the band gives the start, below gives the end", and endpoints that are pure functions of the point plus one ordering.

#### A2. Chromium PDF viewer + PDFium. CONFIRMED

- **PDFium** `CPDF_TextPage::GetIndexAtPos` (core/fpdftext/cpdf_textpage.cpp 485-523, chromium/pdfium main @ `a84323421e94`). It returns the first char whose box contains the point. Otherwise it returns the char whose box grown by `tolerance/2` contains the point, choosing the smallest `xdif + ydif`, where each term is the distance to the nearest edge. With no candidate it returns -1.
- **Chromium** `PDFiumPage::GetCharInfo` (pdf/pdfium/pdfium_page.cc 1526-1529, chromium/chromium main @ `1ff7881be4bc`) uses `kTolerance = 20.0` points.
- `PDFiumEngine::OnMouseMove` (pdf/pdfium/pdfium_engine.cc 2385-2446):
  - While selecting, if there is no char within tolerance, the code says `// We're selecting but right now we're not over text, so don't change the current selection.` (2433-2437). In other words, empty space **freezes** the extent at its last value.
  - `GetCharIndexBasedOnPointData` (2031-2050) picks the char index or index+1 by comparing x with the char centre, flipped for RTL. There is a `TODO(crbug.com/443275584): Handle vertical text.` at 2030.
- INFERRED: "freeze on empty space" is path-dependent. The result depends on where the pointer was last over text. It cannot be tested as a pure function and it differs from the owner rule. I note it, but do not recommend it.

#### A3. pdf.js text layer. CONFIRMED

- web/text_layer_builder.js, mozilla/pdf.js master @ `60aefc5b51d5`. After rendering, a `div.endOfContent` is appended (125-129). Its CSS (web/text_layer_builder.css 144-155) is `position:absolute; inset:100% 0 0; user-select:none`, and it becomes `top:0` while `.selecting`. It absorbs pointer hits on empty space.
- In browsers other than Firefox or Chromium 148+, the `selectionchange` handler moves `endOfContent` to sit right after (or before) the span being modified. Lines 353-358 explain: "we limit the selection jump to at most cover the entirety of the <span> where the selection is being modified".
- Commit ea43bb43fb (2026-06-30, "Avoid text selection workaround in modern Chromium") says "Chromium 148+ improved their selection behavior when it comes to absolutely positioned elements". It says the workaround "actually become harmful" there.
- Ordering: the DOM order of text items, which is the content-stream order.
- INFERRED: the policy is "a gap never adds text beyond the span you are leaving". This is the owner's 「夹到离开的那段」 in DOM form.

#### A4. Blink caret-from-point (the browser behind `caretPositionFromPoint` and drag selection). CONFIRMED

- `InlineCursor::PositionForPointInInlineFormattingContext` (third_party/blink/renderer/core/layout/inline/inline_cursor.cc 594-710, chromium main @ `1ff7881be4bc`).
- It converts the point to the logical **block offset** only, then finds the line box that contains it. Hitting a line's bottom does not count (642).
- If no line contains the point, it keeps `closest_line_before` and `closest_line_after`, by block offset only.
- On Mac and Unix, `move_caret_to_boundary` puts the caret at the start of the line that follows the point (when the point is above it) or the end of the line that precedes it (673-704). The cited tests are `editing/selection/click-in-margins-inside-editable-div.html`, `fast/writing-mode/flipped-blocks-hit-test-line-edges.html` and `LayoutViewHitTestTest.HitTestHorizontal/4`.
- Inside the chosen line, `PositionForPointInInlineBox` (712-826) uses only the **inline offset**. It finds the child containing it, else `closest_child_after` (smallest start > point), else `closest_child_before` (largest end ≤ point).
- INFERRED:
  - Line boxes in CSS tile the block axis, so a browser never has "a gap between lines". OCR boxes do have gaps, which is why Mado needs a row-choice rule.
  - The structure is still the owner rule: pick the line by the perpendicular axis only, then pick the position by the along axis only.
  - Choosing the inline neighbour by *largest end* and *smallest start*, not by sorted adjacency, is exactly what makes CE3 (nested boxes) safe.
- Spec: CSSOM View `caretPositionFromPoint` (https://drafts.csswg.org/cssom-view/#dom-document-caretpositionfrompoint, section 5) returns null "if at the coordinates x,y … no text insertion point indicator would have been inserted". It leaves the "nearest" choice to the UA. CONFIRMED that the spec text I read covers only the first steps; the rest was truncated.

#### A5. Poppler `TextOutputDev` (used by Evince and others). CONFIRMED

- poppler/TextOutputDev.cc, freedesktop poppler master @ `0ca5d674c90d`. The selection is a rectangle between the two points.
- `TextPage::visitSelection` (4874-4980) picks the nearest *block* for each point by Manhattan distance. It forces the first or last block when the point is beyond the page corners.
- `TextBlock::visitSelection` (4769-4872) picks the nearest *line* for each point by Manhattan distance `max(xMin-x,0)+max(x-xMax,0)+max(yMin-y,0)+max(y-yMax,0)` (4815-4823). It then decides the start by reading index, with y as the tie-break (4830-4836). Each end point is **clamped into the chosen line's box** (`fmax(p->xMin, fmin(p->xMax, x))`, 4856-4861).
- `TextLine::visitSelection` (4665-4767) selects chars whose centre `mid` lies between s1 and s2 (`XBetweenAB`).
- INFERRED: Manhattan distance lets horizontal closeness choose another line, which the owner rule forbids. Poppler gets away with it because blocks (columns) are separated first by layout analysis. The "clamp into chosen line" step is a good, testable idea.

#### A6. Okular `TextPage::textArea`. CONFIRMED

- core/textpage.cpp 277-560, KDE okular master @ `4a271b121142`.
- The documented algorithm (284-296, 322-349) is:
  - If a point is in a word, use that word.
  - For the **start** in empty space, take the first word in reading order that is not above the point and is to its right (case 3a, 425-471).
  - For the **end**, scan *backwards* for the last word not below the point and to its left (case 3b, 473-520).
  - Selection type 02 (start lower than end after swapping) uses `xdist + ydist` to word centres.
  - Points outside the page bounding box are clamped to it (case 1b).
- INFERRED: start-snaps-forward plus end-snaps-backward is the "inward" rule. An empty-space endpoint never adds a word it has not reached. The Manhattan fallback in type 02 can still let x pick a row.

#### A7. pdfminer.six layout analysis (`LAParams`). CONFIRMED

pdfminer/layout.py, master @ `a18de2a9c479`.
- `line_overlap` defaults to 0.5. Two chars are on the same line when `voverlap > min(height) * line_overlap` **and** `hdistance < max(width) * char_margin` (default 2.0). See `group_objects` 703-778.
- The check is between *consecutive* objects only, not seeded from one tall object.
- `line_margin` (0.5) groups lines into boxes through `find_neighbors` (513-536). Neighbours must be the same height within tolerance and left-, right- or centre-aligned.
- `boxes_flow` (default 0.5, range -1..1) weights x against y when ordering text boxes (676-693).
- INFERRED:
  - Mado's current row test `overlap >= shorter * 0.5` is pdfminer's `line_overlap` without the `char_margin` adjacency condition, and it is measured against a seed instead of a neighbour. That is why a tall seed swallows two rows.
  - pdfminer also refuses "same height" for paragraph grouping, which is another guard against tall boxes.

#### A8. Tesseract / hOCR and OCRmyPDF

- hOCR 1.2 spec (https://kba.github.io/hocr-spec/1.2/), CONFIRMED:
  - `ocr_line` (§3.1.4) is a line of glyphs with `bbox` and optional `baseline` (§4.1: a polynomial; `baseline 0.015 -18` is slope and intercept).
  - `textangle` (§4.14) is the rotation of the text.
  - `ocr_carea` (§3.1.3) "should appear in reading order".
  - `order` (§4.11) gives an explicit reading order.
  - Tesseract-specific `x_size` and `x_descenders` are not in the spec. CONFIRMED that they are absent from the spec; that Tesseract emits them is UNCONFIRMED here, beyond OCRmyPDF consuming `line.x_size` and `line.x_descenders`.
- OCRmyPDF `src/ocrmypdf/fpdf_renderer/renderer.py` @ `86a5e723ea2b`, CONFIRMED:
  - Lines 30-32 say `# A line whose box reaches this far above the OCR engine's own line metrics is taken to be stretched by one word reaching into a neighbouring line.` with `STRETCHED_LINE_RATIO = 1.5`.
  - Lines 520-540: when the box height above the baseline is more than 1.5× the engine's own metrics, the renderer uses the metrics instead of the box.
  - The text layer is drawn invisible (text mode 3, 294-298) along each line's baseline, so selection is left to the PDF viewer (A1-A6).
  - INFERRED: this is direct evidence from a production OCR pipeline that **OCR line boxes get stretched into the neighbouring line**. Mado should expect tall Vision boxes that overlap a neighbouring row, and not let them define rows.
- Tesseract's internal textline finder: UNCONFIRMED (not read).

#### A9. Reading order: XY-cut and simple sort rules. CONFIRMED (where marked)

- Recursive XY-cut, Sanster/xy-cut `xycut.py` @ `3639c53b65f8`, lines 71-126, CONFIRMED:
  - It projects boxes on y and splits at empty runs.
  - For each horizontal band it projects on x. If x cannot split, it emits the band sorted by x; otherwise it recurses into each x chunk.
  - INFERRED: a tall box blocks every y-cut across its height. XY-cut therefore isolates it as its own column (x-cut), then the short lines beside it get y-cut into separate rows *inside* that column. That is the right structure for CE1 and CE2: rows are local to a column, and a tall box is a column, not a row.
- PaddleOCR `sorted_boxes` (tools/infer/predict_system.py 160-182, @ `dab3fe35379`), CONFIRMED: sort by (top-left y, x), then bubble-swap neighbours whose top-left y differ by `< 10` px when x is smaller. It is a fixed pixel threshold; it has no tall-box handling.
- Kraken, Surya, docTR, LayoutParser reading order: UNCONFIRMED (not read today).

#### A10. Apple VisionKit / Vision (documented behaviour only). CONFIRMED (docs JSON, developer.apple.com)

- `ImageAnalysisOverlayView` has `selectedText`, `selectedAttributedText` and `selectedRanges: [Range<String.Index>]` into `text: String` ("The text contents of the current image analysis").
- It also has `hasActiveTextSelection`, `resetSelection()`, `hasText(at:)`, `analysisHasText(at:)`, and `InteractionTypes.textSelection` ("enables text selection, copying, and translating").
- So Apple also models a selection as **ranges into one reading-order string**, the same model as Mado's `Position(line, offset)`.
- How Live Text resolves empty-space drags is **not documented**. UNCONFIRMED.
- `VNRecognizeTextRequest` and `VNRecognizedTextObservation` docs say nothing about result order. CONFIRMED that no ordering statement appears in the doc JSON I searched. So Mado must not assume Vision returns lines in row-major order. INFERRED.
- New in macOS 26: `RecognizedTextObservation.shouldWrapToNextLine`, "Whether the text continues on the next line". CONFIRMED (introducedAt 26.0). Mado targets macOS 14, so it is only usable behind an availability check.

#### A11. Screen-OCR tools

- **Text-Grab** (TheJoeFin/Text-Grab @ `f0345015dcab`, `Text-Grab/Views/GrabFrame.xaml.cs` 2192-2250), CONFIRMED. Selection is a **marquee rectangle**: every `WordBorder` (and PDF text line) whose rect `IntersectsWith` the drag rect is selected. A rect smaller than 10×10 is ignored (2196). There is no caret model and no gap rule.
- **NormCap and Capture2Text**: region-capture tools. I only read the NormCap README (@ `acaccb7604d5`), which describes no in-image caret selection. Behaviour UNCONFIRMED.
- **Textractor**: not read, UNCONFIRMED.

---

### B. Edge cases

See also the table after section D.

- **Tall/short mixed heights; a tall box beside two rows.**
  - MuPDF uses the glyph size, not the box, for the line band. That helps for PDF but not for OCR boxes.
  - OCRmyPDF detects stretched OCR lines (ratio 1.5).
  - XY-cut isolates tall boxes as columns.
  - pdfminer requires same-height neighbours for paragraphs.
  - Mado CE1 and CE2 are this case.
- **Superscripts, subscripts, drop caps.** MuPDF keeps chars on the line if `|base_offset| < 0.8` of the font size. pdfminer uses overlap > 0.5 of the *smaller* height. A drop cap is the CE1 shape: a big glyph beside two lines. For Vision line boxes, a drop cap may come back as its own observation (INFERRED).
- **Nested and overlapping boxes.** Blink picks the inline neighbour by extreme edge (`closest_child_before` = largest end), which is robust to nesting. Mado CE3 comes from adjacency in a `minX`-sorted list.
- **Columns and side-by-side labels.** Poppler and Okular rely on blocks/flows from layout analysis. MuPDF has an explicit `TODO: closest column?`. pdf.js limits jumps to the current span. Mado CE4 (`中文测试` | `SIDE`) is this case.
- **Tables.** Text-Grab has a table mode built on word borders. The others treat cells as blocks. Mado uses line observations, so table cells are just side-by-side lines in one row (INFERRED).
- **Rotated or skewed text.** MuPDF uses `line->dir` vectors throughout. Poppler uses `rot` 0-3. hOCR uses `textangle` and the `baseline` slope. Chromium has a vertical-text TODO. Mado has quarter turns and flips.
- **Vertical text.** MuPDF uses wmode. Blink uses the writing-mode converter. pdfminer uses `detect_vertical` and `LTTextLineVertical`.
- **RTL and mixed direction.** MuPDF swaps `ll`/`lr` for bidi-odd chars. Chromium flips "left of centre" for RTL. Poppler uses `primaryLR`. OCRmyPDF reorders RTL words visually.
- **Empty space above the first or below the last line.** Blink on Mac/Unix goes to the start of the first line or the end of the last. MuPDF goes to start or end via the band. Poppler and Okular clamp to the page bounding box. Chromium PDF leaves the selection unchanged.
- **Equal distances (ties).** MuPDF uses `<=`, so later lines win ties (239, 251). PDFium uses strict `<`, so the earlier char wins. Poppler breaks reading-index ties by y.
- **Pointer exactly on an edge.** Blink: the line bottom does not count (642). PDFium: `Contains` is inclusive. Mado: `CGRect.contains` excludes maxX/maxY (INFERRED from CoreGraphics semantics, UNCONFIRMED here).
- **Zero-size or degenerate boxes.** MuPDF skips zero-extent quads when highlighting (424-426). Poppler skips empty selections. OCRmyPDF rejects `bbox.height <= 0` (396-399).
- **Single line, no lines.** MuPDF returns 0. Okular returns an empty area when there are no words. Mado has `guard !lines.isEmpty`.
- **Many lines (performance).** Every engine I read is a linear scan per query (MuPDF, PDFium, Poppler). Mado's bridge detection is O(n³) naively. Precompute bridges and rows once per `lines` set, then each query is O(n) (INFERRED).
- **OCR noise and confidence.** None of the selection code reads confidence. Vision gives candidates with confidence; filtering before selection is a product choice (UNCONFIRMED best practice).
- **Hit-test tolerance and padding.** PDFium's tolerance box gives Chromium 20 pt. MuPDF's `hfuzz` and `vfuzz` apply to highlight merging only.

---

### C. How these projects test selection and hit-testing

- **PDFium** `fpdfsdk/fpdf_text_embeddertest.cpp` @ `a84323421e94`, `TEST_F(FPDFTextEmbedderTest, Text)`, lines 203-213. Table-like point probes on a real tiny PDF (`hello_world`):
  - `EXPECT_EQ(4, FPDFText_GetCharIndexAtPos(textpage, 42.0, 50.0, 1.0, 1.0))`.
  - -1 at (0,0) and at (199,199).
  - -1 for out-of-range coordinates (42, 1e7) and (-1, 50).
  - Bug-named tests exist (`Bug921`, `Bug782596`, `Bug1029`, …, `Bug431824298`), plus `TextVertical`, `TextHebrewMirrored`, `CharBoxForRotated45DegreesText` and `CharBoxForRotated90DegreesText`.
- **Blink** `third_party/blink/renderer/core/layout/layout_view_test.cc` @ `1ff7881be4bc`:
  - `TEST_P(LayoutViewHitTestTest, HitTestHorizontal)` (665+) uses a hand-built layout with an ASCII diagram in the comment (676-685). It asserts the exact `PositionWithAffinity` for named probe points: "Top-right corner (outside) of div" gives `(text2, 3)`, and "Top-right corner (outside) of span1" gives `(text2, 0)` (706-736).
  - Siblings: `HitTestVerticalLR`, `HitTestVerticalRL`, `FloatLeftLeft`…`FloatRightRight`, `TextAndInputsWithRtlDirection`. The test is parameterised (`TEST_P`) over legacy and NG configurations.
  - Web tests named in code comments: `editing/selection/click-in-margins-inside-editable-div.html`, `fast/writing-mode/flipped-blocks-hit-test-line-edges.html`, `editing/selection/last-empty-inline.html`, `editing/selection/caret-at-bidi-boundary.html`. Names CONFIRMED from comments; contents not read.
- **pdf.js** `test/integration/text_layer_spec.mjs` @ `60aefc5b51d5`. Real-browser (Firefox and Chrome) Puppeteer drags on a real PDF (`tracemonkey.pdf`):
  - `describe("doesn't jump when hovering on an empty area")` › `it("in a single page")` (627-678). It drags from `middlePosition` of one line to `belowEndPosition` (x = line end, y = 1.5 × height) of a later line through `moveInSteps(…, 20)` (151-159, 175-180). It expects `toHaveRoughlySelected("code sequences, records\nthem, and compiles them to fast native code. We call suc")`.
  - The custom matcher `toHaveRoughlySelected` (319-345) allows `TOLERANCE = 10` extra characters at each end.
  - Siblings: "across multiple pages", "with .markedContent" (per-char and per-word modes), "keeps selection when dragging outside the current page", "allows selecting within the link when going backwards".
  - INFERRED: these are path-dependent (stepped moves) because the pdf.js workaround keeps state (`prevRange`).
- **Okular**:
  - `autotests/parttest.cpp`: `PartTest::testSelectText` (307-340) does a real GUI drag at fractional page coordinates and compares the clipboard to `"Hola que tal"`.
  - `PartTest::testSelectTextMultiline` (342-405) is a regression test for **KDE bug 482249**. It goes from mid-line to the end of the line, down to the next line, then back left past the first line's start x, and compares the clipboard to `"cks!\nOf c"`.
  - `autotests/searchtest.cpp` `SearchTest::testTwoColumns` (408-428) uses **hand-built `NormalizedRect` fixtures** (words with explicit rects) to check that layout analysis detects two columns.
  - GUI tests `QSKIP` when CI cannot create windows.
- **PyMuPDF** `tests/test_textextract.py::test_extract1` (@ `772b775fe4c3`, lines 20-35) calls `pymupdf.get_highlight_selection(page, start=page.rect.tl, stop=page.rect.br)` with **no assertion**, which is a smoke test only. I found no MuPDF unit test for empty-space selection. CONFIRMED for the files read; UNCONFIRMED that none exists elsewhere.
- **Text-Grab** has `Tests/WordBorderTests.cs` and `Tests/GrabFrame*Tests.cs`. Names CONFIRMED from the tree; contents not read.
- **Property-based or fuzz tests for selection**: none found in any of the projects above. UNCONFIRMED that none exist. None of the requested properties ("full range = whole text", monotone, A→B = B→A, in-box selects that line) appears as an explicit property test in the files I read.

---

### D. Recommendation for Mado

#### D1. Why the three rounds kept failing (INFERRED, checked with a port)

`endpointOutsideBoxes` (lines 130-175) has three structural defects:

1. **Seeded row.** It chooses one seed by perpendicular distance, then makes the row "every box overlapping the seed by ≥ half the shorter height". A tall seed (CE1 `16`, CE2 `big`) overlaps both neighbouring rows, so the "row" merges two visual rows, and `rowEnd` / `row[0]` can be a line from the other row.
2. **Gap search by adjacency in a `minX`-sorted list.** With nesting (CE3: `short` inside `wide`), the pair (`short`, `C`) is examined. 350 lies between `short.maxX = 250` and `C.minX = 400`, so the gap logic runs on the wrong left neighbour. The fallback chain also lets `coordinate <= alongMin(row[0])` and `>= alongMax(rowEnd)` return lines from the merged second row.
3. **Direction from the seed index** (`seed > anchor!.line`), where the seed can be a bridge with an unrelated index.

I ported lines 130-175 (horizontal case) to Python and the port reproduces CE1 = "November\nMonday", CE2 = "\n" and CE3 = "wide\nshort" exactly. The port is in scratch at `/tmp/i688proto/current.py`, not in the repo.

#### D2. Algorithm (works in the text's own frame)

Work in **image-text coordinates** (u = along the line, v = perpendicular, y down): apply the inverse of `ImageTextGeometry` to the view point, so rotation and flips disappear from the rule. Today the code branches on `quarterTurnsHorizontal` and detects ascending char centres. INFERRED improvement; it also makes the transform-invariance test trivial.

```
precompute once per `lines`:
  B(i,j) := overlapV(i,j) > 0.5 * min(h_i, h_j)          // pdfminer line_overlap
  bridge(i) := exists j≠k≠i: B(i,j) && B(i,k) && !B(j,k)  // spans two rows that don't touch
  N := non-bridge lines (if empty: N := all lines)        // fallback, see proof note
  rows := connected components of N under B               // = equivalence classes, see below
  band(r) := [min v0, max v1] over members of r

position(p):                       // p already in text frame
  if some line box contains p: first such line by index; offset by u   // unchanged
  dv(r) := max(band.lo - p.v, 0, p.v - band.hi)
  R := rows with minimal dv        // usually one; ties -> resolve all, then pick below
  for each r in R:
    if some member m of r has m.u0 <= p.u <= m.u1:
        cand += (m*, offset(m*, p.u)) where m* minimises (dv to m's own box, index)
    else:
        L := member with max u1 among u1 < p.u   ->  cand += (L, count(L))   // end of left neighbour
        Rt := member with min u0 among u0 > p.u  ->  cand += (Rt, 0)        // start of right neighbour
  pick from cand:
    if all candidates are after the anchor  -> the earliest in reading order
    if all candidates are before the anchor -> the latest in reading order
    otherwise (straddles; only if Vision order disagrees with geometry)
                                            -> the candidate on the anchor's geometric side
                                               (u of anchor < p.u ? left : right)
  ties in reading order -> lower index
```

Why this matches the owner rule 「同一行内夹到离开的那段、行外按最近的行（先比垂直距离）」 (INFERRED):

- **Row by vertical position first.** The row is chosen only from `dv` to the row band. `p.u` is never consulted until a row is fixed, so horizontal closeness can never select another row.
- **On the anchor's row, a gap clamps to the anchor-side line.** The two gap candidates are the facing edges of the gap. The anchor's own line is either ≤ the left neighbour or ≥ the right neighbour in reading order, so "the candidate nearer the anchor" is the anchor-side one. This is Okular's inward snap and pdf.js's "limit the jump to the span being modified".
- **Cross-row drags.** Both candidates lie on one side of the anchor, so taking the nearer one means "stop before the gap" going forward and "start after the gap" going backward. This matches the existing tests `issue688ForwardDragIntoNextRowGapStopsBeforeGap` and `issue688DeviceReverseDragIntoUpperGapStartsAtSIDE`.
- **In-box hits and multi-line order unchanged.** The first branch is the current code; `selectedText` and `Position` ordering are untouched.

Why a box spanning two rows cannot merge them (provable, INFERRED):

- Among non-bridges, B is transitive. Suppose A~B and B~C but not A~C. Then B overlaps two lines that do not overlap each other, so B is by definition a bridge, which is a contradiction.
- So rows are exact equivalence classes, and no row contains two lines that fail to overlap. A tall box that touches two rows is a bridge and never seeds or joins a row. It can still be selected by an in-box hit.
- Non-emptiness of N: with plain intersection (threshold 0), the interval that ends first is never a bridge, because any two intervals overlapping it both contain its end point. With the 0.5 threshold this guarantee is lost, hence the fallback `N := all`.

Nested boxes are safe because the neighbours are chosen by extreme edges (`max u1` and `min u0`), as Blink does, not by list adjacency.

Prototype check (scratch, `/tmp/i688proto/proto.py`, not in the repo; Python, my own code):
- It passes the 5 counterexamples, the bridge-chain case and every row and device test shape in `Issue688SelectTextTests.swift` that I could model with synthetic boxes. That is 13 example cases, including CE1 at x 330 and 280, CE2, CE3, three-on-a-row, next-row margins, forward into the next-row gap, short overshoot, and side-by-side forward, reverse and reverse-from-lower-row.
- The device tests use real Vision boxes from `mixed.png`, which I could not run. I approximated them with synthetic boxes.
- One design iteration mattered. When bridges were allowed as gap candidates, the bridge-insertion property failed 63 of 4000 checks: the bridge's end is earlier in reading order than the anchor, so "nearest to anchor" straddled. Excluding bridges from outside-point resolution brought this to 0 over seeds 3, 4, 5 and 11.

#### D3. Test strategy that would have caught all five at once

1. **Keep a named, table-driven regression suite** (Swift Testing `@Test(arguments:)`). Each row has: name (CE1-price, CE2-tall, CE3-nested, CE4-side-by-side, CE5-* margins, overshoot, reverse, rotated), boxes in view coordinates, anchor, drag point, expected text and expected `extent`. This is the PDFium and Blink style of hand-built geometry with exact expected positions.

2. **Seeded generated layouts.** Use SplitMix64 seeded from a fixed list, and print the seed and layout on failure; Swift has no seeded `RandomNumberGenerator` in the standard library, so write the small struct. The generator produces:
   - 1-4 rows of 1-3 lines with random widths, ±2 pt jitter, mixed heights 12/16/20 and gaps of 8-30 pt;
   - plus optional tall bridge lines (left, right or between columns, spanning 2-3 rows);
   - nested short lines inside wide ones;
   - side-by-side labels with 15-60 pt gaps.

   Endpoints are sampled at box edge ± ε (ε = 0.01 inside, 1 pt outside), in gaps, and in margins. Everything is pure geometry on `ImageTextSelection`, so 400 layouts × 10 drags runs in well under a second (INFERRED; the Python prototype runs 20 000 checks in seconds).

3. **Invariants to check.** The metamorphic ones need no oracle:

   | ID | Invariant | Catches |
   |---|---|---|
   | I1 | In-box: if p is in line i's box (first by index), then `extent.line == i` | regressions in the unchanged path |
   | I2 | **Edge continuity**: moving the endpoint from just inside any edge of line L to 1 pt outside it, with no other box within 1 pt, leaves the selected text unchanged once `\n` is removed | CE1, CE2 (1-2 pt past the line), CE5 overshoot |
   | I3 | **Bridge insertion**: adding a tall line left of all text, spanning every row, does not change `selectedText` for any drag whose anchor and endpoint lie right of it | CE1, CE2 (the cf71cc0e port failed 779 of 4000; recommended rule 0) |
   | I4 | **Nested insertion**: adding a short line inside a line H's u-range on H's row, right after H in order, does not change the result of a drag that ended at H's end | CE3 (the port failed 1854 of 4000; recommended rule 0) |
   | I5 | **Transform invariance**: for each `quarterTurns` 0-3 and each flip, mapping the boxes and drag points through `ImageTextGeometry` gives identical `selectedText` | rotated-image bugs (CE5), the `horizontal` branch |
   | I6 | Row safety: `extent.line` belongs to the row chosen by vertical distance (oracle = an independent O(n²) row builder in the test target), or is an in-box hit | the whole failure class |
   | I7 | Contiguity: `selectedText` equals `fullText[gidx(lower)..<gidx(upper)]`, with full text = lines joined by `\n` | slicing bugs |
   | I8 | Full range: anchor at the start of the first line and drag below-right of everything gives the whole text, provided the input is row-major | ordering bugs |
   | I9 | Symmetry for in-box endpoints only: A→B and B→A give the same text. Do **not** assert this for gap endpoints; the owner rule is anchor-dependent by design | |
   | I10 | Degenerate inputs (no lines, one line, empty text, zero-width box, duplicate boxes) never crash and give a deterministic result | |

   - I2 alone did not catch the cf71cc0e port on the plain generator (0 failures). It needs bridges and nesting in the generator. That is why I3 and I4 must be explicit.
   - The oracle in I6 shares the spec with the implementation. The metamorphic invariants I2-I5 do not, so they are the independent check.

4. **Device fixture (existing)**: keep `mixed.png` and `mixed-orientation-6.jpg` tests, because they exercise real Vision boxes (order and heights) that the generator cannot predict.

#### D4. Uncertain or needs a decision

- **Vision's line order** is undocumented (A10). The "straddle" branch exists for when within-row order disagrees with geometry. Mado could instead sort lines into rows × u order once and use that as reading order. That changes "multi-line reading order unchanged", so the owner would have to decide.
- **The 0.5 overlap threshold** is pdfminer's default. With real Vision boxes, adjacent rows may overlap more because of descenders, which makes false bridges. A per-layout check (OCRmyPDF's 1.5× ratio to the median line height) could be an alternative bridge test. Not validated on device.
- **Above the first line and below the last.** Blink on Mac goes to the start or end of the line; MuPDF uses the band. Mado today (and this proposal) keeps using u. The owner has not ruled on this.
- **Ties at exactly the gap midpoint between two rows.** The proposal resolves them toward the anchor (select less). That is my choice, not the owner's.
- **Apple Live Text behaviour** on empty-space drags is undocumented. I could not check it from documentation.

---

### Edge case → who handles it → how → relevant to Mado

| Edge case | Who handles it | How | Relevant to Mado |
|---|---|---|---|
| Tall box spanning two rows | OCRmyPDF; XY-cut; MuPDF | stretched-line ratio 1.5 to metrics; tall box blocks y-cuts and becomes a column; band = glyph size, not box | **yes** (CE1, CE2) |
| Nested boxes on a row | Blink | inline neighbour by largest end and smallest start | **yes** (CE3) |
| Pointer in a gap on the anchor's row | Okular; pdf.js | start snaps forward, end snaps backward; jump limited to current span | **yes** (CE4) |
| Pointer in empty space while dragging | Chromium PDF | extent frozen, selection unchanged | yes (alternative, path-dependent; not recommended) |
| Pointer between rows | Blink; MuPDF | block-offset-only line choice; nearest band by \|vdist\| | **yes** (CE5 margins) |
| Pointer past a line end on the same band | MuPDF; Poppler | "extended line" picks by horizontal distance; clamp into chosen line | yes (Mado clamps to the row end) |
| Above first / below last line | Blink (Mac); MuPDF; Poppler/Okular | start or end of line; band start/end; clamp to page bbox | yes (owner decision open) |
| Columns | Poppler/Okular blocks; XY-cut; MuPDF TODO | layout analysis first | partly (side-by-side labels only) |
| Superscript, subscript, drop cap | MuPDF; pdfminer | baseline offset < 0.8 font size; overlap > 0.5 × min height | yes (drop cap = CE1 shape) |
| Rotated or skewed | MuPDF dir vectors; Poppler rot; hOCR textangle/baseline | per-line direction | yes (quarter turns and flips) |
| Vertical text | MuPDF wmode; Blink writing modes; pdfminer `detect_vertical` | logical block/inline axes | yes (rotated images); native vertical CJK UNCONFIRMED for Vision |
| RTL / bidi | MuPDF bidi swap; Chromium RTL flip; OCRmyPDF visual order | swap edge comparison | yes (Hebrew/Arabic OCR); not covered by current tests |
| Ties | MuPDF `<=` (later wins); PDFium `<` (earlier wins); Poppler y tie | fixed order | yes (define and test) |
| Exactly on an edge | Blink (bottom excluded); PDFium inclusive | half-open vs closed | yes (`CGRect.contains` semantics) |
| Zero-size boxes | MuPDF; OCRmyPDF; Poppler | skip or reject | yes |
| No lines / single line | MuPDF; Okular | return 0 / empty | yes (already guarded) |
| Many lines | all | linear scan per query | yes (precompute rows once) |
| Hit tolerance | PDFium/Chromium | 20 pt tolerance box | maybe (not in owner rule) |
| OCR confidence / noise | none in selection code | n/a | product choice |
| Marquee (rectangle) selection | Text-Grab | rect intersects word boxes | no (different interaction) |

---

### Sources (all read 2026-11-16)

- MuPDF `source/fitz/stext-search.c` and `stext-device.c` @ 131220bea34f854eecefbf849257aec515ca1450: https://github.com/ArtifexSoftware/mupdf/tree/131220bea34f854eecefbf849257aec515ca1450/source/fitz
- PDFium `core/fpdftext/cpdf_textpage.cpp` and `fpdfsdk/fpdf_text_embeddertest.cpp` @ a84323421e94f484faca52dd9d027934eba42ab8: https://github.com/chromium/pdfium
- Chromium `pdf/pdfium/pdfium_engine.cc`, `pdf/pdfium/pdfium_page.cc`, `third_party/blink/renderer/core/layout/inline/inline_cursor.cc`, `third_party/blink/renderer/core/layout/layout_view_test.cc` @ 1ff7881be4bc00172e9c8a095398b3bde6b4e824: https://github.com/chromium/chromium
- pdf.js `web/text_layer_builder.js`, `web/text_layer_builder.css`, `test/integration/text_layer_spec.mjs` @ 60aefc5b51d526e39bbcbae1c6cb760763b65b0a; commit ea43bb43fb: https://github.com/mozilla/pdf.js
- Poppler `poppler/TextOutputDev.cc` @ 0ca5d674c90d7689de11da8f0c08d6dd3329cda5: https://gitlab.freedesktop.org/poppler/poppler
- Okular `core/textpage.cpp`, `autotests/parttest.cpp`, `autotests/searchtest.cpp` @ master 4a271b121142acab76c20137dd7782e81c2844f3: https://invent.kde.org/graphics/okular
- pdfminer.six `pdfminer/layout.py` @ a18de2a9c479b4c847538500017b449ddaec177e: https://github.com/pdfminer/pdfminer.six
- OCRmyPDF `src/ocrmypdf/fpdf_renderer/renderer.py` @ 86a5e723ea2b612e8df4a647056b0ebf3b3c97a5: https://github.com/ocrmypdf/OCRmyPDF
- hOCR 1.2 spec: https://kba.github.io/hocr-spec/1.2/
- Sanster/xy-cut `xycut.py` @ 3639c53b65f8d06927527ee5873fc8c21e647efa: https://github.com/Sanster/xy-cut
- PaddleOCR `tools/infer/predict_system.py` @ dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf: https://github.com/PaddlePaddle/PaddleOCR
- Text-Grab `Text-Grab/Views/GrabFrame.xaml.cs` @ f0345015dcabf572453568addfcecc64abfc1c16: https://github.com/TheJoeFin/Text-Grab
- PyMuPDF `tests/test_textextract.py` @ 772b775fe4c32a05900753ae434505d368b06f6f: https://github.com/pymupdf/PyMuPDF
- Apple docs: https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview (and `selectedRanges`, `text`, `hasText(at:)`), https://developer.apple.com/documentation/vision/vnrecognizetextrequest, https://developer.apple.com/documentation/vision/recognizedtextobservation/shouldwraptonextline
- CSSOM View `caretPositionFromPoint`: https://drafts.csswg.org/cssom-view/#dom-document-caretpositionfrompoint
- NormCap README @ acaccb7604d548a56d80a91209647026ec1a9165: https://github.com/dynobo/normcap

Not read (UNCONFIRMED): Tesseract internals, Kraken, Surya, docTR, LayoutParser, Capture2Text, Textractor, WebKit and Gecko caret-from-point, Blink web-test file contents, Text-Grab test contents.

---

# Appendix B — Codex researcher note (verbatim; source: Report-Task i688-selection-codex)


### Answer

- **INFERRED:** Use two stages: choose a fixed visual row by perpendicular distance, then choose a caret within that row. Browser engines provide precedent for this separation, but their existing layout lines are richer than Mado’s OCR rectangles. [Blink, `inline_cursor.cc:605–840`][Blink]
- **CONFIRMED:** Mado currently chooses a seed rectangle, then collects rectangles overlapping that seed. A tall seed can therefore collect two separate rows. [M1, lines 138–157][M1]
- **INFERRED:** Replace seed-dependent grouping with a conservative, precomputed row partition; ambiguous tall spanners must never merge rows or enlarge their selection bands. [M1, lines 130–174][M1]; [PDFBox, lines 500–502][PDFBox]
- **INFERRED:** Within a row, use the union of horizontal intervals and retain each exposed boundary’s owning line. This addresses nested boxes and anchor-side gap clamping. [M1, lines 159–174][M1]; [Brief, lines 15–18][Brief]
- **INFERRED:** Verify against an independent oracle over generated layouts, exact boundary sweeps, all supplied regressions, and frozen real Vision results. Tesseract supplies a useful exhaustive-generation precedent. [Tesseract tests, lines 172–206, 518–533][TessTests]
- **UNCONFIRMED:** Rectangles alone cannot establish every true semantic row, and Apple does not publish Live Text’s snapping algorithm. The recommendation below distinguishes mathematical guarantees from layout assumptions. [Apple, Overview][Apple]; [Mado model, lines 68–76][MModel]

### Scope and evidence labels

**CONFIRMED** means a primary source was directly read during this investigation, by the main researcher or a research subagent. **INFERRED** means a deduction or proposed design, rather than an upstream guarantee. **UNCONFIRMED** identifies an unresolved implementation, test, or behavioral question. Citations identify the source file and lines, or an official documentation section.

This report uses the specified brief and local Mado files. It does not use the other researcher’s note or either prohibited auditor directory. Local files are cited as the inspected working-tree contents; their correspondence to commit `cf71cc0e` was not independently checked because git was prohibited.

### A. Algorithms

#### A1. Mado’s actual model and behavior

**CONFIRMED:** `TextRecognitionLine` contains a string, one normalized rectangle, and optional per-`Character` rectangles. It has no row ID, block ID, baseline, writing-direction field, or confidence field. [Mado model, lines 68–76][MModel]

**CONFIRMED:** `Position` is `(line: Int, offset: Int)`, ordered first by the original array index. Copying slices the first and last strings and joins every intervening array entry with `"\n"`. Visual rows are not independently represented in the copied range. [M1, lines 37–58][M1]

**CONFIRMED:** `begin` requires an actual rectangle hit; a drag may resolve outside all boxes. Overlapping exact hits choose the first line in array order. Character offsets use provided boxes when their count matches the string’s `Character` count; otherwise, the implementation divides the line rectangle uniformly. [M1, lines 65–75, 99–126][M1]

**CONFIRMED:** Outside-box resolution ranks rectangles by perpendicular interval distance, then center distance, height, and index. It subsequently constructs a row by overlap with the winning seed, sorts that row along the text axis, and applies anchor/direction rules. [M1, lines 130–174][M1]

**INFERRED:** The seed ranking and row grouping interact badly: a tall rectangle can win because it contains the pointer’s perpendicular coordinate, then admit two distinct short rows. Removing transitive overlap chaining alone does not remove this failure. [M1, lines 138–157][M1]; [Brief, lines 15–16][Brief]

**CONFIRMED:** The upstream provider separately computes reading order using overlapping rectangles, comparing a candidate with the last entry in each accumulated row, then sorting each row left to right. This is another layout heuristic, independent of drag resolution. It currently requests Chinese Simplified and US English recognition. [Provider, lines 12–36, 73–76][MProvider]

**INFERRED:** The endpoint fix should retain original array indices and serialization. Reworking column order, RTL, or provider grouping would change additional behavior and requires separate acceptance criteria. [Brief, line 10][Brief]; [M1, lines 37–58][M1]

#### A2. PDF engines and extraction libraries

| Implementation | Findings |
|---|---|
| MuPDF 1.25.0 | **CONFIRMED:** Selection traverses existing blocks and lines. It derives a baseline-oriented frame from line direction and character quads, selects a closest line, then a character boundary. Within an extended line band it considers line-end distances; outside it compares perpendicular midline distance. The code contains a closest-column TODO. It is not an OCR overlap-grouping algorithm. [`stext-search.c:74–214`][MuPDF] |
| MuPDF range, copy, highlight, snap | **CONFIRMED:** Both endpoints map independently to scalar positions; reversed endpoints are swapped before enumeration. Copy and highlight share range enumeration; snapping expands to character/word/line boundaries. No anchor-side whitespace policy appears in this path. [`stext-search.c:224–335, 397–460`][MuPDF] |
| MuPDF extraction | **CONFIRMED:** Extraction has distinct baseline, spacing, and paragraph thresholds, handles writing direction, baseline displacement, overlapping motion, synthetic spaces, and duplicate text used for fake bold. These operate on glyphs before selection. [`stext-device.c:84–87, 563–716`][MuPDFDevice] |
| PDFium, commit `012fe571c9fe430da68dbcd2f5ba21758db0ae15` | **CONFIRMED:** `GetIndexAtPos` returns the first exact containing character rectangle. Otherwise it considers tolerance-expanded rectangles and minimizes the sum of distances to their nearest x/y edges; strict comparison retains the earlier tolerant candidate on ties. No eligible hit returns `-1`. [`cpdf_textpage.cpp:415–447`][PDFium] |
| PDFium applicability | **INFERRED:** This is a character-hit primitive, not a full caret policy. Its combined x/y metric must not replace Mado’s vertical-first rule. [`cpdf_textpage.cpp:415–447`][PDFium]; [Brief, line 10][Brief] |
| Poppler 22.04.0 | **CONFIRMED:** Page selection searches nearest blocks, then nearest lines using Manhattan rectangle distance, with corner/outside-content handling. Line/word selection tests character advance midpoints and accounts for rotated axes. Source was read from Google’s tagged vendored mirror because official GitLab access failed. [`TextOutputDev.cc:4850–5212`][Poppler] |
| Poppler applicability | **INFERRED:** Manhattan distance allows horizontal distance to affect which line wins, so it is not a suitable oracle for the owner rule. [`TextOutputDev.cc:5034–5044`][Poppler] |
| Okular v24.12.0 | **CONFIRMED:** `TextPage::textArea` implements two-cursor selection over text entities. It handles empty content, clamps to content bounds, searches exact containing entities, and uses different candidate searches for forward and reverse selection. Some reverse cases use x+y center distance; endpoints are subsequently normalized into text order. [`core/textpage.cpp:277–543`][Okular] |
| Okular normalization | **CONFIRMED:** Text entities are NFC-normalized; combining marks can merge with a preceding entity and union its area. This concerns representation, not nearest-row selection. [`core/textpage.cpp:185–201`][Okular] |
| PDFBox 3.0.3 | **CONFIRMED:** `TextPositionComparator` compares direction-adjusted coordinates and treats certain overlapping vertical extents or nearly equal y positions as the same row for x ordering. `PDFTextStripper` explicitly says this comparator is not transitive and includes a sorting fallback. [`TextPositionComparator.java:32–68`][PDFBoxComparator]; [`PDFTextStripper.java:494–510`][PDFBox] |
| PDFBox layout details | **CONFIRMED:** Line-separation code discusses superscripts/subscripts and regressions caused by using accumulated line extents. Bidi normalization is a separate operation. [`PDFTextStripper.java:622–640, 1755–1784`][PDFBox] |
| pdfminer.six 20240706 | **CONFIRMED:** `LAParams` expresses character overlap and spacing relative to character dimensions, line margins relative to line dimensions, optional vertical detection, and a reading-flow preference. Character grouping compares overlap and distance; line grouping uses spatial neighbors; text-box grouping uses a distance heap and checks intervening objects. [`layout.py:53–97, 752–952`][PDFMiner] |
| pdfminer order | **CONFIRMED:** With `boxes_flow=None`, horizontal boxes sort by descending y then x; vertical boxes by descending x then y. Otherwise hierarchical grouping supplies ordering indices. [`layout.py:954–984`][PDFMiner] |
| Extraction-library applicability | **INFERRED:** PDFBox/pdfminer grouping is evidence about layout assumptions, not a pointer/anchor contract. In particular, pairwise overlap must not be assumed to define a row equivalence relation. [PDFBox, lines 500–502][PDFBox]; [pdfminer, lines 752–984][PDFMiner] |

#### A3. pdf.js and browser caret positioning

**CONFIRMED:** pdf.js v4.10.38 uses browser DOM selection over positioned text spans. Its text layer retains incoming text-item order, applies transforms, sets span direction, supports vertical text placement, and creates line-break elements for `hasEOL`. The layer has a 100,000-div processing threshold. [Text layer, lines 251–305, 347–349, 385–392][PDFJSText]

**CONFIRMED:** pdf.js explicitly addresses selection jumps in empty space: it moves an end-of-content element next to the span whose selection boundary is changing, using the previous range to determine the moving end. This is direct evidence that whitespace dragging requires more than generic geometric proximity. [Builder, lines 222–292][PDFJSBuilder]

**CONFIRMED:** Blink’s inspected implementation chooses an existing layout line using the logical block axis, then searches inline descendants. It distinguishes before/after-line cases, excludes the line’s bottom edge in its interval test, skips floating boxes as outside-hit snap targets, and handles bidi at line boundaries. [Chromium commit `4d54f0a8e47abbf6d5d401c7d09a43ec2994d130`, `inline_cursor.cc:605–840, 883–934`][Blink]

**CONFIRMED:** WebKit’s document API first hit-tests a renderer, then asks it for a position. Its inspected inline-layout helper chooses a line by logical block position, then a closest inline box; it handles flipped layout, vertical writing, page breaks, and above/below-line behavior. [WebKit commit `3025232f837965ab567f9de4330bb82b29866cfd`, `Document.cpp:2152–2225`][WebKitDocument]; [`RenderBlockFlow.cpp:3296–3375`][WebKitFlow]

**CONFIRMED:** Gecko’s inspected path chooses a containing/nearest line before an inline frame. Between lines, equal block-axis distances select the next line; inline-distance ties select the preceding candidate. It skips empty/unselectable/generated frames, and its generic helper warns about overlapping frames. [Firefox `FIREFOX_132_0_RELEASE`, `nsIFrame.cpp:5116–5242, 5283–5318`][Gecko]

**INFERRED:** The transferable pattern is “block-axis row, then inline-axis caret.” These engines already possess layout line containers; none of the inspected paths proves that overlapping OCR rectangles can safely create those containers. [Blink, lines 634–744][Blink]; [Mado model, lines 68–76][MModel]

**CONFIRMED:** CSSOM View specifies viewport/null handling, transforms, and shadow-root retargeting for `caretPositionFromPoint`, but explicitly leaves exact hit-testing details outside its scope. It does not standardize a nearest-OCR-row policy. [CSSOM View §5, method algorithm and hit-testing note][CSSOM]

#### A4. OCR applications, text layers, and reading-order systems

| Project | What the primary source establishes |
|---|---|
| Tesseract 5.5.0 / hOCR | **CONFIRMED:** hOCR emits existing block → paragraph → line → word structure, paragraph/word direction, line baseline/height metadata, and word confidence. Rotated non-upright text emits `textangle`; baseline emission is omitted there because of specification ambiguity. [`hocrrenderer.cpp:43–60, 91–105, 208–305`][TessHOCR] |
| Tesseract order | **CONFIRMED:** `ResultIterator` exposes logical reading order, including RTL/minor-direction runs and complex words. **UNCONFIRMED:** The original segmentation pipeline and interactive pointer behavior were not fully traced. [`resultiterator.h:49–77, 105–132`][TessIterator] |
| OCRmyPDF v16.10.4 | **CONFIRMED:** It renders selectable invisible PDF text from hOCR lines and words, using paragraph direction, line-local rotation/baseline transforms, and stretched explicit spaces. It suppresses word separators for specified CJK languages, skips unusable line/word data, and leaves interactive selection to a PDF viewer. [`_hocr.py:186–365, 405–459`][OCRmyPDF] |
| docTR v0.11.0 | **CONFIRMED:** It straightens rotated boxes, sorts using position normalized by median height, groups using distance from the accumulating line’s mean center with a half-median-height threshold, and splits large horizontal gaps into sublines. Optional geometric clustering builds blocks. [`builder.py:42–212`][DocTR] |
| docTR applicability | **INFERRED:** Normal-size/center evidence is preferable to letting an arbitrarily tall box alone define row membership. However, docTR’s running-center heuristic is not a proof against arbitrary bridges or nested boxes. [`builder.py:115–139`][DocTR] |
| Kraken, commit `17c8cef65a80ac93848ab91aac798fd3c770edd3` | **CONFIRMED:** Geometric reading order builds pairwise precedence and topologically sorts it. It supports left-to-right/right-to-left column direction; polygonal order handles regions atomically and orders their lines separately. These are reading-order operations. [`segmentation.py:85–170, 845–903`][Kraken] |
| Surya v0.13.1 | **CONFIRMED:** Layout output includes box position in reading order, class, confidence, and polygon. Official documentation evaluates reading order by correctly ordered box pairs and warns of noisy labels. **UNCONFIRMED:** No anchor/caret policy was established. [`README.md:197–219, 432–440`][Surya] |
| LayoutParser v0.3.4 | **CONFIRMED:** Its official example explicitly partitions text into columns by center location, sorts each column by y, then concatenates left followed by right. This is example-specific page-order logic. [`index.rst:97–128`][LayoutParser] |
| XY-cut / recursive XY-cut | **CONFIRMED:** PdfPig v0.1.11 recursively cuts word groups using horizontal/vertical whitespace projections and dominant font dimensions, with termination/retention handling. **INFERRED:** This can inform upstream block/column partitioning, but does not define an empty-space caret. [`RecursiveXYCut.cs:103–314`][XYCut] |
| NormCap v0.5.9 | **CONFIRMED:** It OCRs a captured image region, consumes Tesseract TSV words, removes blank/missing text, and reconstructs line breaks from block/paragraph/line identifiers. It is not the same interaction as dragging a caret over an existing text layer. [`recognize.py:16–42`][NormCap]; [`structures.py:130–165`][NormCapStructure] |
| Windows Text-Grab, commit `f0345015dcabf572453568addfcecc64abfc1c16` | **CONFIRMED:** It obtains lines from WinRT OCR and unions word rectangles for line bounds. GrabFrame selects words by intersection with a drag rectangle, with small-selection toggling behavior. This is rectangle selection rather than Mado’s linear `(line, offset)` range. [`WinRtOcrLinesWords.cs:8–59`][TextGrabModel]; [`GrabFrame.xaml.cs:2190–2230, 4326–4343`][TextGrab] |
| Capture2Text | **CONFIRMED, official docs only:** Standard capture selects a rectangle. Separate line capture selects the line closest to the pointer; forward line capture starts near a character and proceeds forward. Settings cover deskew and Chinese/Japanese orientation. **UNCONFIRMED:** Exact distance metric, ties, tall-box policy, and tests were not verified from source. [Official §§Standard Capture, Text Line Capture, Forward Text Line Capture, Settings][Capture2Text] |
| Textractor | **CONFIRMED:** Artikash/Textractor v5.2.0 is a Windows text-hooking application, not an image-OCR selection implementation. [`README.md:7, 44–50`][Textractor] **UNCONFIRMED:** The brief may mean the Sailfish OCR application `skvark/Textractor`; its pinned caret implementation was not established. Its unpinned README is not used as algorithm evidence. |

#### A5. Apple VisionKit

**CONFIRMED:** Apple documents `ImageAnalysisOverlayView` as supplying text selection and copy/look-up interaction over an analyzed image. It exposes selected text, selected attributed text, point-level text availability, and image-area configuration through a tracking image view or delegate. [Official Overview, Configure the interface, Accessing text information][Apple]

**UNCONFIRMED:** Apple’s documentation does not reveal its row grouping, whitespace snapping metric, tall-box handling, exact ties, anchor semantics, or internal test suite. “Match Live Text’s algorithm” cannot be a source-backed implementation requirement from this page. [Same official API documentation][Apple]

### B. Edge cases and their implications

**INFERRED:** Three concerns must be evaluated separately: OCR/layout reconstruction, endpoint mapping, and logical text serialization. A successful extraction test does not prove correct empty-space dragging, and a correct endpoint does not repair an already interleaved reading order. [M1, lines 50–58, 99–174][M1]; [OCRmyPDF, lines 186–254][OCRmyPDF]

**INFERRED:** Tall observations, drop caps, superscripts, and mixed font sizes are especially dangerous when full rectangle height substitutes for a text baseline. Tesseract exposes richer height/baseline information; PDFBox explicitly documents line-height-related regressions. Mado’s inspected line model lacks those metadata. [Tesseract renderer, lines 91–105][TessHOCR]; [PDFBox, lines 622–640][PDFBox]; [Mado model, lines 68–76][MModel]

**CONFIRMED:** The Mado provider obtains the top candidate and per-`Character` boxes but does not transfer candidate confidence into `TextRecognitionLine`. [Provider, lines 99–114][MProvider]

**INFERRED:** A confidence threshold therefore cannot simply be inserted into `endpointOutsideBoxes` using the present model. Filtering observations would also affect reading order and copied text, beyond the requested endpoint correction. [Mado model, lines 68–76][MModel]; [Brief, line 10][Brief]

**INFERRED:** Rotation of a horizontal line and genuine vertical writing are different problems. Mado’s quarter-turn geometry supports the former; the inspected model does not explicitly describe vertical-CJK reading direction or mixed bidi runs. [M1, lines 13–32, 120–128][M1]; [Mado model, lines 68–76][MModel]

**UNCONFIRMED:** There is no verified universal tie, rectangle-edge, or empty-margin convention shared by these projects. Blink and Gecko already differ in documented implementation details, and CSSOM leaves hit testing unspecified. [Blink, lines 605–840][Blink]; [Gecko, lines 5116–5242][Gecko]; [CSSOM §5][CSSOM]

### C. Concrete tests and transferable strategies

#### C1. Tests read in primary sources

| Project / concrete test | What it asserts |
|---|---|
| Mado: `issue688ReadingOrderAndPartialCharacterRanges` | **CONFIRMED:** Handmade lines produce exact partial text `"ello\nWor"`; clearing removes selection; beginning away from text fails. [M2, lines 8–23][M2] |
| Mado: price/tall tests | **CONFIRMED:** `issue688PriceLayoutKeepsUpperLineAtBothOvershoots` tests y=12; `issue688TallLineDoesNotPullLowerOvershootToUpper` tests y=55. They do not test the brief’s nearby y=21/y=62 counterexamples. [M2, lines 181–200][M2]; [Brief, lines 15–16][Brief] |
| Mado: nested interval coverage | **CONFIRMED:** `issue688RowEndUsesLargestMaxX` has wide + nested short boxes, but no following `C` box. The brief’s additional `C` creates an interior gap rather than an outer-row overshoot. [M2, lines 213–220][M2]; [Brief, line 17][Brief] |
| Mado: device fixture tests | **CONFIRMED:** Tests cover Chinese/SIDE gaps, reverse dragging, outer overshoot, transformed geometry, and oriented image fixtures. They call the real provider at runtime. This report did not run them. [M2, lines 47–138, 233–247][M2] |
| PDFium: `FPDFTextEmbedderTest.Text` | **CONFIRMED:** On `hello_world.pdf`, `(42,50)` with `(1,1)` tolerance resolves to character 4; several outside/invalid coordinates resolve to `-1`. [`fpdf_text_embeddertest.cpp:189–198`][PDFiumTests] |
| PDFium: `TextVertical`, `TextHebrewMirrored` | **CONFIRMED:** Real PDFs check vertical character origins/boxes and an exact Hebrew code-point sequence. These are geometry/extraction tests, not anchor-gap tests. [`fpdf_text_embeddertest.cpp:259–315`][PDFiumTests] |
| pdf.js: `in a single page`, `across multiple pages`, `allows selecting within the link when going backwards` | **CONFIRMED:** Browser integration tests drag real PDF text and inspect resulting selection, including backwards and multipage cases. [`text_layer_spec.mjs:114–258`][PDFJSTests] |
| pdf.js: `doesn't jump when moving selection` | **CONFIRMED:** Moves a selection caret below a line and farther horizontally, checking the selected end text remains consistent. Its helper permits surrounding-character slack; that tolerance should not be copied into Mado’s exact regression assertions. [`text_layer_spec.mjs:58–80, 323–404`][PDFJSTests] |
| Blink: `click-in-margins-inside-editable-div.html` | **CONFIRMED:** Coordinate tables over fixed-font lines check exact caret markers under multiple platform editing behaviors, including margins, padding, and borders. [Lines 17–145][BlinkMargins] |
| Blink: `PositionForPointInChildVerticalRTL` | **CONFIRMED:** Vertical-rl/RTL content resolves to expected logical offsets 2, 1, and 0, including affinity checks. [`inline_cursor_test.cc:975–1007`][BlinkTests] |
| Blink: `PositionForPointInChildBlockChildren` | **CONFIRMED:** A regression linked to Chromium issue 1096110 checks resolution into an inline block containing block children. [`inline_cursor_test.cc:1009–1018`][BlinkTests] |
| WebKit: `caret-at-bidi-boundary.html` | **CONFIRMED:** Sweeps x pixel by pixel, checking collapsed selection and expected logical offset transitions for mixed Hebrew/Latin/numeric content. One fixture documents a known wrong offset, so the file is not proof of universal bidi correctness. [Lines 16–31, 48–89][WebKitTests] |
| PDFBox: `BidiTest.testSorted`, `testNotSorted` | **CONFIRMED:** Compare positional-sort and unsorted extraction with expected text files, normalizing whitespace. These are extraction goldens. [`BidiTest.java:61–81, 112–178`][PDFBoxTests] |
| pdfminer: `test_parent_with_wrong_bbox_returns_non_empty_neighbour_list` | **CONFIRMED:** Handmade lines, including one outside its parent bounds, must yield two text boxes. [`test_layout.py:16–33`][PDFMinerTests] |
| pdfminer: `test_find_neighbors_horizontal` and vertical counterpart | **CONFIRMED:** Exact neighbor lists include aligned lines and reject wrong-height/width or misaligned candidates. [`test_layout.py:36–113`][PDFMinerTests] |
| pdfminer: `test_pdf_with_empty_characters_horizontal` / `_vertical` | **CONFIRMED:** Issue-449 real-PDF regressions expect three text boxes, with vertical detection enabled in the vertical case. [`test_layout.py:116–148`][PDFMinerTests] |
| Tesseract: `TextlineOrderSanityCheck` | **CONFIRMED:** Enumerates all \(4^7\) seven-word direction sequences in both LTR/RTL contexts; the helper checks every word index occurs exactly once after removing direction markers. This is exhaustive ordering coverage. [`resultiterator_test.cc:172–206, 518–533`][TessTests] |
| Tesseract: `VerifyIteratorText`, `EasyTest` | **CONFIRMED:** Reconstruct text at different iterator hierarchy levels and compare against whole-page truth, using a real image fixture. [`resultiterator_test.cc:106–149, 258–286`][TessTests] |
| Tesseract: `SmallCapDropCapTest` | **CONFIRMED:** Real-image coverage expects one drop cap, subject to legacy-engine configuration. `SubSuperTest` is under `#if 0`, so it is not active coverage. [`resultiterator_test.cc:369–469`][TessTests] |
| docTR: `test_sort_boxes`, `test_resolve_lines` | **CONFIRMED:** Parameterized handmade boxes check complete index ordering/grouping for same-row, slight misalignment, multiple rows, diagonal placement, gaps, and rotated quadrilaterals. “Vertical” box arrangement is not evidence of vertical-CJK selection support. [`test_models_builder.py:187–230`][DocTRTests] |
| Kraken: `test_order_simple_over_under`, touching variants, left/right variants | **CONFIRMED:** Constructed polygons check exact order arrays, including touching boundaries and RTL direction; other cases use real-derived layouts. [`test_readingorder.py:49–206`][KrakenTests] |
| OCRmyPDF: `test_hocrtransform_matches_sandwich` | **CONFIRMED:** Compares two text-layer renderers using extracted word-set Jaccard similarity >0.99. **INFERRED:** This intentionally loses ordering/duplicate information and would miss Mado’s newline/row-selection errors. [`test_hocrtransform.py:75–102`][OCRmyPDFTests] |
| PdfPig: `RecursiveXYCutTests.GetBlocks` | **CONFIRMED:** A theory over a real two-column PDF checks block count and exact text after an additional x/y sort. It tests segmentation output, not every intended reading-order decision. [`RecursiveXYCutTests.cs:8–49`][XYCutTests] |
| NormCap: `test_normcap_ocr_testcases` | **CONFIRMED:** Drives region capture and checks output similarity; fixtures include two columns and mixed font sizes. [`test_normcap.py:12–50`][NormCapTests]; [`data.py:161–200`][NormCapData] |
| Text-Grab: `ParagraphDisplayText_KeepsLogicalWordSingleLine` | **CONFIRMED:** Ensures multiline display remains one logical word with a space in output. It does not test nearest-row endpoints. [`WordBorderTests.cs:10–21`][TextGrabTests] |
| Surya: `test_layout_topk` | **CONFIRMED:** Checks expected box count, labels, and class alternatives on one image. It does not test pointer mapping. [`test_layout.py:1–14`][SuryaTests] |

#### C2. Properties: established versus proposed

**INFERRED:** MuPDF’s independent endpoint resolution plus index normalization implies reversal symmetry for its resolved range. This is a deduction from code, not a verified upstream property-test name. [MuPDF, lines 224–239][MuPDF]

**CONFIRMED:** Tesseract tests whole-text reconstruction and exhaustive ordering properties. Those are valuable precedents, but neither is a test of OCR pointer monotonicity. [Tesseract tests, lines 106–206, 518–533][TessTests]

**UNCONFIRMED:** No verified upstream test was found asserting all four requested selection properties together: full-range copy, pointer monotonicity, reversed outside-gap drags, and inside-box dominance. Concrete selection tests for MuPDF, Poppler, Okular, Gecko, Capture2Text, and the intended OCR Textractor remain unverified in this investigation. The inspected implementations are linked in A; missing test evidence must not be interpreted as absence of tests.

**INFERRED:** For Mado, reverse symmetry must be limited to unambiguous in-box endpoints or already resolved logical positions. Beginning outside a box currently fails, and anchor-side gap clamping deliberately makes outside resolution depend on the anchor. [M1, lines 65–75, 103–111, 168–171][M1]

### D. Recommendation for Mado

#### D1. State the guarantee precisely

**INFERRED:** Define the desired guarantee as:

> For a pointer outside every text rectangle, select a fixed visual row using only perpendicular geometry. Then resolve the inline position within that row, respecting anchor-side gaps. A spanning rectangle cannot merge previously distinct row bands.

This formalizes the supplied owner rule without claiming to recover semantic rows perfectly from arbitrary rectangles. [Brief, lines 10, 15–25][Brief]; [M1, lines 130–174][M1]

**INFERRED:** A stronger universal guarantee is impossible while preserving arbitrary input order and contiguous copying. For example, if visual row A occupies array indices 0 and 2, while row B occupies index 1, a range from A[0] to A[2] necessarily includes B[1]. Endpoint correction cannot change that consequence of `selectedText`. [M1, lines 50–58][M1]

#### D2. Conservative row construction

**INFERRED — proposed design, not an upstream algorithm:** Build a selection-only row sidecar once per recognized-line snapshot. Keep original indices and copied text unchanged. Work in image coordinates with inline coordinate `u` and perpendicular coordinate `v`; invert the existing canvas transform for the pointer rather than deriving reading direction from rotated bounding-box minima. [M1, lines 13–32, 37–58, 120–137][M1]

**INFERRED — proposed construction:** Process valid rectangles from shortest perpendicular height to tallest, with deterministic geometry/index ties. Each row stores:

- Original line indices.
- A **core band**, the intersection of its members’ perpendicular intervals.
- Inline union components and the original line owning each exposed component boundary.

A candidate fits a row only if its core intersection remains positive and it overlaps more than half the shorter perpendicular interval with **every** member. If it fits multiple rows, mark it an ambiguous spanner; do not attach it to those rows, merge them, or enlarge their bands. If it fits one row, add it and intersect the core. Otherwise create a row. This deliberately uses complete membership checks rather than an overlap-connected component. [Design basis: M1, lines 143–157][M1]; [PDFBox nontransitivity warning, lines 500–502][PDFBox]

```text
buildRows(lines):
    rows = []
    spanners = []

    for i in validLinesSortedBy(perpendicularHeight, geometry, originalIndex):
        compatible = []

        for row in rows:
            if positiveIntersection(row.core, interval(i))
               and every member j of row satisfies:
                   overlap(interval(i), interval(j))
                     > 0.5 * min(height(i), height(j)):
                compatible.append(row)

        if compatible.count == 0:
            rows.append(Row([i], core = interval(i)))
        else if compatible.count == 1:
            row = compatible[0]
            row.members.append(i)
            row.core = intersection(row.core, interval(i))
        else:
            spanners.append(i)    // never connect these rows

    for row in rows:
        row.components = unionInlineIntervalsWithBoundaryOwners(row.members)

    return rows, spanners
```

**INFERRED:** The interval union must be a sweep with a running maximum right edge, not adjacent comparisons after sorting by left edge. A nested short interval must not replace the enclosing wide interval as owner of the exposed right boundary. Equal exposed boundaries use deterministic original-index priority. [Brief, line 17][Brief]; [M1, lines 159–174][M1]

**UNCONFIRMED:** The 0.5 overlap threshold is a proposed compatibility policy, not a proven universal Vision row detector. Slightly misaligned labels, short noise boxes, superscripts, skew, and spanner-origin drags may need a different row-evidence policy. Real Vision bounds are needed to validate this choice. [Mado model, lines 68–76][MModel]; [docTR’s different center-based policy, lines 103–146][DocTR]

#### D3. Outside endpoint mapping

**INFERRED — proposed design:** Preserve the current exact-hit path and character-offset behavior. Invoke the new mapping only after no box contains the pointer. [Brief, line 10][Brief]; [M1, lines 99–126][M1]

```text
resolve(point, anchor):
    if currentExactHit(point) exists:
        return currentCharacterPosition(point, hitLine)

    p = inverseCanvasTransform(point)

    rows = precomputedRows
    if rows is empty:
        return nil

    row = minimum rows by:
        1. distance(p.v, row.core)
        2. abs(p.v - midpoint(row.core))
        3. prefer anchor's row, only on an exact preceding tie
        4. stable row ID

    // No inline/x term participates in choosing row.

    if p.u is before all row components:
        return positionAtExposedLeftBoundary(firstComponent)

    if p.u is after all row components:
        return positionAtExposedRightBoundary(lastComponent)

    if p.u is in a gap between leftComponent and rightComponent:
        if anchor belongs to row:
            choose boundary on anchor's side of this gap
        else:
            choose boundary according to cross-row logical drag direction
        return that boundary's original (line, offset)

    // p.u projects into a component, but p is outside actual boxes.
    eligible = component members whose inline intervals contain p.u
    choose anchor line if eligible, otherwise stable original-index priority
    return existingCharacterPosition(point, chosenLine)
```

**INFERRED:** For ordinary rows whose original indices lie wholly before or after the anchor, preserve the existing cross-row convention: forward dragging chooses the preceding gap boundary, reverse dragging the following boundary. If indices interleave, define a deterministic fallback and flag the layout as ambiguous rather than claim semantic correctness. [M1, lines 168–171][M1]; [M1 serialization, lines 50–58][M1]

**INFERRED:** Spanners remain available for exact hits and text serialization but do not establish outside-selection row bands. If a drag begins in a spanner, the proposed fallback treats it as having no anchor row and uses the ordinary row-distance/cross-row rules. This makes the function defined; it is not evidence that this fallback matches user expectations for drop caps or oversized isolated text. [Brief, lines 15–16][Brief]; [M1, lines 103–111][M1]

#### D4. Guarantees and supplied counterexamples

**INFERRED:** Under the stated row-band contract, the following follow directly:

1. **Vertical precedence:** changing only `u` cannot change the selected row while both points remain outside every actual box; the row score contains no `u`.
2. **No bridge merge:** rows are never unioned, and adding a member can only shrink its core. A multirow spanner does not modify any core.
3. **Anchor-side gap:** on the anchor row, a gap resolves to its anchor-side exposed boundary, not the horizontally nearest line.
4. **Nested-box safety:** interval-union boundaries belong to the rectangle actually exposing that boundary.
5. **Existing range semantics:** returned positions retain original indices; copying/highlighting retain the original serializer.

These are design deductions, not executed test results. [Contract: Brief, line 10][Brief]; [integration constraints: M1, lines 37–58, 77–126][M1]

| Supplied case | Expected behavior under the proposal |
|---|---|
| Price, endpoint `(330,21)` | **INFERRED:** November and Monday form separate short bands; the tall `16` fits both and becomes a spanner. Distances are 1 to November and 7 to Monday, so the endpoint is November’s end. [Brief, line 15][Brief] |
| Tall variant, `(600,62)` | **INFERRED:** `big` becomes a spanner between short rows a/b; distance to b is 2, versus 42 to a. Resolve to b’s end. [Brief, line 16][Brief] |
| Wide + nested short + C | **INFERRED:** Wide/short form one union component ending at x=300, owned by wide. The gap before C therefore resolves to wide’s end when anchored in wide. [Brief, line 17][Brief] |
| Chinese + SIDE gap | **INFERRED:** If row construction assigns them to the same row, the gap resolves to the anchor-side component. **UNCONFIRMED:** The actual Vision bounds’ compatibility with the proposed threshold was not measured. [Brief, line 18][Brief]; [M2 fixture construction, lines 127–137][M2] |
| Next-row margin, A/B/C, overshoot, reverse, rotation | **INFERRED:** Fixed row selection, component-boundary resolution, and inverse transformation address these as separate rules. Exact expected positions must be checked across their full coordinate neighborhoods. [Brief, line 19][Brief]; [M2, lines 154–230][M2] |

#### D5. Test strategy that catches the failure class

**INFERRED — proposed tests:** Use three independent layers: a declarative oracle with known row membership, exact hand-built regressions, and real Vision fixtures. Do not make the oracle call production row construction or interval-union helpers. This combines exhaustive-generation and exact-geometry precedents without inheriting their domain assumptions. [Tesseract tests, lines 518–533][TessTests]; [docTR tests, lines 187–230][DocTRTests]; [M2, lines 127–137][M2]

**INFERRED — generated layout oracle:**

- Generate separated true row bands and 1–4 fragments per row.
- Add height variation constrained to the declared row model.
- Add tall rectangles spanning at least two rows, nested intervals, overlapping intervals, and duplicate boundaries.
- Generate text with ASCII, Chinese, combining sequences, and emoji graphemes.
- Generate pointers at every relevant edge, midpoint, gap, margin, and `edge ± ε`.
- Enumerate both anchor sides and cross-row directions.
- Apply quarter-turns, flips, positive zoom, and translations.
- Compare exact `(original line identity, Character offset)`, exact copied string, and selected rectangle/text consistency.

The generator supplies true row membership directly; separate tests evaluate whether the proposed row detector recovers that membership. [Design requirements: Brief, lines 23–25][Brief]; [Mado geometry/string semantics, lines 13–58, 77–126][M1]

**INFERRED — required invariants:**

| Property | Necessary precondition / expected assertion |
|---|---|
| Inside-hit dominance | Preserve the current first-containing-box result, including overlapping/nested hits. It cannot mean “every overlapping box wins.” |
| Perpendicular priority | At a fixed perpendicular coordinate, any two outside-box points choose the same row. |
| Bridge immunity | Adding a recognized multirow spanner leaves existing short-row cores distinct and preserves the chosen short-line identity in supplied cases. |
| Gap stability | Sweeping through a gap on the anchor row stays at the anchor-side boundary. |
| Nested frontier | Adding an interval completely inside a component does not replace its exposed boundary owner. |
| Conditional monotonicity | In a fixed row with nonoverlapping fragments ordered consistently with logical indices, an inline sweep produces nondecreasing positions. Do not assert this globally for mixed bidi or interleaved indices. |
| Conditional reversal | Two unambiguous in-box endpoints yield the same normalized logical range when swapped. Outside-gap drags require direction-specific expectations. |
| Whole-range copy | For nonempty input and resolved positions `(0,0)` through the last line’s end, copy equals the original strings joined with `"\n"`. |
| Transform covariance | Transforming image geometry and pointer together preserves logical positions. |
| Valid output | Returned offsets lie in `0...text.count`; empty/no-valid-geometry input does not crash. |

All properties above are **INFERRED proposals**, grounded in the owner rule and current API semantics, not claims of existing upstream coverage. [Brief, lines 10, 23–25][Brief]; [M1, lines 37–126][M1]

**INFERRED:** Preserve the exact five supplied counterexample families as a single regression matrix. Sweep y around November’s bottom edge and b’s bottom edge, and include the third `C` in nested tests. Merely retaining the current y=12/y=55 examples would miss the reported failure neighborhood. [Brief, lines 15–19][Brief]; [M2, lines 181–220][M2]

**INFERRED:** Freeze recognized strings/boxes from `mixed.png` and the oriented fixture as deterministic geometry fixtures, alongside live Vision integration tests. Record recognition environment when collecting them. A live OCR result alone makes geometry regressions harder to distinguish from recognition changes. [M2, lines 110–137][M2]

**INFERRED:** Cache row construction per line snapshot. The simple complete-membership construction is quadratic in line count; endpoint row scanning can be linear before optional indexing. Benchmark large lists before choosing optimization thresholds; this investigation measured no timings. [M1’s current per-drag rectangle construction, lines 99–101][M1]; [proposed construction in D2, derived from the owner contract][Brief]

### Edge-case matrix

Each relevance assessment below is **INFERRED** for Mado’s current flat Vision-line model. “Handles” identifies the particular evidenced operation, not universal correctness.

| Edge case | Evidence status / who handles it | How | Relevant to Mado |
|---|---|---|---|
| Tall/short mixed heights | **CONFIRMED:** PDFBox, docTR | Explicit line-height concerns; median-height/center grouping. [PDFBox:622–640][PDFBox]; [docTR:103–146][DocTR] | Yes; central failure |
| Superscripts/subscripts | **CONFIRMED:** PDFBox; **UNCONFIRMED:** active Tesseract superscript test | PDFBox comments address line separation; Tesseract `SubSuperTest` is disabled. [PDFBox:622–640][PDFBox]; [Tesseract tests:369–469][TessTests] | Yes when they alter observation geometry |
| Drop caps | **CONFIRMED:** Tesseract | Real-image symbol/drop-cap classification test. [Tests:369–405][TessTests] | Yes; metadata unavailable in Mado model |
| Overlapping/nested boxes | **CONFIRMED:** Mado; Gecko warning | First-containing exact hit; Gecko warns generic nearest-frame helper cannot correctly handle overlap. [M1:103–104][M1]; [Gecko:5283–5318][Gecko] | Yes |
| Columns | **CONFIRMED:** MuPDF limitation, Kraken, LayoutParser, XY-cut | Existing block structure; precedence/regions; explicit column partition; whitespace cuts. [MuPDF:191][MuPDF]; [Kraken:85–170][Kraken]; [LayoutParser:97–128][LayoutParser]; [XY-cut:103–314][XYCut] | Yes, but upstream ordering is separate |
| Side-by-side labels | **CONFIRMED:** Mado tests | Anchor-side gap and overshoot checks. [M2:47–86, 172–179][M2] | Yes |
| Tables | **UNCONFIRMED:** universal table selection | These inspected layout/caret sources do not establish one correct table reading/selection policy. [Scope: LayoutParser example:97–128][LayoutParser] | Yes; preserve existing order for this fix |
| Rotation/skew | **CONFIRMED:** MuPDF, OCRmyPDF, docTR | Direction frames, baseline transforms, angle correction. [MuPDF:74–214][MuPDF]; [OCRmyPDF:311–365][OCRmyPDF]; [docTR:42–63][DocTR] | Yes; arbitrary skew remains a separate limitation |
| Vertical text | **CONFIRMED:** pdfminer, Blink tests | Axis-specific layout and vertical-rl/RTL offsets. [pdfminer:752–827][PDFMiner]; [Blink tests:975–1007][BlinkTests] | Yes; not equivalent to rotating horizontal text |
| RTL/mixed bidi | **CONFIRMED:** MuPDF, Tesseract, WebKit | Bidi-aware boundaries/logical order and transition tests. [MuPDF:74–127][MuPDF]; [Tesseract tests:478–533][TessTests]; [WebKit tests:48–89][WebKitTests] | Yes; richer direction model needed |
| Above first / below last row | **CONFIRMED:** Blink, WebKit, Gecko | Explicit block-axis boundary handling; platform/preferences affect behavior. [Blink:605–724][Blink]; [WebKit:3296–3375][WebKitFlow]; [Gecko:5116–5242][Gecko] | Yes |
| Equal distances | **CONFIRMED:** MuPDF, PDFium, Gecko | Later replacement with `<=`; first tolerant hit with `<`; different block/inline tie conventions. [MuPDF:165–202][MuPDF]; [PDFium:415–447][PDFium]; [Gecko:5116–5242][Gecko] | Yes; specify deterministically |
| Exactly on an edge | **CONFIRMED:** Blink | Explicit bottom-edge exclusion and coordinate-table tests. [Blink:605–724][Blink]; [Margin tests:17–145][BlinkMargins] | Yes; retain exact-hit convention |
| Zero-size/degenerate boxes | **CONFIRMED:** OCRmyPDF, MuPDF | Skip nonpositive-height line data or zero-extent highlight quads. [OCRmyPDF:311–365][OCRmyPDF]; [MuPDF:345–410][MuPDF] | Yes |
| Single line / no lines | **CONFIRMED:** Mado, docTR | Empty-line-list guard; empty builder output. [M1:100][M1]; [docTR:238–251][DocTR] | Yes |
| Very many lines | **CONFIRMED:** pdf.js limit | Text-div processing threshold. [Text layer:251–305][PDFJSText] | Yes; no measured Mado performance conclusion |
| OCR noise/confidence | **CONFIRMED:** Tesseract metadata; Mado omission | Confidence emitted upstream, absent from Mado line model. [hOCR:263–305][TessHOCR]; [Mado model:68–76][MModel] | Yes; filtering changes scope |
| Tolerance/padding | **CONFIRMED:** PDFium | Tolerance-expanded character rectangles and combined edge-distance ranking. [PDFium:415–447][PDFium] | Yes; padding must not defeat vertical precedence |
| Unicode/combining text | **CONFIRMED:** Okular, Mado | NFC entity merging; Swift `Character` offsets and character-box count matching. [Okular:185–201][Okular]; [M1:113–126][M1] | Yes |

### Sources

The citations below are primary source code at the indicated tag/commit, official documentation, or the explicitly requested local primary files. No secondary articles support technical conclusions.

- **Local evidence:** [brief][Brief]; [selection implementation][M1]; [selection tests][M2]; [line model][MModel]; [Vision provider][MProvider].
- **PDF engines:** [MuPDF selection][MuPDF], [extraction][MuPDFDevice]; [PDFium hit testing][PDFium], [tests][PDFiumTests]; [Poppler tagged source mirror][Poppler]; [Okular][Okular].
- **Extraction/layout:** [PDFBox comparator][PDFBoxComparator], [stripper][PDFBox], [tests][PDFBoxTests]; [pdfminer layout][PDFMiner], [tests][PDFMinerTests].
- **Browsers:** [pdf.js builder][PDFJSBuilder], [text layer][PDFJSText], [tests][PDFJSTests]; [Blink implementation][Blink], [unit tests][BlinkTests], [margin tests][BlinkMargins]; [WebKit document API][WebKitDocument], [layout helper][WebKitFlow], [tests][WebKitTests]; [Gecko][Gecko]; [CSSOM specification][CSSOM].
- **OCR/layout systems:** [Tesseract hOCR][TessHOCR], [iterator][TessIterator], [tests][TessTests]; [OCRmyPDF renderer][OCRmyPDF], [tests][OCRmyPDFTests]; [docTR builder][DocTR], [tests][DocTRTests]; [Kraken order][Kraken], [tests][KrakenTests]; [Surya documentation][Surya], [tests][SuryaTests]; [LayoutParser example][LayoutParser]; [PdfPig recursive XY-cut][XYCut], [tests][XYCutTests].
- **Applications/platform:** [NormCap recognition][NormCap], [structure][NormCapStructure], [tests][NormCapTests], [fixtures][NormCapData]; [Text-Grab model][TextGrabModel], [selection][TextGrab], [tests][TextGrabTests]; [Capture2Text official documentation][Capture2Text]; [Artikash Textractor][Textractor]; [Apple VisionKit][Apple].
- Research workflow used: [project research skill](<repo>/.agents/skills/research/SKILL.md).

[Brief]: ~/.picsee/herdr/delegator/research/i688-selection-problem.md:1
[M1]: picsee-wt/gpt-imple-1-688/App/TextRecognition/ImageTextSelection.swift:1
[M2]: picsee-wt/gpt-imple-1-688/AppTests/Issue688SelectTextTests.swift:1
[MModel]: picsee-wt/gpt-imple-1-688/Packages/MadoKit/Sources/MadoApplication/TextRecognition/TextRecognitionService.swift:68
[MProvider]: picsee-wt/gpt-imple-1-688/Packages/MadoKit/Sources/MadoInfrastructure/TextRecognition/OnDeviceTextRecognitionProvider.swift:1
[MuPDF]: https://github.com/ArtifexSoftware/mupdf/blob/1.25.0/source/fitz/stext-search.c#L74
[MuPDFDevice]: https://github.com/ArtifexSoftware/mupdf/blob/1.25.0/source/fitz/stext-device.c#L563
[PDFium]: https://github.com/chromium/pdfium/blob/012fe571c9fe430da68dbcd2f5ba21758db0ae15/core/fpdftext/cpdf_textpage.cpp#L415
[PDFiumTests]: https://github.com/chromium/pdfium/blob/012fe571c9fe430da68dbcd2f5ba21758db0ae15/fpdfsdk/fpdf_text_embeddertest.cpp#L189
[Poppler]: https://skia.googlesource.com/third_party/poppler/+/refs/tags/poppler-22.04.0/poppler/TextOutputDev.cc#4850
[Okular]: https://github.com/KDE/okular/blob/v24.12.0/core/textpage.cpp#L277
[PDFBoxComparator]: https://github.com/apache/pdfbox/blob/3.0.3/pdfbox/src/main/java/org/apache/pdfbox/text/TextPositionComparator.java#L32
[PDFBox]: https://github.com/apache/pdfbox/blob/3.0.3/pdfbox/src/main/java/org/apache/pdfbox/text/PDFTextStripper.java#L494
[PDFBoxTests]: https://github.com/apache/pdfbox/blob/3.0.3/pdfbox/src/test/java/org/apache/pdfbox/text/BidiTest.java#L61
[PDFMiner]: https://github.com/pdfminer/pdfminer.six/blob/20240706/pdfminer/layout.py#L53
[PDFMinerTests]: https://github.com/pdfminer/pdfminer.six/blob/20240706/tests/test_layout.py#L16
[PDFJSBuilder]: https://github.com/mozilla/pdf.js/blob/v4.10.38/web/text_layer_builder.js#L222
[PDFJSText]: https://github.com/mozilla/pdf.js/blob/v4.10.38/src/display/text_layer.js#L251
[PDFJSTests]: https://github.com/mozilla/pdf.js/blob/v4.10.38/test/integration/text_layer_spec.mjs#L58
[Blink]: https://chromium.googlesource.com/chromium/src/+/4d54f0a8e47abbf6d5d401c7d09a43ec2994d130/third_party/blink/renderer/core/layout/inline/inline_cursor.cc#605
[BlinkTests]: https://github.com/chromium/chromium/blob/4d54f0a8e47abbf6d5d401c7d09a43ec2994d130/third_party/blink/renderer/core/layout/inline/inline_cursor_test.cc#L975
[BlinkMargins]: https://github.com/chromium/chromium/blob/4d54f0a8e47abbf6d5d401c7d09a43ec2994d130/third_party/blink/web_tests/editing/selection/click-in-margins-inside-editable-div.html#L17
[WebKitDocument]: https://github.com/WebKit/WebKit/blob/3025232f837965ab567f9de4330bb82b29866cfd/Source/WebCore/dom/Document.cpp#L2152
[WebKitFlow]: https://github.com/WebKit/WebKit/blob/3025232f837965ab567f9de4330bb82b29866cfd/Source/WebCore/rendering/RenderBlockFlow.cpp#L3296
[WebKitTests]: https://github.com/WebKit/WebKit/blob/3025232f837965ab567f9de4330bb82b29866cfd/LayoutTests/editing/selection/caret-at-bidi-boundary.html#L16
[Gecko]: https://github.com/mozilla-firefox/firefox/blob/FIREFOX_132_0_RELEASE/layout/generic/nsIFrame.cpp#L5116
[CSSOM]: https://www.w3.org/TR/2025/WD-cssom-view-1-20250916/#dom-document-caretpositionfrompoint
[TessHOCR]: https://github.com/tesseract-ocr/tesseract/blob/5.5.0/src/api/hocrrenderer.cpp#L43
[TessIterator]: https://github.com/tesseract-ocr/tesseract/blob/5.5.0/include/tesseract/resultiterator.h#L49
[TessTests]: https://github.com/tesseract-ocr/tesseract/blob/5.5.0/unittest/resultiterator_test.cc#L106
[OCRmyPDF]: https://github.com/ocrmypdf/OCRmyPDF/blob/v16.10.4/src/ocrmypdf/hocrtransform/_hocr.py#L186
[OCRmyPDFTests]: https://github.com/ocrmypdf/OCRmyPDF/blob/v16.10.4/tests/test_hocrtransform.py#L75
[DocTR]: https://github.com/mindee/doctr/blob/v0.11.0/doctr/models/builder.py#L42
[DocTRTests]: https://github.com/mindee/doctr/blob/v0.11.0/tests/common/test_models_builder.py#L187
[Kraken]: https://github.com/mittagessen/kraken/blob/17c8cef65a80ac93848ab91aac798fd3c770edd3/kraken/lib/segmentation.py#L85
[KrakenTests]: https://github.com/mittagessen/kraken/blob/17c8cef65a80ac93848ab91aac798fd3c770edd3/tests/test_readingorder.py#L49
[Surya]: https://github.com/datalab-to/surya/blob/v0.13.1/README.md#L197
[SuryaTests]: https://github.com/datalab-to/surya/blob/v0.13.1/tests/test_layout.py#L1
[LayoutParser]: https://github.com/Layout-Parser/layout-parser/blob/v0.3.4/docs/example/deep_layout_parsing/index.rst#L97
[XYCut]: https://github.com/UglyToad/PdfPig/blob/v0.1.11/src/UglyToad.PdfPig.DocumentLayoutAnalysis/PageSegmenter/RecursiveXYCut.cs#L103
[XYCutTests]: https://github.com/UglyToad/PdfPig/blob/v0.1.11/src/UglyToad.PdfPig.Tests/Dla/RecursiveXYCutTests.cs#L8
[NormCap]: https://github.com/dynobo/normcap/blob/v0.5.9/normcap/ocr/recognize.py#L16
[NormCapStructure]: https://github.com/dynobo/normcap/blob/v0.5.9/normcap/ocr/structures.py#L130
[NormCapTests]: https://github.com/dynobo/normcap/blob/v0.5.9/tests/integration/test_normcap.py#L12
[NormCapData]: https://github.com/dynobo/normcap/blob/v0.5.9/tests/integration/testcases/data.py#L161
[TextGrabModel]: https://github.com/TheJoeFin/Text-Grab/blob/f0345015dcabf572453568addfcecc64abfc1c16/Text-Grab.Core.Windows/Models/WinRtOcrLinesWords.cs#L8
[TextGrab]: https://github.com/TheJoeFin/Text-Grab/blob/f0345015dcabf572453568addfcecc64abfc1c16/Text-Grab/Views/GrabFrame.xaml.cs#L2190
[TextGrabTests]: https://github.com/TheJoeFin/Text-Grab/blob/f0345015dcabf572453568addfcecc64abfc1c16/Tests/WordBorderTests.cs#L10
[Capture2Text]: https://capture2text.sourceforge.net/#how_to_capture
[Textractor]: https://github.com/Artikash/Textractor/blob/v5.2.0/README.md#L44
[Apple]: https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview

### Answer — delivery and verification limits

**Recommendation:** Proceed with a separately specified row-band model and a vertical-first endpoint resolver, using interval-union boundary ownership for gaps. Treat row recovery as a heuristic requiring evidence; the resolver’s guarantees are conditional on that model. [Brief, lines 10–25][Brief]; [M1, lines 130–174][M1] **INFERRED.**

**File path:** `~/.picsee/herdr/delegator/research/i688-selection-codex.md` — **not written because the sandbox permits reading only.** The complete note is returned above.

**Could not verify:** Apple’s private snapping behavior; Capture2Text’s source-level distance/tie policy; the intended OCR Textractor implementation; several projects’ selection-specific tests; actual Vision bounds for smoke688; runtime correctness/performance of the proposal; or the local worktree’s commit identity. No git commands, project builds, or Swift tests were run.

**Execution exception:** Two research subagents attempted read-only HTTP access through system `python3`; Apple’s developer-tool shim unexpectedly emitted `xcodebuild` diagnostics. They stopped that path and continued through web/GitHub tools. Consequently, this investigation cannot claim that no Xcode-related process was invoked at all, although no project build or test was intentionally launched.
