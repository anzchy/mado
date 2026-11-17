# Bottom Bar at 80% and the Home Image Wall: grilling record

2026-10-30, `/grill-with-docs 底栏常驻80%和首页图片墙`. The owner made every decision below; mado-delegator asked the questions and checked the facts. Terms are in [GLOSSARY.md](../../GLOSSARY.md): **Home**, **Image Wall** and **Bottom Bar**.

This is grilling only. The next steps are `/to-spec` and then `/to-tickets`. No implementation starts before the tickets exist (`.claude/rules/10-spec-before-implementation.md`).

## Starting point

- The owner said: 「整条底栏去掉，打开文件夹后底栏出现，而且我希望底栏透明无填充」. Prototype round 1 showed variants A, B and C.
- Then: 「我希望打开文件夹后，底栏还是常驻的（如A所示，但是透明度给个20%，40%，60%3个选项让我选）」. The 20/40/60% levels looked identical, because in layout A nothing sits behind the bar. The prototype was changed so that photos scroll behind the bar.
- The owner picked 「填充 80%（很实）」 (asked as 「透明度80%」 and clarified to mean fill).
- Home wall: 「prototype-home-wall.html，选C，但是图片墙可以放大」, then 「home-image-wall.html 这一版可以」.
- Reference pages are on main (#308): `design/prototypes/picsee-browser/states/grid-footer-fill.html` and `home-image-wall.html`. Both are reference pages only, not pinned states. The source prototypes are on branch `prototype/footer-transparent`.

## Facts checked

- Today the first-launch window shows the Bottom Bar with search, sort, info and display disabled (ledger OPEN-01).
- B4 「散落相纸」 (OPEN-08, P3-16 #202) places built-in sample prints at the window edges: light 30%, dark 40%. When a folder is dragged over the window, the prints fade and the central photo opens out.
- B4 ships 6 sample photos at 480 px on the long edge (about 350 KB in total), with their provenance in `PROVENANCE.md`.
- The viewer has its own bottom command bar, which is separate from the Grid's Bottom Bar.
- Pages 11/12 (`grid-light.html`, `grid-dark.html`) pin today's solid Bottom Bar with a 1 px top rule.

## Decisions

| # | Question | Owner's choice |
|---|---|---|
| 1 | How does Image Wall C relate to B4? | 「C 取代 B4 外观，保留拖入反馈」: the Home shows the tilted collage. Dragging a folder over the window still gives feedback: the wall fades and the drop prompt highlights. Dropping opens the folder, as today. |
| 2 | Which images does the wall show on a first launch? | 「沿用 B4 内置样图」. The wall never reads the user's disk. |
| 3 | Which windows have no Bottom Bar? | 「只有未打开文件夹的窗口」. Once a folder is open, the Reading State, an empty folder, a failed read and Lost Access (page 26) all show the Bottom Bar. |
| 4 | What happens to the 80% bar when the system's Reduce Transparency setting is on? | 「变成实色 100%」 |
| 5 | Does the viewer's command bar change too? | 「不改，只改网格底栏」 |
| 6 | When does the wall drift? | 「只在窗口可见且在前台时」. Reduce Motion stops it entirely. |
| 7 | Does the 80% bar keep the 1 px top rule? | 「不要，靠 80% 底色区分」 |
| 8 | How does the bar appear when a folder opens? | 「和网格一起直接出现」: no animation of its own. |
| 9 | Which sample images, at what size? | 「沿用现有 6 张 480px」: no added size. The wall repeats the six images, and on Retina at 30–40% opacity they look slightly soft. |

## Consequences for the spec

- **Bottom Bar.** Its fill is the window background at 80% opacity, or 100% under Reduce Transparency, with no top rule. The Grid scrolls behind it, so the last row must be able to scroll fully clear of the bar. The bar shows in every window with a folder open and never on the Home.
- **Home.**
  - It has no Bottom Bar and no sidebar.
  - The Image Wall is a tilted collage of the six B4 samples, larger than B4's prints. The opacity follows the reference page.
  - The drift runs only while the window is visible and frontmost, and never under Reduce Motion.
  - Drag-over feedback stays; B4's central photo stack goes.
- **Affected ledger rows and pages.**
  - Ledger rows: OPEN-01 (the 「底部…按钮为禁用」 clause in its acceptance), OPEN-08 (B4 appearance) and GRID-01/GRID-08 (the Bottom Bar frame).
  - Pinned pages: 11/12 and 21, plus the other pages that show the grid bar.
  - Changing acceptance needs its own commit that quotes the owner.
- **Out of scope.** The viewer command bar; showing the user's own photos on the wall; new sample images.
