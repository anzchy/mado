# Grilling record: Table Recognition (2026-11-24)

Input: [plan](20261124-table-recognition-plan.md) (spike result, DeepSeek API facts, current UI, preliminary UI plan, 14 questions). Decisions are the owner's; quotes are the owner's words. Glossary changes are in `GLOSSARY.md`.

## Decisions

### 1. Where "识别表格" sits in the vocabulary, and how a request is routed
- **Table Recognition is a kind of result; Cloud Recognition is the engine.** Cloud Recognition's definition now covers an OCR service or a vision-model endpoint. Owner: 「确定，按此记入词汇表」.
- **The command decides the kind of result** (owner asked: 「怎么 route，何时选 baidu ocr，何时选 table recognition」):

  | User does | Result | Engine | On failure |
  |---|---|---|---|
  | Recognise Text, ⌃⌥4 | text | Baidu when Cloud Recognition is on and a key exists; else On-device | existing fallback, labelled |
  | Recognise Table | table | only the table service (DeepSeek, OpenAI or custom); no on-device engine yet | no fallback to Baidu or on-device; the user is told why and may ask for text |
  | Select text on the image | text | always On-device (ADR-019) | — |

- No automatic detection of tables (it would need an upload first, against ADR-019's "only when explicitly asked"). Baidu's general_basic returns lines of text without row/column structure, so it cannot stand in for a table.
- Settings keep the two apart: the Text Recognition group chooses the text service (Baidu); a Table Recognition group chooses the table service. One global switch for all cloud features; consent per service naming the host (to be confirmed in question 3).

## Decisions 2–14: delegated to Codex (novice-user view, UX consistency)

Owner, 2026-11-24: 「let codex 从一个小白用户的角度，来决定，要求符合用户UX」. Codex (read-only consult) picked the answers below. Items marked **[owner confirm]** touch privacy or consent and are not final until the owner says so. Codex did not re-verify API or price facts, and found nothing local on macOS 26 Vision table APIs.

2. **Entry points (all four in v1), default shortcut ⌃⌥5 for the Capture action only.** View › *Recognise Table / 识别表格*; Capture Bar button *Recognise Table* (tooltip "Capture and Recognise Table"); Text panel action *Recognise as Table / 按表格重新识别*; Capture Thumbnail action *Recognise Table*. The last two reuse the original image, not the recognised text. Unconfigured first use **[owner confirm]**: dialog "首次使用需要连接识别服务。设置完成后即可继续；目前尚未发送图片。" with *Set Up* (jumps to the Settings group) and *Cancel*; the pending image stays in memory; the user clicks *Continue Recognition* after setup, never an automatic upload.
3. **One global "Allow Cloud Recognition" switch plus consent per service host** **[owner confirm]**. Baidu consent does not cover DeepSeek; a changed host asks again. First upload: "将这张图片发送到 {host} 识别表格？图片会离开你的 Mac，由该服务处理，并适用其隐私政策。" with *Agree and Recognise* / *Cancel*. No "not retained" promise unless confirmed.
4. **New ADR extends ADR-019** **[owner confirm]**: command decides result kind, Cloud Recognition is the engine; About, README, Settings, GLOSSARY and release template stop saying Baidu is the only exception; the real host is shown next to the address; no silent cross-host redirect of image or key; sandbox unchanged.
5. **Settings: new "Table Recognition" group on the Screenshots page, default DeepSeek.** Visible: service, Access Key (secure field; save/replace/remove), Test button, "Get a DeepSeek Key" help (planned link platform.deepseek.com/api_keys, **not verified online**). Advanced (collapsed): address and model; Custom opens it. The host stays visible outside Advanced. An OpenAI preset ships only with a verified vision model.
6. **Request shaping per preset, no "thinking" control.** DeepSeek: thinking disabled. OpenAI/custom: standard fields only. Changing the model clears the old Test result.
7. **Test sends a built-in tiny table image and checks the returned table** **[owner confirm the note]**. Note beside the button: "发送内置示例，不发送你的图片；服务可能收费。" Still bound by the switch and consent. Plain messages for wrong key, unreachable address, model without image support, offline, quota; otherwise "测试未通过", no guessing.
8. **The result opens a resizable table panel with directly editable cells; no auto-copy.** Shows source image beside it, row/column count, service name, undo, a "check text and rows" hint; "Table recognised · 7 rows, 4 columns (including header)"; "Table copied" only after copying. Markdown editing under advanced actions. en + zh-Hans, keyboard-editable, IME-safe, focus restored on close. No five-second auto-dismiss.
9. **Default *Copy Table* writes HTML and tab-separated plain text together.** Plain-text editors get tabs and newlines, no pipes. *Copy Markdown* only on request; optional *Copy for Spreadsheet* (TSV only). All flavors come from the edited content. Excel/Numbers behaviour needs a device check. In-cell line breaks must be defined.
10. **macOS 26 on-device table engine does not block this plan and is not promised in v1.** Unverified; a separate spike decides later. The macOS 14 path must not depend on it.
11. **v1 scope: one ordinary table in one clear image.** Hint "include one table". Over a hard limit: ask to select a smaller area before upload, no silent downscale. Merged cells may be expanded; tilted photos need straightening. No table, mixed column counts or a truncated reply is never reported as success; offer *Select Again*, *Retry*, *Settings*, and a separate explicit *Recognise Text Only (On-device)*. Cancellable; no automatic retry of a paid request.
12. **New ledger row EXT-06 "Table Recognition", status Absent, own work package.** Proposed acceptance: recognise from opened-image and capture entries, check and fix cells, copy, paste into Word as a complete editable table, screenshot-compare all rows, columns and text with known differences listed; plus Excel/Numbers, four entries, en/zh, keyboard, VoiceOver, and no upload when consent is refused or the switch is off. Shipped needs a signed device record. EXT-04's Baidu acceptance is not rewritten.
13. **Cost text, no invented price:** "识别由你选择的服务提供，可能使用账户余额；费用与余额请到服务账户查看。" Key in Keychain per service config; a new address does not inherit an old key. Local diagnostics keep only token counts, time and error class **[owner confirm]**; never images, text or keys.
14. **Tests target "complete after paste", not "API returned 200".** Red first: consent, switch, host change, test image, error classes, truncation, Markdown→HTML/TSV, HTML escaping; samples with mixed CJK/English, spaces, pipes, multi-line cells, `Sensonor`; sanitised fixtures only; final acceptance with the owner's key and a real Word screenshot, recording the Word version.

**Codex disagreements with the plan** (to fix in the spec): do not force "first row is the header"; the prompt cannot replace clipboard conversion; Markdown cannot carry merged cells, so disclose differences in fonts and widths; the plan's "32 cells" contradicts "4 columns, header + 6 rows", so correct the baseline; the preview renders only controlled table content (no scripts, remote images or links); cell editing and the thumbnail entry are not stretch goals.

## Decision 15: Settings keeps one short line per row; how-to and long privacy text move to a help website (owner 2026-11-24)
Owner: 「详细操作文字太多了，考虑将所有的操作细节形成一个html帮助页，单独发布为一个website，或者你看看业内最佳实践」, and 「37 capture bar还没有更新，图标旁边还有文字」.
- **Capture Bar (37) is now icon-only** with 识别表格 (⌃⇧⌘5, placeholder) after 识别文字; the tooltip carries name and shortcut. The native bar (`CaptureBarView.swift`) still draws text labels and follows through the spec; CAP-01's 「怎么确认」 changes then.
- **Rule for Settings:** a hint is at most one short line. Steps ("怎么获取密钥") and long privacy text live on a help page, opened by a 「了解更多 ↗」 link in the default browser. Consent-critical facts stay in the app in one sentence ("图片只在你点「识别表格」后发送到 {host}"), because ADR-019 needs them visible where the user decides.
- **Prototype pages** `states/help/{index,deepseek-key,baidu-key,cloud-recognition,screen-recording}.html`; shortened Baidu and 截图 hints are drawn in `table-settings.html` as a proposal. Formal 35 (`settings.html`) is unchanged until decided.
- **Open for the owner:** where the site is published (e.g. GitHub Pages of the project repo); nothing is published. Offline users get only the one-line hint. Opening a link in the browser is not Mado's own network use (ADR-0015 holds); the ADR-019 amendment should say so.
