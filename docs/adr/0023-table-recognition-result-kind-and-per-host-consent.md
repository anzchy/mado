---
status: proposed
date: 2026-11-25
---

# ADR-023: Table Recognition is a result kind of Cloud Recognition, with consent per service host; it amends ADR-019 and ADR-015

[ADR-015](0015-sparkle-updates-over-a-network-client-entitlement.md) says Mado makes network requests only for Sparkle. [ADR-019](0019-cloud-text-recognition-with-user-key-and-consent.md) adds one exception: Cloud Recognition, when the user explicitly asks to recognise text, to the OCR service the user configured (Baidu first). The Table Recognition spec ([#866](https://github.com/anzchy/mado/issues/866), ledger row EXT-06) adds a second command, Recognise Table, that sends the image to a vision-model service the user configures (DeepSeek by default, or a custom OpenAI-compatible address). This ADR records how that fits the two earlier decisions. It amends them; it does not replace them, and everything in them that is not named here still holds. EXT-04's acceptance is unchanged.

Sources: [Table Recognition grilling record](../plans/20261124-table-recognition-grilling.md) decisions 1, 3, 4, 5, 7, 13 and 15; [云识别 heading and help site grilling record](../plans/20261124-cloud-heading-and-help-site-grilling.md); spec #866; `GLOSSARY.md` (Table Recognition, Cloud Recognition).

## Decision

1. **Result kind versus engine.** Table Recognition is a kind of result, like recognised text; Cloud Recognition is the engine that produces it.
   - The command the user chooses decides the kind of result: Recognise Text gives text, Recognise Table gives a table.
   - Mado never detects a table automatically, because deciding from the image would need an upload first.
   - Recognise Table uses only the table service the user configured. It never falls back from a table to text, to Baidu, or to On-device Recognition. When it cannot run or fails, the user is told why and may ask for text as a separate command.
   - Recognise Text routes as ADR-019 says, and selecting text on an image stays On-device only.
2. **Consent per service host, with the real host shown.**
   - Consent is given and stored per service host. Consent for one host (for example Baidu's) does not cover another (for example DeepSeek's).
   - Settings always shows the real host the image is sent to beside the address, outside any collapsed "Advanced" section.
   - When the configured host changes, Mado asks for consent again before the next upload.
   - ADR-019's single global switch still gates every Cloud Recognition upload, text and table alike.
   - The Settings **Test** button for the table service sends a built-in sample table image, never the user's image, to the configured table host. It is part of the same exception and is gated the same way: it sends nothing while the switch is off or the host has no consent.
3. **No cross-host redirect carries the image or the key.** Mado never follows a redirect that would send the image or the key to a different host. The existing HTTP transport already refuses every redirect (`URLSessionHTTPTransport`), and Table Recognition reuses it.
4. **A help link opened in the default browser is not Mado's own network use.** Settings may link to help pages (the help site). Opening such a link hands the address to the user's default browser; Mado itself makes no request. ADR-015's rule that Mado's own code makes network requests only for Sparkle and the Cloud Recognition exception still holds.
5. **Presets, key and what leaves the Mac.**
   - Presets: DeepSeek is the default; Custom takes an OpenAI-compatible address and model. An OpenAI preset ships only if a vision-capable model has been verified before release; otherwise only DeepSeek and Custom are offered (#866). No other preset is decided.
   - The access key is stored in the Keychain per service configuration. A new address does not inherit an old key, and consent does not carry over to a new host (decision 13; #866). Whether a changed model alone needs a new key is not decided here.
   - One Recognise Table request sends, to the configured host only: the one image the command was given, the user's key as a bearer credential, the fixed prompt, and the request fields of the preset (such as the model name). A Test request sends the built-in sample image instead of a user image. No recognised text, no other image and no diagnostics are sent; local diagnostics stay on the Mac (#866).
6. **The sandbox is unchanged; no new entitlement.** The table service uses the existing `com.apple.security.network.client`, already granted for Sparkle (ADR-015) and used by Cloud Recognition (ADR-019). No entitlement is added or widened.

## How this amends the earlier ADRs

- **ADR-019:** the exception now covers two explicit commands, Recognise Text and Recognise Table, each going only to the service the user configured for it, plus the table service's Settings Test request with its built-in sample image. Nothing else in Mado sends images or makes network requests beyond these and Sparkle. Consent, given once in ADR-019, is now given once per service host. ADR-019's fallback rule applies to Recognise Text only.
- **ADR-015:** Baidu is no longer the only service an image may be sent to. The exception is Cloud Recognition as amended here, and opening a help link in the browser does not count as Mado's network use.

## Wording is not decided here

This ADR states decisions, not user-facing text. The grilling record marks the consent, switch and ADR decisions (3 and 4) and the privacy wording as "owner confirm". The wording of the consent dialog, the Test note, the local diagnostics line, and the About, README and release text is the owner's to confirm under [#873](https://github.com/anzchy/mado/issues/873). This ADR quotes none of it. It stays `proposed` until the owner confirms decisions 3 and 4.

## Considered options

- **Detect tables automatically and pick the kind of result for the user.** This needs an upload before the user has asked for one, against ADR-019. Rejected.
- **Fall back from a failed table to Baidu text or On-device Recognition.** The user would get lines of text when they asked for a table, and might not notice. Rejected; text stays a separate, explicit command.
- **Let one consent cover every cloud service.** The user would agree to Baidu and then send images to a host they never named. Rejected.

## Consequences

- About, README, Settings, GLOSSARY and the release template must stop saying that Baidu is the only network exception (#873 and the Settings tickets of #866).
- The transport's host allow-list, today limited to Baidu's OCR endpoints, has to admit the configured table service host without allowing redirects.
- Ledger row EXT-06 records the acceptance; EXT-04 keeps its own.
