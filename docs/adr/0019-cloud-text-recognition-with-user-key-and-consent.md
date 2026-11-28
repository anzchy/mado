---
status: accepted
date: 2026-11-13
---

# ADR-019: Cloud Recognition uses the user's own key and runs only after consent; it amends ADR-015

[ADR-015](0015-sparkle-updates-over-a-network-client-entitlement.md) said Mado makes network requests only for Sparkle and never uploads images. The owner has decided to "support common OCR APIs, Baidu OCR first" ([grilling record](../plans/20261113-capture-annotation-ocr-grilling.md) 0.5, 1.1–1.4). This ADR adds one narrowly scoped exception.

## Decision

- **Scope of the exception:** an image may leave the Mac only through **Cloud Recognition**, only when the user has explicitly triggered "Recognise text", and only to the OCR service the user configured. Nothing else in Mado makes network requests or uploads images or metadata, so ADR-015 still holds everywhere else.
- **Key:**
  - The user enters their own Baidu API Key and Secret Key in Settings.
  - The keys are stored in the keychain.
  - Mado ships no key and pays no fees on the user's behalf.
- **Consent:**
  - The first use of Cloud Recognition explains that the image will be uploaded to Baidu, and remembers the user's agreement.
  - Settings has a global switch that turns Cloud Recognition off.
- **Fallback:** without a key, offline or out of quota, Mado uses **On-device Recognition** (Vision) instead, and the result is marked as on-device.
- **Selecting text on an image** (EXT-01) always uses On-device Recognition, so viewing an image never uploads it.
- **Extensibility:** recognition goes through one provider interface. Baidu is the first provider; other services are added later through the same consent and key rules.

## Considered options

- **Mado ships its own key:** the key would ship with the app and could be extracted, and the owner would carry the fees and the real-name verification. Rejected.
- **Ask for confirmation every time:** the most interruptions, with little gain in safety over a single consent plus a global switch. Rejected.
- **On-device only:** consistent with ADR-015, but does not meet the owner's requirement for Baidu-first. Rejected.

## Consequences

- The Baidu account requires real-name verification. The documentation lists only mainland ID cards. Image retention terms, and whether the service is reachable from outside the mainland, are unconfirmed ([technical research](../research/20261113-capture-ocr-tech.md) §D). These have to be stated in the Settings description and the consent text.
- The free quota is about 1000 calls per month for the standard and the accurate endpoints (500 for the accurate endpoint with locations). Quota errors go to the fallback; they do not fail silently.
- The entitlement does not change: `network.client` already exists for Sparkle.

## Amendment 2026-11-22: the standard endpoint

The first provider calls Baidu's standard general-text endpoint (`general_basic`), not the accurate one (`accurate_basic`). The device acceptance run found that a Baidu application with only 通用文字识别 enabled is refused on the accurate endpoint (`error_code=6`), and the owner decided to use the standard endpoint only ([grilling record](../plans/20261122-baidu-standard-ocr-grilling.md)).

- Both endpoints take the same token and request and return the same response shape, and both have about 1000 free calls per month.
- The standard endpoint accepts images up to 8 MB encoded and 4096 px on the longest side (the accurate one: 10 MB, 8192 px). Mado shrinks a larger image before upload, as before, and uses On-device Recognition when it cannot fit.
- Settings tells the user to enable 通用文字识别 for the application in the Baidu console.
- Nothing else in this decision changes: key, consent, global switch, fallback and the rule that selecting text on an image never uploads.

## Amendment 2026-11-28: the Baidu notes move to the help site (#870, spec #866)

The Baidu account notes (real-name verification, mainland Chinese ID documents only, unconfirmed image retention and service outside mainland China) and the terms link move out of the Settings description. Settings keeps a one-line Keychain hint with a 「了解更多 ↗」 link to the help page. The privacy facts and the terms link stay visible at the point of decision, in the consent dialog shown before the first upload, and on the help page `baidu-key.html` (Chinese and English). The step to enable 「通用文字识别」 in the Baidu AI Cloud console now appears only on the help page, which replaces the Settings sentence of the 2026-11-22 amendment.

Owner decision 2026-11-28: 「修订 ADR-0019，说明移到帮助站」, with this text confirmed as written.

Consequence: a release must not ship before the help pages are live (#887/#888). The #889 link check, once built, gates release on it; until then the ledger limitation for EXT-04 and EXT-06 states that the check does not exist yet.
