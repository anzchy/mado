# Plan: Table Recognition (识别表格) with an OpenAI-compatible vision model (2026-11-24)

Status: **plan for a grilling session, not a spec.** Nothing here is decided. Per `.claude/rules/10-spec-before-implementation.md` the order is `/grill-with-docs`, then `/to-spec`, then `/to-tickets`; no implementation brief before that.

Owner request (2026-11-24, quoted): 在 OCR 中加入识别表格，调用 OpenAI 的 API（或兼容 OpenAI 协议的自定义 base URL 和 API Key，均在 Settings 中设置，设置旁边要有测试 API 是否能 Work 的小按钮）。提示词：识别表格并输出 md 表格格式，要求输出到 Word 就直接是完整的表格。验收标准是在 Docx 中粘贴，然后截图复核其是否完整 OCR 了表格样式和其中内容。

Later the owner switched the first provider to DeepSeek for the spike.

## 1. Spike result (done, outside the repo)

Spike code and outputs: `~/.mado/spikes/table-ocr/` (`spike.py`, `md2html.py`, `clip.swift`, `out/`). Sample: a 1216×1497 PNG of a 4-column, 6-row Chinese/English table with multi-line cells and borders.

| Run | Prompt | Thinking | Output tokens | Cell errors (32 cells) | Hard `<br>` |
|---|---|---|---|---|---|
| 1 | v1 ("换行用 `<br>`") | on (default) | 4206 (3591 reasoning) | 2 | 58 |
| 2 | v2 (wrapped lines joined) | off | 453 | 2 | 0 |
| 3 | v2, `detail: high` | off | 453 | 2 | 0 |

- Structure (4 columns, 1 header + 6 rows) and all text were correct except one systematic misread: **Sensonor read as Sensoror**, in both cells, on every run. Recognition is not verbatim-safe; the user must be able to review before using the result.
- v1's instruction to mark line breaks made the model copy every visual wrap as `<br>`; pasted into Word the columns would break mid-word. v2 fixes it.
- Thinking mode is on by default for `deepseek-flash` and costs ~85% of the output tokens for no benefit on a copying task. It must be turned off per request.
- **Owner verified (2026-11-24): pasting the result into Word as an HTML table works** (a clipboard that carries `public.html`). Pasting raw Markdown text into Word does not make a table; Word does not parse Markdown.
- Cost for the sample: about 1.1k input and 0.45k output tokens, roughly $0.0004 at DeepSeek's published off-peak price (computed from the price list, not from a bill).
- Borders, column widths, fonts and merged cells are not in Markdown. The spike restores borders and centred header with inline styles when it renders HTML. The sample has no merged cells; they are untested.

## 2. First provider: DeepSeek (from the DeepSeek docs, read 2026-11-24)

| Item | Value |
|---|---|
| Base URL (OpenAI format) | `https://api.deepseek.com` |
| Endpoint | `POST /chat/completions` |
| Model | `deepseek-flash` (version DeepSeek-V4.1-Flash-1017 on the pricing page); the only vision-capable one. `deepseek-v4-pro` does not accept images. Retired names `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` are routed to Flash |
| Thinking | enabled by default; turn off with `"thinking": {"type": "disabled"}` (with the OpenAI SDK: `extra_body`). With thinking off, `temperature` applies; we send 0 |
| Image part | `{"type":"image_url","image_url":{"url":"data:image/png;base64,…","detail":"original"}}`; JPEG, PNG, GIF, WebP; `detail` is `low`, `high`, `original` or `auto` (`low` downsamples to 512×512, unsuitable for tables) |
| Limits | one image ≤ 32 MiB base64, ≤ 8192 px per side, 1024 tokens per image, body ≤ 48 MiB; images only in user, system or tool messages |
| Price (USD per 1M tokens, off-peak / peak) | input miss 0.15 / 0.30, cache hit 0.003 / 0.006, output 0.60 / 1.20; context 1M; peak is Mon to Fri 01:00–04:00 and 06:00–10:00 UTC |

Example (key from the environment, never in the command line or a file):

```sh
IMG=$(base64 -i table.png | tr -d '\n')
curl -sS https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY" -H "Content-Type: application/json" \
  -d @- <<JSON
{
  "model": "deepseek-flash",
  "temperature": 0,
  "thinking": {"type": "disabled"},
  "messages": [{"role": "user", "content": [
    {"type": "text", "text": "<prompt v2 below>"},
    {"type": "image_url", "image_url": {"url": "data:image/png;base64,$IMG", "detail": "original"}}
  ]}]
}
JSON
```

Prompt v2 (working text, to be settled in the grill):

> 识别图片中的表格，输出 Markdown 表格。要求：保留全部行列和每个单元格的完整文字，逐字照抄，不要遗漏、不要改写、不要翻译、不要纠正；第一行是表头。图片里因为单元格宽度而自动折行的文字，是同一段话，必须连成一行，不要加 `<br>`，也不要加空格；只有单元格里明显分成多段（有段落间距或项目符号）时，才用 `<br>` 分隔。只输出表格本身，不要代码围栏，不要任何解释。输出后粘贴到 Word 就应当是一张完整的表格。

Other OpenAI-compatible endpoints (OpenAI, a self-hosted gateway): same chat-completions shape. The `thinking` field is DeepSeek-specific; an endpoint that rejects unknown fields would fail, so request shaping must be per provider preset (an open question below). Model names for other providers are the user's input; the spike has not been run against OpenAI.

## 3. What exists today (read from the code and the ledger)

- **Viewer:** View menu › Recognise Text (no shortcut, no toolbar button; EXT-01, EXT-05). Result: a notice above the zoom group, "Copied N characters · <engine>", click opens an editable plain-text panel (Copy, Close).
- **Capture Bar:** recognise button and ⌃⌥4: region capture, on-device only (EXT-05), nothing saved, same notice and panel at the display's bottom right.
- **Capture Thumbnail:** Copy, Annotate, Open in Mado, Move to Trash.
- **Settings › Screenshots (截图) › Text Recognition:** one Cloud Recognition switch ("Allow Recognize Text to use a cloud service"), service (Baidu), keys (Save to Keychain, Remove Keys), Baidu terms link, a static sentence naming the Baidu product to enable.
- **Engine layer:** a `TextRecognitionService` with on-device and cloud providers behind protocols; Baidu is the first cloud provider (ADR-019: "one provider interface; other services later through the same consent and key rules"; the global switch and one-time consent).
- **Privacy statements** that must change: About text, README privacy bullets, release-notes template (all say Cloud Recognition, Baidu, is the one exception), ADR-015 and ADR-019 (one Baidu exception).

## 4. Preliminary UI plan (for the grill to attack)

Principle: the table is the **result of one explicit user action**; the image leaves the Mac only then, to the endpoint the user configured (ADR-019's rule, extended).

1. **Settings › Screenshots (or a new "Recognition" section): a new group "Table Recognition (识别表格)", next to the existing Text Recognition group.**
   - Provider preset: DeepSeek (default), OpenAI, Custom.
   - Base URL (filled by the preset, editable for Custom), Model (filled by the preset, editable), API Key (secure field, keychain, same pattern as the Baidu keys).
   - **Test button** beside the key row: runs a request with no user image and shows an inline result: ✓ with latency, or a specific reason (key rejected, base URL not found, model not found, timeout, model does not accept images). Candidate design: the test sends a tiny generated image so that "this model cannot read images" (for example `deepseek-v4-pro`) shows up in Settings and not at first use.
   - Consent sentence and a global on/off switch, same rule as Cloud Recognition (the first use asks; Settings can turn it off). Thinking is not a user setting; the app sends the provider's non-thinking request.
2. **Viewer: View › Recognise Table… (识别表格) under Recognise Text.** Always explicit. When Table Recognition is not configured the item opens Settings at the group instead of failing. The Recognise Text result panel also offers "Recognise as table" as a secondary action, because the person looking at flat text that lost its layout is exactly the person who wants the table.
3. **Capture Bar: a "Recognise Table" button (and a shortcut, for example ⌃⌥5) that captures a region and recognises a table in one step**, mirroring ⌃⌥4. This is the highest-value path: screenshot a table in a browser or PDF and paste it into Word. Nothing is saved, same as ⌃⌥4.
4. **Result: the same quiet notice, then a panel.** Notice: "Copied table · 6 rows × 4 columns · DeepSeek". Clicking it opens a panel with a rendered **preview of the table** and a toggle to edit the Markdown source, because the model makes small errors (Sensoror). Copy buttons: "Copy as table" (default) and "Copy Markdown".
5. **Clipboard contents:** one write with several flavors, so the target app picks what it understands: `public.html` (a bordered table; Word, Pages, Mail, Notion), a tab-separated plain text for spreadsheets and editors, and the Markdown source offered through "Copy Markdown". Which flavor is the plain-text one is an open question.
6. **Failure:** an unusable reply (no table, uneven columns, endpoint error, quota, offline, image too large) shows a plain message with the reason and offers Recognise Text (on-device) instead. No silent fallback to an upload.

## 5. Questions for the grill (each with a first recommendation)

1. **Name and glossary.** "Table Recognition (识别表格)" as a third kind next to On-device Recognition and Cloud Recognition, or a mode of Cloud Recognition? Recommend a separate term: different providers, different output, different consent text.
2. **Entry points in v1.** Recommend viewer menu item plus Capture Bar; the Capture Thumbnail and the "Recognise as table" button in the text panel as stretch.
3. **Consent.** One shared consent and global switch with Baidu, or one per provider and kind? The image goes to a different company; recommend consent per provider (shown the first time that provider is used) and one global off switch for all cloud features.
4. **ADRs and privacy text.** ADR-015 and ADR-019 describe one Baidu exception. Needs a new ADR (or an amendment) that names Table Recognition and the user-chosen endpoints, and updates About, README and the release-notes template. The consent sentence must say that the image goes to the host in the Base URL the user entered.
5. **Providers in v1.** Recommend presets DeepSeek and OpenAI plus Custom base URL; verify OpenAI in a second spike before promising it.
6. **Request shaping per provider.** `thinking: disabled` only for the DeepSeek preset; Custom sends the standard fields only. Confirm.
7. **Test button scope.** Text-only ping, or a tiny-image ping that also proves vision support? Recommend the tiny image (costs a fraction of a cent).
8. **Result panel.** Preview plus Markdown edit, or just copy-and-notice like Recognise Text? Recommend preview plus edit, because of the "Sensoror" class of errors.
9. **Clipboard flavors** and which one is the plain-text flavor (tab-separated or Markdown).
10. **On-device alternative.** macOS 26 Vision may be able to find tables on the Mac with no upload (a document-recognition request). This is from memory and has not been checked; a second small spike should confirm it before the grill decides that the cloud is the only way. If it works, the cloud path could be an opt-in for better quality.
11. **Limits.** Images above the model's limits, very dense or very large tables (1024 tokens per image), several tables in one image, merged cells, rotated or photographed tables. Recommend v1 supports one table per request, tells the user when the result is unusable, and does not promise merged cells.
12. **Ledger and work packages.** New row EXT-06 (Table Recognition, Absent), a work package after P7-12, and the effect on EXT-04's description (one provider kind vs two). Acceptance row text from the owner's criterion: paste the result into a Word document and screenshot it; the table has all rows, columns and text of the source, with a recorded list of known differences.
13. **Key storage and cost.** Keychain, one key per provider; no key ships with the app. Show cost or token counts? Recommend no, but log token counts locally for diagnostics, not the image or the text.
14. **Test strategy.** A provider test with a URLProtocol stub like the Baidu one; a recorded real response as a fixture; the device acceptance with the owner's key and Word.

## 6. Out of scope for this plan

Exporting to `.docx` or `.xlsx` files, editing table structure, merging or splitting tables, other languages' prompt tuning, an on-device table engine (until question 10 is answered), prompt editing by the user, and any change to Baidu Cloud Recognition.

## 7. Next steps

1. Owner reads this plan and corrects it.
2. `/grill-with-docs` on section 5 (owner-triggered); decisions go to `GLOSSARY.md`, a new ADR and a grilling record next to this file.
3. `/to-spec`, then `/to-tickets`. No implementation brief before that.
4. Optional before the grill: spike 2 (macOS 26 on-device table recognition; the same image through OpenAI).
