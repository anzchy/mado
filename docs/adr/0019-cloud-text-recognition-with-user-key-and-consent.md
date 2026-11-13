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
- The free quota is about 1000 calls per month (500 for the accurate endpoint with locations). Quota errors go to the fallback; they do not fail silently.
- The entitlement does not change: `network.client` already exists for Sparkle.
