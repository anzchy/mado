# Settings copy review (2026-11-24)

Owner request, 2026-11-24: 「Settings page的所有文案，包括网页中的文字，都交给agy cli审核一下，主要是易读性，是否有歧义等，根据其建议形成一个文档，提交github issue」. This is the document; the issue is linked from the end of this file. Related: spec #866 (Table Recognition), #870 (Settings hints cut to one line), #873 (privacy text), #863 (Settings sidebar spacing).

## Method and limits

- Reviewer: `agy` (Google Antigravity CLI), headless print mode, plan mode (read-only), medium or low effort. Nothing was edited by it; its output is text.
- Pass 1 inputs: the visible text of every pane of the Settings window as drawn in design state 35 (including the new 表格识别 group and its test messages), the five help-site pages (`site/`), and the decided privacy facts. Pass 2 input: the shipped App strings (`App/Resources/Localizable.xcstrings`, English source plus Simplified Chinese, 430 strings), filtered by the reviewer to the Settings, About and consent strings.
- Limits: pass 1 reviewed the **design state**, which is not the shipped app; findings that exist only in the state page are marked **state only**. The reviewer could not see the English text of the Table Recognition group (it is not in the App yet), the real names macOS shows for the capture helper, or the third-party consoles. Its suggestions were triaged below by the delegator: accepted, adjusted, or rejected with a reason. Wording that touches privacy stays an owner decision.

## Overall verdict

The copy is honest and mostly plain, and the cost and key-storage statements are well judged. It is not ready to ship because (1) several strings in the shipped app still describe Cloud Recognition as Baidu-only and text-only, which is no longer true once Table Recognition lands; (2) the English strings mix American and British spelling (`Recognize`/`Recognise`, `authorize`); (3) the Chinese name of the feature is split between 云识别 and 云端识别; (4) the design state page still carries old text (`picsee`, a wireframe number); (5) the help site still has internal notes that must not be published.

## Findings (merged and de-duplicated; ordered by severity)

Disposition: **Accept** (do it), **Adjust** (do it with the change noted), **Reject** (reason), **Owner** (needs your decision), **Device** (needs a device check first).

### High

| # | Where (exact current text) | Problem | Disposition and replacement |
|---|---|---|---|
| H1 | About: "…the only exception is Cloud Recognition, which is off until you turn it on with your own Baidu keys and agree, and then sends the image you asked to recognise to Baidu. The sandbox reads only folders you authorize." / 「…唯一例外是云识别：需你主动开启、使用自己的百度密钥并同意，才会把你要识别的那张图片发送给百度。…」 | Contradicts the decided facts once Table Recognition ships: Cloud Recognition covers text and tables, default services Baidu and DeepSeek, consent per host. `authorize` is American. | **Accept**, folded into #873 (drafts there, owner confirms the wording). |
| H2 | The three Cloud Recognition strings of the Baidu consent dialog and the Settings switch: "Cloud Recognition uploads the image being recognized to Baidu. It uploads only when you click Recognize Text, have agreed once, and this switch is on…" and "Use Baidu to recognize text?" and "Allow Recognize Text to use a cloud service" | Describe the switch as Baidu-only and text-only; the switch becomes global (text and table) with consent per service host. American spelling. | **Accept**, folded into #871 (T4) and #873: the switch text names both commands and "the service you configured"; the Baidu consent dialog keeps its Baidu-specific facts. Owner confirms wording. |
| H3 | English spelling: "Capture and Recognize Text", "Recognize Text" (a duplicate key next to "Recognise Text"), "Allow Recognize Text to use a cloud service", "…being recognized to Baidu", "Use Baidu to recognize text?", "authorize" | The product standard is British (`Recognise Text`); the duplicate keys map to the same Chinese. | **Accept**: one source key `Recognise Text`; British spelling throughout (decision: owner confirms British as the product standard, see Glossary). |
| H4 | Chinese 「云端识别」「云端服务」 in "Cloud Recognition", "Cloud Recognition · No Key", the switch and the two long dialogs; 「云识别」 elsewhere | Two names for one feature. | **Accept**: 云识别 everywhere; the switch reads 「允许云识别」. |
| H5 | **State only:** Settings 通用/缓存/更新/关于: "为 picsee 单独设置", "只删除 picsee 生成的缩略图", "picsee 只在检查更新时访问 GitHub", "picsee 不收集数据，不上传图片" | Old name; the About line also says "不上传图片", which is false once Cloud Recognition exists. | **Accept** for the state page (the shipped strings already say Mado). |
| H6 | **State only:** Display: 「与网格底栏「显示」面板（15）是同一组设置…」 | A wireframe number leaked into user text. | **Accept**: 「与网格底栏的「显示」设置同步，任一处修改立即生效。」 |
| H7 | Help `screen-recording.html`: 「…只给截图助手」 vs 「…录屏与系统录音，打开 Mado。」 | Which row to enable is unclear. The owner had to add Mado.app by hand in the real run, and the prompt names the helper. | **Device**: check what System Settings shows for the helper and for Mado on a clean machine, then write one consistent instruction. |
| H8 | Capture: 「没有密钥、离线或额度用完时，文字识别改用本机并标明。」 / "Without a key, offline, or when the quota is used up, Mado uses on-device recognition, and the result names the engine it used." | Ambiguous after Table Recognition: it applies to Recognise Text only; Recognise Table has no on-device fallback. | **Accept**: 「没有密钥、离线或额度用完时，「识别文字」会改用本机识别并标明；「识别表格」只能用云识别。」 / "…Recognise Text falls back to on-device and says so; Recognise Table needs Cloud Recognition." |
| H9 | Capture: the Cloud Recognition switch sits under the heading 「文字识别」 | It now governs text and tables, so it should not look nested under text. | **Owner**: either a heading 「云识别」 above both service groups, or keep the layout and rely on the switch text. State 35 shows the second; decide. |

### Medium

| # | Where | Problem | Disposition |
|---|---|---|---|
| M1 | "Only thumbnails created by Mado are deleted. Your images are untouched. Confirm before clearing; thumbnails are rebuilt while browsing." / 「…清理前先确认；…」 | "Confirm before clearing" is awkward text that the confirmation dialog already provides. | **Accept**: drop the confirm sentence. |
| M2 | "Allow Mado to record the screen in System Settings…" vs 「录屏与系统录音」「录屏权限」 elsewhere | Three names for one permission. | **Accept** with H7: use the macOS name 「录屏与系统录音」 (English: Screen & System Audio Recording) once confirmed on the device. |
| M3 | "Enable “General Text Recognition” for this application in the Baidu AI Cloud console." / 「需在百度智能云控制台为该应用开通…」 | "this application" can be read as Mado. | **Accept**: "for your app" / 「为你的应用」. |
| M4 | Keychain casing: "Save to Keychain", "Keys are stored in the keychain." / 「密钥存在钥匙串里。」 | Inconsistent casing. | **Adjust**: "Keys are stored in the macOS Keychain." / 「密钥保存在 macOS 钥匙串中。」 The reviewer's 「安全保存」 is **rejected**: it is a security claim the product does not make. |
| M5 | Table group: 「只在你点「识别表格」后，图片才发送到这里。」 | Omits the switch condition. | **Accept**: 「开启「允许云识别」并点「识别表格」后，图片才会发送到这里。」 |
| M6 | Table group: Test note 「发送内置示例，不发送你的图片；可能收费。」 | The reviewer wanted 「可能消耗账户额度」. | **Reject**: the owner confirmed the current wording on 2026-11-24. |
| M7 | Table group: test success 「测试成功，可以识别示例表格。」 | Reviewer wanted 「可以正常识别表格」. | **Reject**: that claims more than a sample test proves (decision 7). The current wording stays. |
| M8 | Table group: 「测试未通过。」 | Reviewer wanted a hint ("check key, network, service"). | **Reject**: decision 7 says not to guess the cause when it cannot be classified. |
| M9 | Table group: 「高级」row and the cost line 「可能使用服务账户的余额，费用请到该服务查看。了解更多 ↗」 | Reviewer thought the cost line sits oddly under 高级. | **Adjust**: keep the cost line (decision 13) but place it under the Test row, not after 高级; the 高级 row is just the disclosure. |
| M10 | Capture bar hint 「打开后，没有 Mado 窗口也能截图。第一次截图时 macOS 会请求录屏权限（只给截图助手）。了解更多 ↗」 | Long for one line. | **Accept**: 「打开后，没有 Mado 窗口也能截图；第一次需要允许录屏权限。了解更多 ↗」, the helper detail goes to the help page. |
| M11 | Access key labels: 「密钥」「访问密钥」「API Key」「Secret Key」 and the placeholder 「粘贴访问密钥（API Key）」 | Mixed names; jargon. | **Owner**: confirm 「访问密钥」 as the single term, keeping service-specific field names (API Key, Secret Key) in parentheses only for Baidu where its console uses them. |
| M12 | **Site:** index 「设置页里的「了解更多」会打开这里。App 里只留一句话，细节放在这里。」 and baidu-key 「具体页面名称发布前需要对照百度控制台核对。」 and the draft banner | Internal notes that must not be published. | **Accept**: remove before the site is enabled (blocked on content verification of the real pages). |
| M13 | **Site:** baidu-key 「百度会把上传的图片保存多久、在中国大陆以外能否使用，目前都未经确认。」 | Reads like an audit note. | **Adjust**: 「百度如何保存上传的图片、在中国大陆以外能否使用，目前无法确认，请以百度的隐私政策为准。」 |
| M14 | **Site:** deepseek-key 「选“自定义”，填写 OpenAI 兼容的地址和能读图片的模型名即可；“兼容”不代表所有模型都能读图。」 | Hard for a non-technical reader. | **Accept** (lightly): say what the two fields are and that not every model can read images. |

### Low

| # | Where | Disposition |
|---|---|---|
| L1 | General: 「关闭时工具在不操作后自动隐藏，鼠标移到边缘或按 Tab 唤回。」 | **Accept**: 「关闭时，大图工具会在无操作后自动隐藏；把鼠标移到窗口边缘或按 Tab 键可重新显示。」 |
| L2 | Capture: 「关闭后，重启电脑时截图工具条不会自动出现。」 | **Accept**: state the on-case: 「开启后，登录 Mac 时自动显示截图工具条。」 |
| L3 | Capture: 「文件名 mado-20261113153012.png，同一秒的第二张加 -2。」 | **Accept**: 「文件名如 mado-20261113153012.png；同一秒内再截一张会加 -2。」 |
| L4 | About licence lines: Chinese lines lack the terminal full stop that the English has | **Accept**. |
| L5 | Quote style 「」 vs “” and menu-path arrows → vs › | **Owner**: choose one each (suggested: 「」 for UI labels, › for menu paths). |

## Glossary to fix (owner confirms)

| Concept | Variants today | Proposed |
|---|---|---|
| App name | Mado, picsee (state page) | Mado |
| Cloud service feature | 云识别, 云端识别, 云端服务 | 云识别 / Cloud Recognition |
| Text command | 识别文字, 文字识别 | 识别文字 / Recognise Text |
| Table command | 识别表格, 表格识别 | 识别表格 / Recognise Table |
| On-device | 本机, 本机识别 | 本机识别 / on-device |
| Credential | 密钥, 访问密钥, API Key | 访问密钥 / Access Key (Baidu field names in parentheses) |
| Keychain | 钥匙串, Mac 钥匙串 | macOS 钥匙串 / macOS Keychain |
| English spelling | Recognise and Recognize, authorise and authorize | British |
| Permission name | 录屏权限, 录制屏幕, 录屏与系统录音 | 录屏与系统录音 (after the device check, H7) |

## Where each fix lands

- Shipped strings and Settings layout: #871 (T4, the new group and the switch text), #870 (T12, hints cut to one line; add the M10, L1-L3 text), #873 (T13, About, README, release notes, CHANGELOG), plus one small ticket for the pure string cleanups that do not wait for Table Recognition (H3, H4, M1, M3, M4, L4).
- Design state page 35: H5, H6, M5, M9, M10 (a states PR; `design:check` must pass).
- Help site: M12-M14, H7; blocked on verifying the pages against the real DeepSeek and Baidu consoles.
- Not judged by the reviewer: the English text of the Table Recognition group (not written yet), the helper's name in System Settings, the live consoles.

## Second look needed after the fixes

Re-run the same review on the shipped English strings once #871 and #873 land, because pass 1 could not see them.
