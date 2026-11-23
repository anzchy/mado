# Grilling record: Cloud Recognition uses Baidu's standard endpoint (2026-11-22)

Trigger: the v0.0.2 device acceptance run (#824) found that the owner's Baidu application, which has only 通用文字识别 (standard) enabled, answers `error_code=6 No permission to access data` to the accurate endpoint Mado calls. `baidu-ocr-check.sh` confirmed the keys are valid, `general_basic` works and `accurate_basic` is refused.

Inputs: [technical research](../research/20261113-capture-ocr-tech.md) (D2 standard endpoint, D3 accurate endpoint, limits and quota), [ADR-019](../adr/0019-cloud-text-recognition-with-user-key-and-consent.md), [previous grilling record](20261113-capture-annotation-ocr-grilling.md), standard endpoint documentation https://ai.baidu.com/ai-doc/OCR/zk3h7xz52.

## Facts established by reading the code and docs

- ADR-019 and GLOSSARY do not name an endpoint; only ADR-019's Consequences line mentions "500 for the accurate endpoint with locations". Ledger EXT-04's 怎么确认, the consent sheet and the result label (「百度云识别」) do not distinguish the two products.
- The endpoint URL is hard-coded at `BaiduTextRecognitionProvider.swift:57`; three test files pin it.
- Both products: 1,000 free calls per month, same token, same `image` parameter, same `words_result` response.
- Limits differ: standard 8 MB encoded and 4096 px longest side; accurate 10 MB and 8192 px. The provider's size check and downscale use the accurate limits today.

## Decisions (owner)

| # | Question | Decision |
|---|---|---|
| 1 | Keep accurate, add a fallback, or use standard only | Standard only (`general_basic`). Owner's choice 2026-11-22: 「改成只用标准版」. |
| 2 | Process | Run /grill-with-docs first, then /to-spec and /to-tickets. Owner's choice 2026-11-22: 「先跑 /grill-with-docs」. |
| 3 | An image larger than the standard limits | Downscale to 4096 px longest side before upload, as the provider already does for the accurate limit; keep the 8 MB encoded check. Owner's choice: 「降采样到 4096 px 再上传 (Recommended)」. |
| 4 | A user who enabled only the accurate product gets `error_code=6` | Add one short sentence in Settings (zh and en) in the 文字识别 group naming the product to enable in the Baidu console (通用文字识别); fallback and its diagnostics log stay as they are. Owner's choice: 「加一句中英文说明 (Recommended)」. |
| 5 | How the decision is recorded | An amendment section in ADR-019, no new ADR (the endpoint is one constant and easy to reverse, so it does not meet the "hard to reverse" bar); the Consequences line about quota is corrected. Owner's choice: 「在 ADR-0019 里加修订段，不新开 ADR (Recommended)」. |
| 6 | Release | Milestone v0.0.2 and part of the release gate #825: the real-cloud-success sentence of EXT-04 in #824 cannot pass otherwise. Owner's choice: 「进 v0.0.2 并加入 #825 门槛 (Recommended)」. |

## Facts that need no decision

- The existing provider already shrinks the image (by 0.75 per step) until the URL-encoded `image=` value fits the byte limit and fails with `cloudImageTooLarge` (then On-device Recognition) when the shorter side would drop under 15 px. Only the constants change: 10 MB to 8 MB and 8192 px to 4096 px.
- GLOSSARY needs no change: **Cloud Recognition** does not name a product tier.
| 7 | Wording of the Settings sentence | Short, neutral, no link (the Baidu terms link already exists). zh: 「需在百度智能云控制台为该应用开通「通用文字识别」。」 en: "Enable “General Text Recognition” for this application in the Baidu AI Cloud console." Owner's choice: 「简短中立句 (Recommended)」. |
| 8 | Who verifies the real cloud success | The independent tester, with the keys the owner entered in the test build (same as #824); the keys never enter a conversation, log or record. The tester re-runs only EXT-04 (cloud success with the 百度云识别 label, switch off, Remove Keys then no Baidu call). Owner's choice: 「独立测试者用你已输入的密钥跑 (Recommended)」. |

## Scope handed to /to-spec

- Change: the Baidu provider calls `general_basic`; size check 8 MB (URL-encoded `image=`) and 4096 px longest side; one Settings sentence (zh and en); tests that pin the new endpoint and limits (the three existing Baidu test files change); ledger EXT-04 限制 text updated (怎么确认 unchanged); ADR-019 amendment.
- Not changed: keys and keychain, consent sheet, global switch, engine label, fallback rules, diagnostics log, On-device Recognition, selecting text on an image.
- Release: milestone v0.0.2, release-gate item in #825; verification by #824's tester as in decision 8.
